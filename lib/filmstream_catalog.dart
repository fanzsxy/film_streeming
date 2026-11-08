import 'dart:convert';
import 'package:http/http.dart' as http;
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
  final List<int>? genreIds;
  final String? originalLanguage;

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
    this.genreIds,
    this.originalLanguage,
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
      genreIds: json['genre_ids'] is List ? (json['genre_ids'] as List)
          .whereType<num>().map((value) => value.toInt()).where((id) => id > 0)
          .toSet().toList(growable: false) : null,
      originalLanguage: json['original_language'] is String
          ? json['original_language'] as String : null,
    );
  }
}

class FilmStreamCatalog {
  FilmStreamCatalog._();
  static Future<List<CatalogEntry>>? _cached;
  static Future<List<CatalogEntry>>? _bundledCached;
  static Future<List<CatalogEntry>> load() => _cached ??= _loadFromAssets();
  static Future<List<CatalogEntry>> bundledOnly() =>
      _bundledCached ??= _loadBundled();
  static Future<List<CatalogEntry>> _loadBundled() async {
    final raw = await rootBundle.loadString('assets/catalog/filmstream_catalog.json');
    return compute(_parseCatalog, raw);
  }
  static void refresh() { _cached = null; }
  // Only import reviewed additions from the repository's main branch.
  // Remote updates cannot replace or redirect an existing bundled title.
  static const _remoteCheckKey = 'filmstream_remote_catalog_checked_v1';
  static const _remoteUrl =
      'https://raw.githubusercontent.com/fanzsxy/film_streeming/main/assets/catalog/filmstream_catalog.json';
  static Future<int> syncReviewedCatalog() async {
    final storage = await prefs.SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = storage.getInt(_remoteCheckKey) ?? 0;
    if (now - last < const Duration(hours: 12).inMilliseconds) return 0;
    try {
      final response = await http.get(Uri.parse(_remoteUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 || response.bodyBytes.length > 15000000) {
        return 0;
      }
      final remote = await compute(_parseCatalog, utf8.decode(response.bodyBytes));
      final known = await load();
      final seenUrls = known.map((e) => '${e.type}:${_normalUrl(e.url)}').toSet();
      final seenTitles = known.map((e) =>
          '${e.type}:${e.year}:${e.title.toLowerCase().trim()}').toSet();
      final localRaw = storage.getString('filmstream_local_catalog_v1') ?? '[]';
      final decoded = jsonDecode(localRaw);
      if (decoded is! List) return 0;
      final additions = <Map<String, dynamic>>[];
      for (final entry in remote) {
        final uri = Uri.tryParse(entry.url);
        if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
            uri.hasPort || !{
              'tv12.lk21official.cc', 'tv.lk21online.de'
            }.contains(uri.host)) continue;
        final urlKey = '${entry.type}:${_normalUrl(entry.url)}';
        final titleKey =
            '${entry.type}:${entry.year}:${entry.title.toLowerCase().trim()}';
        if (seenUrls.contains(urlKey) || seenTitles.contains(titleKey)) continue;
        seenUrls.add(urlKey);
        seenTitles.add(titleKey);
        additions.add({
          'title': entry.title, 'year': entry.year, 'url': entry.url,
          'type': entry.type == 'tv' ? 'series' : 'movie',
          'poster_url': entry.posterUrl,
          'synopsis': entry.synopsis,
          'active_source_url': entry.activeSourceUrl,
          'rating': entry.rating,
          'tmdb_id': entry.tmdbId,
          'tmdb_poster_path': entry.tmdbPosterPath,
          if (entry.genreIds != null) 'genre_ids': entry.genreIds,
          if (entry.originalLanguage != null) 'original_language': entry.originalLanguage,
        });
      }
      if (additions.isNotEmpty) {
        final updated = [...decoded, ...additions];
        final saved = await storage.setString(
            'filmstream_local_catalog_v1', jsonEncode(updated));
        if (!saved) return 0;
        refresh();
      }
      await storage.setInt(_remoteCheckKey, now);
      return additions.length;
    } catch (_) {
      // Offline or invalid remote response: preserve the existing catalog and
      // retry on a future launch. Never erase on-device scan results.
      return 0;
    }
  }


  static String _normalUrl(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  static Future<List<CatalogEntry>> _loadFromAssets() async {
    final bundled = await bundledOnly();
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
