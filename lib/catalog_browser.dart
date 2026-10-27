import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'filmstream_catalog.dart';
import 'main.dart' show Tmdb, Movie, DetailPage, imageRoot;

class CatalogBrowser extends StatefulWidget {
  final String title;
  final String? type;
  final String query;
  const CatalogBrowser({super.key, required this.title, this.type, this.query = ''});
  @override State<CatalogBrowser> createState() => _CatalogBrowserState();
}

class _CatalogBrowserState extends State<CatalogBrowser> {
  late final Future<List<CatalogEntry>> entries = FilmStreamCatalog.load();
  int visible = 24;
  @override void didUpdateWidget(covariant CatalogBrowser old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.type != widget.type) visible = 24;
  }
  @override Widget build(BuildContext context) => FutureBuilder<List<CatalogEntry>>(
    future: entries, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Text('Gagal membaca katalog: ${snapshot.error}'));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      final term = widget.query.toLowerCase().trim();
      final matches = snapshot.data!.where((e) =>
        (widget.type == null || widget.type == e.type) &&
        (term.isEmpty || e.title.toLowerCase().contains(term))).toList();
      matches.sort((a,b) {
        final y = b.year.compareTo(a.year);
        return y != 0 ? y : a.title.compareTo(b.title);
      });
      final count = visible < matches.length ? visible : matches.length;
      return Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Align(
          alignment: Alignment.centerLeft, child: Text('${widget.title} · ${matches.length} judul',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)))),
        Expanded(child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, childAspectRatio: .57,
            crossAxisSpacing: 12, mainAxisSpacing: 14),
          itemCount: count + (count < matches.length ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == count) return Center(child: FilledButton(
              onPressed: () => setState(() => visible += 24),
              child: const Text('Lainnya')));
            final item = matches[i];
            return CatalogPosterTile(
              key: ValueKey(item.url), entry: item,
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => CatalogDetail(entry: item))),
            );
          },
        )),
      ]);
    },
  );
}

/// TMDB is enrichment only; every tile keeps its crawler title and source URL.
class CatalogMetadata {
  CatalogMetadata._();
  static final Map<String, Future<Movie?>> _cache = {};
  static final RegExp _spaces = RegExp(r'\s+');
  static String norm(String v) => v.toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim().replaceAll(_spaces, ' ');
  static Future<Movie?> forEntry(CatalogEntry entry) {
    return _cache.putIfAbsent(entry.url, () async {
      if (entry.year <= 0) return null;
      try {
        final response = await Tmdb.get(
          entry.type == 'tv' ? 'search/tv' : 'search/movie',
          {'query': entry.title, 'include_adult': 'false'});
        for (final raw in (response['results'] as List? ?? const [])) {
          if (raw is! Map) continue;
          final data = Map<String, dynamic>.from(raw);
          final title = (data['title'] ?? data['name'] ?? '').toString();
          final original = (data['original_title'] ?? data['original_name'] ?? '').toString();
          final date = (data['release_date'] ?? data['first_air_date'] ?? '').toString();
          if (date.length < 4 || int.tryParse(date.substring(0, 4)) != entry.year) continue;
          if (norm(title) != norm(entry.title) && norm(original) != norm(entry.title)) continue;
          if (data['id'] is num) return Movie.fromJson(data, fallback: entry.type);
        }
      } catch (_) {}
      return null;
    });
  }
}

class CatalogPosterTile extends StatefulWidget {
  final CatalogEntry entry;
  final VoidCallback onTap;
  const CatalogPosterTile({super.key, required this.entry, required this.onTap});
  @override State<CatalogPosterTile> createState() => _CatalogPosterTileState();
}

class _CatalogPosterTileState extends State<CatalogPosterTile> {
  late Future<Movie?> metadata = CatalogMetadata.forEntry(widget.entry);
  @override void didUpdateWidget(covariant CatalogPosterTile old) {
    super.didUpdateWidget(old);
    if (old.entry.url != widget.entry.url) metadata = CatalogMetadata.forEntry(widget.entry);
  }
  @override Widget build(BuildContext context) => InkWell(
    onTap: widget.onTap,
    borderRadius: BorderRadius.circular(12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(color: const Color(0xff20252e),
          width: double.infinity,
          child: FutureBuilder<Movie?>(future: metadata, builder: (context, snap) {
            final movie = snap.data;
            final poster = movie != null && movie.poster.isNotEmpty ? movie.poster :
                widget.entry.tmdbPosterPath.isNotEmpty ? widget.entry.tmdbPosterPath : widget.entry.posterUrl;
            if (poster.isEmpty) {
              return Center(child: Icon(
                widget.entry.type == 'tv' ? Icons.tv : Icons.movie_outlined,
                size: 52, color: Colors.white54));
            }
            return Image.network(poster.startsWith('https://') ? poster : '$imageRoot$poster',
              fit: BoxFit.cover, width: double.infinity,
              errorBuilder: (_, __, ___) => const Icon(Icons.movie_outlined, size: 52));
          }),
        ),
      )),
      const SizedBox(height: 7),
      Text(widget.entry.title, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      Text('${widget.entry.year}  ·  ${widget.entry.type == "tv" ? "Series" : "Film"}',
        maxLines: 1, style: const TextStyle(fontSize: 11, color: Colors.white60)),
    ]),
  );
}

class CatalogDetail extends StatefulWidget {
  final CatalogEntry entry;
  const CatalogDetail({super.key, required this.entry});
  @override State<CatalogDetail> createState() => _CatalogDetailState();
}

class _CatalogDetailState extends State<CatalogDetail> {
  late final Future<Movie?> metadata = CatalogMetadata.forEntry(widget.entry);

  Future<void> openSource() async {
    final uri = Uri.tryParse(widget.entry.url);
    if (uri == null || uri.scheme != 'https') return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Halaman sumber tidak dapat dibuka')));
    }
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.entry.title)),
    body: FutureBuilder<Movie?>(future: metadata, builder: (context, snap) {
      final m = snap.data;
      final poster = m != null && m.poster.isNotEmpty ? m.poster :
          widget.entry.tmdbPosterPath.isNotEmpty ? widget.entry.tmdbPosterPath : widget.entry.posterUrl;
      return ListView(padding: const EdgeInsets.all(18), children: [
        if (poster.isNotEmpty)
          Center(child: Image.network(poster.startsWith('https://') ? poster : '$imageRoot$poster', height: 240,
            errorBuilder: (_,__,___) => const Icon(Icons.movie, size: 90)))
        else const SizedBox(height: 190, child: Icon(Icons.movie_outlined, size: 90)),
        const SizedBox(height: 12),
        Text(widget.entry.title, style: Theme.of(context).textTheme.headlineSmall),
        Text('${widget.entry.year} · ${widget.entry.type == "tv" ? "Series" : "Film"}'),
        const SizedBox(height: 12),
        if (snap.connectionState == ConnectionState.waiting)
          const LinearProgressIndicator()
        else if (m == null)
          const Text('TMDB belum menemukan kecocokan pasti. Poster tidak ditebak.')
        else ...[
          Text('Rating TMDB: ${m.rating.toStringAsFixed(1)}'),
          const SizedBox(height: 8),
          Text(m.overview.isNotEmpty ? m.overview : 'Sinopsis belum tersedia'),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => DetailPage(
              movie: m, isFavorite: false, onFavorite: () {}))),
            child: const Text('Detail TMDB')),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(onPressed: openSource, icon: const Icon(Icons.open_in_new),
          label: const Text('Buka URL sumber dari katalog')),
      ]);
    }),
  );
}
