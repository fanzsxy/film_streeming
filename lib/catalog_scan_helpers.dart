import 'dart:convert';

import 'filmstream_catalog.dart';

/// Pure validation/deduplication for the in-app Android WebView scanner.
class CatalogScanHelpers {
  static const genres = <String>{
    'Action', 'Adventure', 'Animation', 'Biography', 'Comedy', 'Crime',
    'Documentary', 'Drama', 'Family', 'Fantasy', 'History', 'Horror',
    'Musical', 'Music', 'Mystery', 'Romance', 'Sci-Fi', 'Science Fiction',
    'Sport', 'Short', 'Thriller', 'War', 'Western', 'Reality', 'Soap', 'Kids',
    'TV Movie', 'War & Politics', 'Action & Adventure', 'Sci-Fi & Fantasy',
  };

  /// Accept comma-separated LK21 card metadata such as "Comedy, Drama",
  /// without treating navigation menus, titles or arbitrary text as genres.
  static final Map<String, String> _genreNamesByLower = {
    for (final label in genres) label.toLowerCase(): label,
  };

  static List<String> parseGenreLabels(Object? raw) {
    final fragments = raw is List
        ? raw.whereType<String>().toList()
        : raw is String ? <String>[raw] : const <String>[];
    final parsed = <String>[];
    for (final fragment in fragments) {
      if (fragment.length > 180) continue;
      final noPrefix = fragment.trim().replaceFirst(
        RegExp(r'^genres?\s*:\s*', caseSensitive: false), '');
      for (final candidate in noPrefix.split(RegExp(r'\s*[,|•]\s*'))) {
        final matched = _genreNamesByLower[candidate.trim().toLowerCase()];
        if (matched != null && !parsed.contains(matched)) parsed.add(matched);
        if (parsed.length >= 10) return parsed;
      }
    }
    return parsed;
  }

  static Object? decoded(Object? value) {
    for (var i = 0; i < 2 && value is String; i++) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    return value;
  }

  static String normalized(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static String cleanUrl(String raw) {
    final value = raw.trim();
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  static bool authorizedPage(String target, String actual, String host) {
    final original = Uri.tryParse(target);
    final landed = Uri.tryParse(actual);
    return original != null && landed != null &&
        original.scheme == 'https' && landed.scheme == 'https' &&
        original.host == host && landed.host == host &&
        original.userInfo.isEmpty && landed.userInfo.isEmpty &&
        !original.hasPort && !landed.hasPort &&
        !original.hasQuery && !landed.hasQuery &&
        !original.hasFragment && !landed.hasFragment &&
        original.path.replaceFirst(RegExp(r'/$'), '') ==
            landed.path.replaceFirst(RegExp(r'/$'), '');
  }

  static bool blockedPage(Object? value) {
    final text = (value ?? '').toString().toLowerCase();
    return RegExp(
      r'captcha|verify you are human|access denied|403 forbidden|429 too many requests',
    ).hasMatch(text);
  }

  static String validPoster(Object? value) {
    final raw = (value ?? '').toString().trim();
    final uri = Uri.tryParse(raw);
    return uri != null && uri.scheme == 'https' &&
            uri.host.isNotEmpty && uri.userInfo.isEmpty && !uri.hasPort
        ? raw : '';
  }

  static Map<String, dynamic>? listingRow(
      Object? raw, String kind, String host, int thisYear) {
    if (raw is! Map || (kind != 'movie' && kind != 'series')) return null;
    final title = (raw['title'] ?? '').toString().trim();
    final yearValue = raw['year'];
    final year = yearValue is int ? yearValue : int.tryParse('$yearValue');
    final url = (raw['url'] ?? '').toString();
    final uri = Uri.tryParse(url);
    if (title.isEmpty || title.length > 180 || year == null ||
        year < 1900 || year > thisYear + 2 || uri == null ||
        uri.scheme != 'https' || uri.host != host ||
        uri.userInfo.isNotEmpty || uri.hasPort ||
        uri.hasQuery || uri.hasFragment) return null;
    final pathYear = RegExp(r'-(19\d{2}|20\d{2})$')
        .firstMatch(uri.path.replaceFirst(RegExp(r'/$'), ''));
    if (pathYear == null || int.parse(pathYear.group(1)!) != year) return null;
    final poster = validPoster(raw['poster_url']);
    final rating = raw['rating'];
    final listingGenres = parseGenreLabels(raw['genres']);
    return {
      'type': kind,
      'title': title,
      'year': year,
      'url': cleanUrl(url),
      if (poster.isNotEmpty) 'poster_url': poster,
      if (rating is num && rating > 0 && rating <= 10) 'rating': rating,
      if (listingGenres.isNotEmpty) 'genres': listingGenres,
      if (listingGenres.isNotEmpty) 'genre_data_source': 'lk21_source',
      'scan_added_v2': true,
    };
  }

  static String keyFor(Map<String, dynamic> row) {
    final type = (row['type'] ?? '') == 'series' ? 'tv' : 'movie';
    return '$type:' + (row['year'] ?? '').toString() + ':' +
        normalized((row['title'] ?? '').toString());
  }

  static List<Map<String, dynamic>> onlyNew(
      List<CatalogEntry> known, List<Map<String, dynamic>> rows,
      {int limit = 12}) {
    final seenUrls = known.map(
      (item) => item.type + ':' + cleanUrl(item.url),
    ).toSet();
    final seenTitles = known.map(
      (item) => item.type + ':' + item.year.toString() + ':' +
          normalized(item.title),
    ).toSet();
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final type = row['type'] == 'series' ? 'tv' : 'movie';
      final urlKey = type + ':' + cleanUrl((row['url'] ?? '').toString());
      final titleKey = keyFor(row);
      if (seenUrls.contains(urlKey) || seenTitles.contains(titleKey)) continue;
      seenUrls.add(urlKey);
      seenTitles.add(titleKey);
      result.add(Map<String, dynamic>.from(row));
      if (result.length >= limit) break;
    }
    return result;
  }

  static Map<String, dynamic> withVerifiedDetail(
      Map<String, dynamic> row, Object? rawDetail) {
    // The caller only invokes this after exact HTTPS host/path verification.
    final result = Map<String, dynamic>.from(row);
    if (rawDetail is! Map) return result;
    final names = parseGenreLabels(rawDetail['genres']);
    final alreadyHasGenres =
        parseGenreLabels(result['genres']).isNotEmpty;
    if (names.isNotEmpty && !alreadyHasGenres) {
      result['genres'] = names;
      result['genre_data_source'] = 'lk21_source';
    }
    final poster = validPoster(rawDetail['poster_url']);
    if ((result['poster_url'] ?? '').toString().isEmpty && poster.isNotEmpty) {
      result['poster_url'] = poster;
    }
    return result;
  }
}
