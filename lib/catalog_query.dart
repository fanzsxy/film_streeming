import 'filmstream_catalog.dart';

/// Catalog genre labels are authoritative. TMDB IDs are only optional aliases.
/// Local-source genres remain filterable even when TMDB matching failed.
class CatalogGenres {
  static const Map<int, String> labels = {
    28: 'Action', 12: 'Adventure', 16: 'Animation', 35: 'Comedy',
    80: 'Crime', 99: 'Documentary', 18: 'Drama', 10751: 'Family',
    14: 'Fantasy', 36: 'History', 27: 'Horror', 10402: 'Music',
    9648: 'Mystery', 10749: 'Romance', 878: 'Science Fiction',
    10770: 'TV Movie', 53: 'Thriller', 10752: 'War', 37: 'Western',
    10759: 'Action & Adventure', 10762: 'Kids', 10763: 'News',
    10764: 'Reality', 10765: 'Sci-Fi & Fantasy', 10766: 'Soap',
    10767: 'Talk', 10768: 'War & Politics',
    900001: 'Biography', 900002: 'Sport', 900003: 'Musical',
  };

  static String normalize(String name) => name.toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static int? idForName(String value) {
    final name = normalize(value);
    if (name == 'sci fi' || name == 'sci fi movie') return 878;
    if (name == 'romantic') return 10749;
    if (name == 'science fiction') return 878;
    if (name == 'sports') return 900002;
    if (name == 'music' || name == 'musical drama') return 10402;
    for (final entry in labels.entries) {
      if (normalize(entry.value) == name) return entry.key;
    }
    return null;
  }

  static Set<int> idsFor(CatalogEntry entry) {
    final ids = <int>{...entry.genreIds};
    for (final name in entry.genres) {
      final id = idForName(name);
      if (id != null) ids.add(id);
    }
    // A TV "Action & Adventure" entry should also appear under Action.
    if (ids.contains(10759)) ids.add(28);
    return ids;
  }

  static List<MapEntry<int, String>> available(List<CatalogEntry> entries) {
    final present = <int>{};
    for (final entry in entries) {
      present.addAll(idsFor(entry));
    }
    final options = [
      for (final id in present)
        if (labels.containsKey(id)) MapEntry(id, labels[id]!),
    ]..sort((a, b) => a.value.compareTo(b.value));
    return options;
  }
}

class CatalogSlice {
  final List<CatalogEntry> items;
  final int total;
  const CatalogSlice(this.items, this.total);
  int get pages => (total + 19) ~/ 20;
}

/// One catalog index shared by Home, See All, Filter, and Search.
/// Filtering scans cached strings locally; no TMDB request on page changes.
class CatalogQueryIndex {
  CatalogQueryIndex._(List<CatalogEntry> source)
      : _entries = source,
        _year = List<CatalogEntry>.of(source),
        _title = List<CatalogEntry>.of(source),
        _rated = List<CatalogEntry>.of(source) {
    for (final entry in source) {
      _titles[entry] = entry.title.toLowerCase();
      _genres[entry] = CatalogGenres.idsFor(entry);
    }
    _year.sort((a, b) {
      final year = b.year.compareTo(a.year);
      return year != 0 ? year : a.title.compareTo(b.title);
    });
    _title.sort((a, b) {
      final title = _titles[a]!.compareTo(_titles[b]!);
      return title != 0 ? title : b.year.compareTo(a.year);
    });
    _rated.sort((a, b) {
      final rating = (b.rating ?? -1).compareTo(a.rating ?? -1);
      if (rating != 0) return rating;
      return b.year.compareTo(a.year);
    });
  }

  static Future<CatalogQueryIndex>? _cached;
  static Future<CatalogQueryIndex> load() =>
      _cached ??= FilmStreamCatalog.load().then(CatalogQueryIndex._);
  static void invalidate() { _cached = null; }

  final List<CatalogEntry> _entries;
  final List<CatalogEntry> _year, _title, _rated;
  final Map<CatalogEntry, String> _titles = {};
  final Map<CatalogEntry, Set<int>> _genres = {};
  List<MapEntry<int, String>> get availableGenres => CatalogGenres.available(_entries);

