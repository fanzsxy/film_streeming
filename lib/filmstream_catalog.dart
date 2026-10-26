import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

/// One entry from the crawler's own film/series catalog.
class CatalogEntry {
  final String title;
  final int year;
  final String url;
  final String type;
  final String posterUrl, synopsis, activeSourceUrl;
  final double? rating;

  const CatalogEntry({
    required this.title,
    required this.year,
    required this.url,
    required this.type,
    this.posterUrl = '',
    this.synopsis = '',
    this.activeSourceUrl = '',
    this.rating,
  });

  factory CatalogEntry.fromJson(Map<String, dynamic> json) {
    final yearValue = json['year'];
    final originalYear = yearValue is num
        ? yearValue.toInt()
        : int.tryParse(yearValue?.toString() ?? '') ?? 0;
    final url = (json['url'] ?? '').toString();
    final path = Uri.tryParse(url)?.path ?? '';
    // Prefer the trailing release year: titles such as "2099" can be misleading.
    final slugYear = RegExp(r'-(19|20)[0-9]{2}/?$').firstMatch(path);
    final releaseYear = json['type'] == 'series' && slugYear != null
        ? int.tryParse(slugYear.group(0)!.replaceAll(RegExp(r'[^0-9]'), '')) ?? originalYear
        : originalYear;
    return CatalogEntry(
      title: (json['title'] ?? '').toString(),
      year: releaseYear,
      url: url,
      type: (json['type'] ?? '') == 'series' ? 'tv' : 'movie',
      posterUrl: (json['poster_url'] ?? '').toString(),
      synopsis: (json['synopsis'] ?? '').toString(),
      activeSourceUrl: (json['active_source_url'] ?? '').toString(),
      rating: json['rating'] is num ? (json['rating'] as num).toDouble() : null,
    );
  }
}

class FilmStreamCatalog {
  FilmStreamCatalog._();
  static Future<List<CatalogEntry>>? _cached;
  static Future<List<CatalogEntry>> load() => _cached ??= _loadFromAssets();

  static Future<List<CatalogEntry>> _loadFromAssets() async {
    final raw = await rootBundle.loadString('assets/catalog/filmstream_catalog.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final items = (decoded['items'] as List<dynamic>? ?? const []);
    return List<CatalogEntry>.unmodifiable(
      items.whereType<Map<String, dynamic>>().map(CatalogEntry.fromJson).where(
        (entry) => entry.title.trim().isNotEmpty &&
            entry.url.startsWith('https://') &&
            (entry.type == 'movie' || entry.type == 'tv'),
      ),
    );
  }

  static Future<List<CatalogEntry>> find(String query, {String? type, int limit = 100}) async {
    final entries = await load();
    final term = query.toLowerCase().trim();
    if (term.isEmpty) return const [];
    return entries.where((entry) =>
      (type == null || entry.type == type) &&
      entry.title.toLowerCase().contains(term)).take(limit).toList(growable: false);
  }
}
