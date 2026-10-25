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
  int visible = 60;
  @override void didUpdateWidget(covariant CatalogBrowser old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.type != widget.type) visible = 60;
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
        Expanded(child: ListView.builder(itemCount: count + (count < matches.length ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == count) return Padding(padding: const EdgeInsets.all(16),
              child: FilledButton(onPressed: () => setState(() => visible += 60),
                child: const Text('Tampilkan lebih banyak')));
            final item = matches[i];
            return ListTile(
              leading: Icon(item.type == 'tv' ? Icons.tv : Icons.movie,
                color: const Color(0xffe5aa55)),
              title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${item.year} · ${item.type == "tv" ? "Series" : "Film"}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => CatalogDetail(entry: item))),
            );
          },
        )),
      ]);
    },
  );
}

class CatalogDetail extends StatefulWidget {
  final CatalogEntry entry;
  const CatalogDetail({super.key, required this.entry});
  @override State<CatalogDetail> createState() => _CatalogDetailState();
}

class _CatalogDetailState extends State<CatalogDetail> {
  late final Future<Movie?> metadata = findMetadata();
  static String norm(String v) => v.toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  Future<Movie?> findMetadata() async {
    if (widget.entry.year <= 0) return null;
    try {
      final response = await Tmdb.get(
        widget.entry.type == 'tv' ? 'search/tv' : 'search/movie',
        {'query': widget.entry.title, 'include_adult': 'false'});
      for (final raw in (response['results'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final data = Map<String,dynamic>.from(raw);
        final title = (data['title'] ?? data['name'] ?? '').toString();
        final original = (data['original_title'] ?? data['original_name'] ?? '').toString();
        final release = (data['release_date'] ?? data['first_air_date'] ?? '').toString();
        if (release.length < 4 || int.tryParse(release.substring(0,4)) != widget.entry.year) continue;
        if (norm(title) != norm(widget.entry.title) &&
            norm(original) != norm(widget.entry.title)) continue;
        if (data['id'] is! num) continue;
        return Movie.fromJson(data, fallback: widget.entry.type);
      }
    } catch (_) { /* Keep unmatched items from catalog. */ }
    return null;
  }

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
      return ListView(padding: const EdgeInsets.all(18), children: [
        if (m != null && m.poster.isNotEmpty)
          Center(child: Image.network('$imageRoot${m.poster}', height: 240,
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