  List<String> get availableLanguages {
    final names = <String>{};
    for (final entry in _entries) {
      final value = entry.originalLanguage.trim().toLowerCase();
      if (RegExp(r'^[a-z]{2,3}

  static bool handles(String endpoint) =>
      endpoint.startsWith('catalog/') || endpoint == 'search/multi' ||
      endpoint.startsWith('home/') || endpoint.startsWith('trending/') ||
      endpoint.endsWith('/popular') || endpoint.endsWith('/top_rated');

  CatalogSlice select(String endpoint, {
    int page = 1,
    String type = 'all',
    Map<String, String> params = const {},
  }) {
    if (page < 1) return const CatalogSlice([], 0);
    String? selectedType = type == 'all' ? null : type;
    if (endpoint == 'search/multi' || endpoint == 'catalog/sorted' ||
        endpoint == 'catalog/filter' || endpoint == 'trending/all/week' ||
        endpoint == 'home/recommended') {
      selectedType = type == 'all' || endpoint == 'search/multi' ? null : type;
      if (endpoint == 'home/recommended') selectedType = null;
    }
    if (endpoint == 'home/latest' || endpoint == 'home/family' ||
        endpoint == 'catalog/movie' || endpoint.startsWith('movie/') ||
        endpoint == 'trending/movie/week') {
      selectedType = 'movie';
    } else if (endpoint == 'catalog/tv' || endpoint.startsWith('tv/') ||
        endpoint == 'trending/tv/week') {
      selectedType = 'tv';
    }

    final sort = params['sort'] ??
        ((endpoint.endsWith('/popular') || endpoint.endsWith('/top_rated') ||
          endpoint.startsWith('trending/') || endpoint == 'home/recommended')
        ? 'popular' : 'latest');
    final order = sort == 'title' ? _title :
        sort == 'popular' ? _rated : _year;
    final query = (params['query'] ?? '').trim().toLowerCase();
    final language = (params['language'] ?? '').trim().toLowerCase();
    final genre1 = int.tryParse(params['genre1'] ?? '') ?? 0;
    final genre2 = int.tryParse(params['genre2'] ?? '') ?? 0;
    final family = endpoint == 'home/family';
    final first = (page - 1) * 20;
    final selected = <CatalogEntry>[];
    var matches = 0;

    for (final entry in order) {
      if (selectedType != null && entry.type != selectedType) continue;
      if (query.isNotEmpty && !_titles[entry]!.contains(query)) continue;
      if (language.isNotEmpty &&
          entry.originalLanguage.toLowerCase() != language) continue;
      final ids = _genres[entry]!;
      if (genre1 != 0 && !ids.contains(genre1)) continue;
      if (genre2 != 0 && !ids.contains(genre2)) continue;
      if (family && !ids.contains(10751)) continue;
      if (matches >= first && selected.length < 20) selected.add(entry);
      matches++;
    }
    return CatalogSlice(selected, matches);
  }
}
).hasMatch(value)) names.add(value);
    }
    return names.toList()..sort();
  }

  static bool handles(String endpoint) =>
      endpoint.startsWith('catalog/') || endpoint == 'search/multi' ||
      endpoint.startsWith('home/') || endpoint.startsWith('trending/') ||
      endpoint.endsWith('/popular') || endpoint.endsWith('/top_rated');

  CatalogSlice select(String endpoint, {
    int page = 1,
    String type = 'all',
    Map<String, String> params = const {},
  }) {
    if (page < 1) return const CatalogSlice([], 0);
    String? selectedType = type == 'all' ? null : type;
    if (endpoint == 'search/multi' || endpoint == 'catalog/sorted' ||
        endpoint == 'catalog/filter' || endpoint == 'trending/all/week' ||
        endpoint == 'home/recommended') {
      selectedType = type == 'all' || endpoint == 'search/multi' ? null : type;
      if (endpoint == 'home/recommended') selectedType = null;
    }
    if (endpoint == 'home/latest' || endpoint == 'home/family' ||
        endpoint == 'catalog/movie' || endpoint.startsWith('movie/') ||
        endpoint == 'trending/movie/week') {
      selectedType = 'movie';
    } else if (endpoint == 'catalog/tv' || endpoint.startsWith('tv/') ||
        endpoint == 'trending/tv/week') {
      selectedType = 'tv';
    }

    final sort = params['sort'] ??
        ((endpoint.endsWith('/popular') || endpoint.endsWith('/top_rated') ||
          endpoint.startsWith('trending/') || endpoint == 'home/recommended')
        ? 'popular' : 'latest');
    final order = sort == 'title' ? _title :
        sort == 'popular' ? _rated : _year;
    final query = (params['query'] ?? '').trim().toLowerCase();
    final language = (params['language'] ?? '').trim().toLowerCase();
    final genre1 = int.tryParse(params['genre1'] ?? '') ?? 0;
    final genre2 = int.tryParse(params['genre2'] ?? '') ?? 0;
    final family = endpoint == 'home/family';
    final first = (page - 1) * 20;
    final selected = <CatalogEntry>[];
    var matches = 0;

    for (final entry in order) {
      if (selectedType != null && entry.type != selectedType) continue;
      if (query.isNotEmpty && !_titles[entry]!.contains(query)) continue;
      if (language.isNotEmpty &&
          entry.originalLanguage.toLowerCase() != language) continue;
      final ids = _genres[entry]!;
      if (genre1 != 0 && !ids.contains(genre1)) continue;
      if (genre2 != 0 && !ids.contains(genre2)) continue;
      if (family && !ids.contains(10751)) continue;
      if (matches >= first && selected.length < 20) selected.add(entry);
      matches++;
    }
    return CatalogSlice(selected, matches);
  }
}
