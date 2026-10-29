import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart' as prefs;

/// One entry from the crawler's own film/series catalog.
class CatalogEntry {
  final String title;
  final int year;
  final String url;
  final String type;
  final String posterUrl, synopsis, activeSourceUrl;
  final double? rating;
  final int? tmdbId;
  final String tmdbPosterPath;

  const CatalogEntry({
    required this.title,
    required this.year,
    required this.url,
    required this.type,
    this.posterUrl = '',
    this.synopsis = '',
    this.activeSourceUrl = '',
    this.rating,
    this.tmdbId,
    this.tmdbPosterPath = '',
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
      tmdbId: json['tmdb_id'] is int && json['tmdb_id'] > 0 ? json['tmdb_id'] as int : null,
      tmdbPosterPath: (json['tmdb_poster_path'] ?? '').toString(),
    );
  }
}

class FilmStreamCatalog {
  FilmStreamCatalog._();
  static Future<List<CatalogEntry>>? _cached;
  static Future<List<CatalogEntry>> load() => _cached ??= _loadFromAssets();
  static void refresh() { _cached = null; }

  static String _normalUrl(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  static Future<List<CatalogEntry>> _loadFromAssets() async {
    final raw = await rootBundle.loadString('assets/catalog/filmstream_catalog.json');
    final bundled = await compute(_parseCatalog, raw);
    final storage = await prefs.SharedPreferences.getInstance();
    final extraRaw = storage.getString('filmstream_local_catalog_v1') ?? '[]';
    List<dynamic> extra;
    try {
      extra = jsonDecode(extraRaw) as List<dynamic>;
    } catch (_) {
      extra = [];
    }
    final seenUrls = bundled.map((e) => '${e.type}:${_normalUrl(e.url)}').toSet();
    final seenTitles = bundled.map((e) =>
        '${e.type}:${e.year}:${e.title.toLowerCase().trim()}').toSet();
    final merged = List<CatalogEntry>.of(bundled);
    for (final item in extra.whereType<Map>()) {
      try {
        final entry = CatalogEntry.fromJson(Map<String, dynamic>.from(item));
        if (entry.title.trim().isEmpty || entry.year < 1900 ||
            entry.year > DateTime.now().year + 2) continue;
        final uri = Uri.tryParse(entry.url);
        if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
            uri.hasPort || !{'tv12.lk21official.cc', 'tv.lk21online.de'}.contains(uri.host)) {
          continue;
        }
        final urlKey = '${entry.type}:${_normalUrl(entry.url)}';
        final titleKey = '${entry.type}:${entry.year}:${entry.title.toLowerCase().trim()}';
        if (seenUrls.contains(urlKey) || seenTitles.contains(titleKey)) continue;
        seenUrls.add(urlKey);
        seenTitles.add(titleKey);
        merged.add(entry);
      } catch (_) {
        // Invalid local entries must not affect the bundled catalog.
      }
    }
    return List<CatalogEntry>.unmodifiable(merged);
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

// Top-level function required by compute(). It runs outside the UI isolate.
List<CatalogEntry> _parseCatalog(String raw) {
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final items = decoded['items'] as List<dynamic>? ?? const [];
  return List<CatalogEntry>.unmodifiable(
    items.whereType<Map<String, dynamic>>().map(CatalogEntry.fromJson).where(
      (entry) => entry.title.trim().isNotEmpty &&
          entry.url.startsWith('https://') &&
          (entry.type == 'movie' || entry.type == 'tv'),
    ),
  );
}
