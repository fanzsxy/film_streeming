import 'package:flutter/material.dart';
import 'filmstream_catalog.dart';

/// Build normalized titles once; typing only scans cached lowercase strings.
/// Keep only the best seven entries, never sort the entire catalog per key.
class CatalogSuggestionIndex {
  final List<_IndexedTitle> _titles;
  CatalogSuggestionIndex(List<CatalogEntry> entries)
      : _titles = [
          for (final entry in entries)
            if (entry.title.trim().isNotEmpty)
              _IndexedTitle(entry, entry.title.trim().toLowerCase())
        ];

  List<CatalogEntry> match(String query, {int limit = 7}) {
    final term = query.trim().toLowerCase();
    if (term.isEmpty || limit <= 0) return const <CatalogEntry>[];
    final top = <_RankedTitle>[];
    final seen = <String>{};
    for (final item in _titles) {
      final position = item.normalized.indexOf(term);
      if (position < 0) continue;
      final entry = item.entry;
      final key = '${entry.type}:${entry.year}:${item.normalized}';
      if (!seen.add(key)) continue;
      final previous = position > 0 ? item.normalized.codeUnitAt(position - 1) : 0;
      final alphanumeric = (previous >= 48 && previous <= 57) ||
          (previous >= 97 && previous <= 122);
      final rank = position == 0 ? 0 : (alphanumeric ? 2 : 1);
      final row = _RankedTitle(item, rank);
      var insertAt = 0;
      while (insertAt < top.length && _compare(top[insertAt], row) <= 0) {
        insertAt++;
      }
      if (insertAt < limit) {
        top.insert(insertAt, row);
        if (top.length > limit) top.removeLast();
      }
    }
    return top.map((e) => e.item.entry).toList(growable: false);
  }

  static int _compare(_RankedTitle a, _RankedTitle b) {
    final rank = a.rank.compareTo(b.rank);
    if (rank != 0) return rank;
    final year = b.item.entry.year.compareTo(a.item.entry.year);
    if (year != 0) return year;
    return a.item.normalized.compareTo(b.item.normalized);
  }
}

class _IndexedTitle {
  final CatalogEntry entry;
  final String normalized;
  _IndexedTitle(this.entry, this.normalized);
}

class _RankedTitle {
  final _IndexedTitle item;
  final int rank;
  _RankedTitle(this.item, this.rank);
}

/// Public helper for ranking tests and other catalog search integrations.
List<CatalogEntry> matchCatalogSuggestions(
  List<CatalogEntry> entries,
  String query, {
  int limit = 7,
}) =>
    CatalogSuggestionIndex(entries).match(query, limit: limit);

class FilmSearchSuggestions extends StatefulWidget {
  final String text;
  final ValueChanged<String> onSelected;
  const FilmSearchSuggestions({
    super.key,
    required this.text,
    required this.onSelected,
  });

  @override
  State<FilmSearchSuggestions> createState() => _FilmSearchSuggestionsState();
}

class _FilmSearchSuggestionsState extends State<FilmSearchSuggestions> {
  late final Future<CatalogSuggestionIndex> _index = FilmStreamCatalog.load()
      .then((entries) => CatalogSuggestionIndex(entries));

  @override
  Widget build(BuildContext context) {
    if (widget.text.trim().isEmpty) return const SizedBox.shrink();
    return FutureBuilder<CatalogSuggestionIndex>(
      future: _index,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final suggestions = snapshot.data!.match(widget.text);
        if (suggestions.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Material(
            color: const Color(0xff20252e),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in suggestions)
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: _SuggestionPoster(entry: entry),
                    title: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${entry.year} · ${entry.type == 'tv' ? 'Series' : 'Film'}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: const Icon(Icons.north_west, size: 16),
                    onTap: () => widget.onSelected(entry.title),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SuggestionPoster extends StatelessWidget {
  final CatalogEntry entry;
  const _SuggestionPoster({required this.entry});

  @override
  Widget build(BuildContext context) {
    final raw = entry.posterUrl.startsWith('https://')
        ? entry.posterUrl
        : (entry.tmdbPosterPath.startsWith('/')
            ? 'https://image.tmdb.org/t/p/w92${entry.tmdbPosterPath}'
            : '');
    final uri = Uri.tryParse(raw);
    final safe = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        width: 38,
        height: 52,
        child: safe
            ? Image.network(
                raw,
                width: 38,
                height: 52,
                fit: BoxFit.cover,
                // Decode small thumbnails, not full resolution posters.
                cacheWidth: 114,
                errorBuilder: (_, __, ___) => const _PosterFallback(),
              )
            : const _PosterFallback(),
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xff303641),
        alignment: Alignment.center,
        child: const Icon(Icons.movie_outlined, color: Color(0xffe5aa55), size: 20),
      );
}
