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
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final originalType = (json['type'] ?? '').toString();
    final resolvedType = host == 'tv12.lk21official.cc'
        ? 'movie'
        : const {
            'tv.nontondrama.vip',
            'tv9.nontondrama.my',
            'tv.lk21online.de',
          }.contains(host)
            ? 'tv'
            : (originalType == 'series' || originalType == 'tv')
                ? 'tv'
                : 'movie';
    return CatalogEntry(
      title: (json['title'] ?? '').toString(),
      year: releaseYear,
      url: url,
      type: resolvedType,
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
              'tv12.lk21official.cc', 'tv.lk21online.de',
              'tv.nontondrama.vip', 'tv9.nontondrama.my'
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
            uri.hasPort || !{
          'tv12.lk21official.cc', 'tv.lk21online.de',
          'tv.nontondrama.vip', 'tv9.nontondrama.my'
        }.contains(uri.host)) {
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
    return List<CatalogEntry>.unmodifiable(consolidateCatalogEntries(merged));
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
    consolidateCatalogEntries(
      items.whereType<Map<String, dynamic>>().map(CatalogEntry.fromJson).where(
        (entry) => entry.title.trim().isNotEmpty &&
            entry.url.startsWith('https://') &&
            (entry.type == 'movie' || entry.type == 'tv'),
      ),
    ),
  );
}


/// Consolidate catalog *display entries* without deleting source records.
///
/// Exact same title/year across movie and series is displayed once, preferring
/// the series record when a known series-domain permalink exists. Titles with
/// minor wording differences require matching poster URLs as extra evidence.
List<CatalogEntry> consolidateCatalogEntries(Iterable<CatalogEntry> entries) {
  final result = <CatalogEntry>[];
  final byUrl = <String, int>{};
  final byTitleYear = <String, int>{};
  final byPosterAlias = <String, int>{};

  String keyTitle(String title) => title.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'), '');
  String keyAlias(String title) => title.toLowerCase()
      .replaceAll(RegExp(r'\b(of|the)\b'), '')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
  String normalizedUrl(String url) => url.trim().replaceFirst(RegExp(r'/+$'), '');

  bool better(CatalogEntry candidate, CatalogEntry current) {
    final candidateSeries = candidate.type == 'tv' &&
        const {'tv.nontondrama.vip', 'tv9.nontondrama.my',
          'tv.lk21online.de'}.contains(Uri.tryParse(candidate.url)?.host);
    final currentSeries = current.type == 'tv' &&
        const {'tv.nontondrama.vip', 'tv9.nontondrama.my',
          'tv.lk21online.de'}.contains(Uri.tryParse(current.url)?.host);
    if (candidateSeries != currentSeries) return candidateSeries;
    final candidatePoster = candidate.posterUrl.startsWith('https://');
    final currentPoster = current.posterUrl.startsWith('https://');
    if (candidatePoster != currentPoster) return candidatePoster;
    if (candidate.tmdbId != null && current.tmdbId == null) return true;
    if (candidate.tmdbId == null && current.tmdbId != null) return false;
    return candidate.title.length > current.title.length;
  }

  String titleIdentity(CatalogEntry e) =>
      '${e.year}:${keyTitle(e.title)}';
  String? aliasIdentity(CatalogEntry e) =>
      e.posterUrl.startsWith('https://')
          ? '${e.type}:${e.year}:${e.posterUrl}:${keyAlias(e.title)}'
          : null;

  void indexEntry(CatalogEntry e, int index) {
    byUrl[normalizedUrl(e.url)] = index;
    byTitleYear[titleIdentity(e)] = index;
    final alias = aliasIdentity(e);
    if (alias != null) byPosterAlias[alias] = index;
  }

  void unindexEntry(CatalogEntry e, int index) {
    final url = normalizedUrl(e.url);
    if (byUrl[url] == index) byUrl.remove(url);
    final title = titleIdentity(e);
    if (byTitleYear[title] == index) byTitleYear.remove(title);
    final alias = aliasIdentity(e);
    if (alias != null && byPosterAlias[alias] == index) {
      byPosterAlias.remove(alias);
    }
  }

  for (final entry in entries) {
    final alias = aliasIdentity(entry);
    final duplicate = byUrl[normalizedUrl(entry.url)] ??
        byTitleYear[titleIdentity(entry)] ??
        (alias == null ? null : byPosterAlias[alias]);
    if (duplicate == null) {
      final index = result.length;
      result.add(entry);
      indexEntry(entry, index);
    } else if (better(entry, result[duplicate])) {
      unindexEntry(result[duplicate], duplicate);
      result[duplicate] = entry;
      indexEntry(entry, duplicate);
    }
  }
  return result;
}
