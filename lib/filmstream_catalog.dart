import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

/// One entry from the crawler's own film/series catalog.
class CatalogEntry {
  final String title;
  final int year;
  final String url;
  final String type;
  final String posterUrl, synopsis;
  final double? rating;

  const CatalogEntry({
    required this.title,
    required this.year,
    required this.url,
    required this.type,
    this.posterUrl = '',
    this.synopsis = '',
    this.rating,
  });

  factory CatalogEntry.fromJson(Map<String, dynamic> json) {
    final yearValue = json['year'];
    final year = yearValue is num
        ? yearValue.toInt()
        : int.tryParse(yearValue?.toString() ?? '') ?? 0;
    return CatalogEntry(
      title: (json['title'] ?? '').toString(),
      year: year,
      url: (json['url'] ?? '').toString(),
      type: (json['type'] ?? '') == 'series' ? 'tv' : 'movie',
      posterUrl: (json['poster_url'] ?? '').toString(),
      synopsis: (json['synopsis'] ?? '').toString(),
      rating: json['rating'] is num ? (json['rating'] as num).toDouble() : null,
    );
  }
}

/// Loads the bundled catalog once. TMDB is used separately for enrichment,
/// not as the source of titles displayed by FilmStream.
class FilmStreamCatalog {
  FilmStreamCatalog._();

  static Future<List<CatalogEntry>>? _cached;

  static Future<List<CatalogEntry>> load() =>
      _cached ??= _loadFromAssets();

  static Future<List<CatalogEntry>> _loadFromAssets() async {
    final raw = await rootBundle.loadString(
      'assets/catalog/filmstream_catalog.json',
    );
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final items = (decoded['items'] as List<dynamic>? ?? const []);
    return List<CatalogEntry>.unmodifiable(
      items.whereType<Map<String, dynamic>>().map(CatalogEntry.fromJson).where(
        (entry) =>
            entry.title.trim().isNotEmpty &&
            entry.url.startsWith('https://') &&
            (entry.type == 'movie' || entry.type == 'tv'),
      ),
    );
  }

  static Future<List<CatalogEntry>> find(
    String query, {
    String? type,
    int limit = 100,
  }) async {
    final entries = await load();
    final term = query.toLowerCase().trim();
    if (term.isEmpty) return const [];
    return entries
        .where((entry) =>
            (type == null || entry.type == type) &&
            entry.title.toLowerCase().contains(term))
        .take(limit)
        .toList(growable: false);
  }
}
