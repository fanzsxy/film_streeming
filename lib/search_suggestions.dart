import 'package:flutter/material.dart';
import 'filmstream_catalog.dart';

/// Title suggestions are deliberately limited to the local FilmStream catalog.
/// No network request is triggered for every keystroke.
List<CatalogEntry> matchCatalogSuggestions(
  List<CatalogEntry> entries,
  String query, {
  int limit = 7,
}) {
  final term = query.trim().toLowerCase();
  if (term.isEmpty || limit <= 0) return const <CatalogEntry>[];
  final unique = <String, CatalogEntry>{};
  for (final entry in entries) {
    final title = entry.title.trim();
    if (title.isEmpty || !title.toLowerCase().contains(term)) continue;
    final key = '${entry.type}:${entry.year}:${title.toLowerCase()}';
    unique.putIfAbsent(key, () => entry);
  }
  final matches = unique.values.toList();
  matches.sort((a, b) {
    final aTitle = a.title.toLowerCase();
    final bTitle = b.title.toLowerCase();
    final aStarts = aTitle.startsWith(term);
    final bStarts = bTitle.startsWith(term);
    if (aStarts != bStarts) return aStarts ? -1 : 1;
    final aWord = aTitle.split(RegExp(r'[^a-z0-9]+')).any((word) => word.startsWith(term));
    final bWord = bTitle.split(RegExp(r'[^a-z0-9]+')).any((word) => word.startsWith(term));
    if (aWord != bWord) return aWord ? -1 : 1;
    final byYear = b.year.compareTo(a.year);
    if (byYear != 0) return byYear;
    return aTitle.compareTo(bTitle);
  });
  return matches.take(limit).toList(growable: false);
}

class FilmSearchSuggestions extends StatelessWidget {
  final String text;
  final ValueChanged<String> onSelected;
  const FilmSearchSuggestions({
    super.key,
    required this.text,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<CatalogEntry>>(
      future: FilmStreamCatalog.load(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final suggestions = matchCatalogSuggestions(snapshot.data!, text);
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
                    leading: Icon(
                      entry.type == 'tv' ? Icons.tv_outlined : Icons.movie_outlined,
                      size: 20,
                      color: const Color(0xffe5aa55),
                    ),
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
                    onTap: () => onSelected(entry.title),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
