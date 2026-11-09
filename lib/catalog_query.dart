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

  // Build aliases once instead of normalizing every genre label for
  // every one of the 34k catalog entries at startup.
  static final Map<String, int> _idsByName = {
    for (final entry in labels.entries) normalize(entry.value): entry.key,
    'sci fi': 878, 'sci fi movie': 878,
    'romantic': 10749, 'sports': 900002,
    'musical drama': 10402,
  };
  static int? idForName(String value) => _idsByName[normalize(value)];

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


 // LOCALIZED LANGUAGE DROPDOWN: only language codes we can name reliably.
 // Order by how many catalogue titles actually use that language, not by code.
class CatalogLanguageOptions {
  static const names = <String,String>{
    'af':'Afrikaans', 'ak':'Akan', 'am':'Amharik', 'ar':'Arab',
    'az':'Azerbaijan', 'be':'Belarusia', 'bg':'Bulgaria',
    'bn':'Bengali', 'bs':'Bosnia', 'ca':'Katalan', 'cs':'Ceko',
    'cy':'Wales', 'da':'Denmark', 'de':'Jerman', 'el':'Yunani',
    'en':'Inggris', 'es':'Spanyol', 'et':'Estonia', 'eu':'Basque',
    'fa':'Persia', 'fi':'Finlandia', 'fil':'Filipina', 'fr':'Prancis',
    'ga':'Irlandia', 'gl':'Galisia', 'gu':'Gujarati', 'he':'Ibrani',
    'hi':'Hindi', 'hr':'Kroasia', 'hu':'Hungaria', 'hy':'Armenia',
    'id':'Indonesia', 'is':'Islandia', 'it':'Italia', 'ja':'Jepang',
    'jv':'Jawa', 'ka':'Georgia', 'kk':'Kazakh', 'km':'Khmer',
    'kn':'Kannada', 'ko':'Korea', 'ky':'Kirgiz', 'lo':'Lao',
    'lt':'Lituania', 'lv':'Latvia', 'mg':'Malagasi', 'mk':'Makedonia',
    'ml':'Malayalam', 'mn':'Mongolia', 'mr':'Marathi', 'ms':'Melayu',
    'my':'Burma', 'ne':'Nepali', 'nl':'Belanda', 'no':'Norwegia',
    'pa':'Punjabi', 'pl':'Polandia', 'pt':'Portugis', 'ro':'Rumania',
    'ru':'Rusia', 'si':'Sinhala', 'sk':'Slowakia', 'sl':'Slovenia',
    'so':'Somalia', 'sq':'Albania', 'sr':'Serbia', 'su':'Sunda',
    'sv':'Swedia', 'sw':'Swahili', 'ta':'Tamil', 'te':'Telugu',
    'th':'Thailand', 'tl':'Tagalog', 'tr':'Turki', 'uk':'Ukraina',
    'ur':'Urdu', 'uz':'Uzbek', 'vi':'Vietnam', 'xh':'Xhosa',
    'yo':'Yoruba', 'zh':'Mandarin', 'zu':'Zulu',
  };

  static List<MapEntry<String,String>> available(
      List<CatalogEntry> entries, {int limit=30}) {
    if(limit<=0)return const [];
    final counts=<String,int>{};
    for(final entry in entries){
      final code=entry.originalLanguage.trim().toLowerCase();
      if(!names.containsKey(code))continue;
      counts.update(code,(n)=>n+1,ifAbsent:()=>1);
    }
    final ranked=counts.keys.toList()..sort((a,b){
      final frequency=counts[b]!.compareTo(counts[a]!);
      return frequency!=0?frequency:names[a]!.compareTo(names[b]!);
    });
    return [for(final code in ranked.take(limit)) MapEntry(code,names[code]!)];
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
  CatalogQueryIndex.fromEntries(List<CatalogEntry> entries) : this._(entries);
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
  late final List<MapEntry<int, String>> availableGenres =
      CatalogGenres.available(_entries);
  late final List<MapEntry<String, String>> availableLanguageOptions =
      CatalogLanguageOptions.available(_entries);

  List<String> get availableLanguages {
    final names = <String>{};
    final languageCode = RegExp(r'^[a-z]{2,3}' + r'$');
    for (final entry in _entries) {
      final value = entry.originalLanguage.trim().toLowerCase();
      if (languageCode.hasMatch(value)) names.add(value);
    }
    return names.toList()..sort();
  }

  // The catalog owns genre filtering, Film/Series and search. TMDB owns
  // Home's trending/popular/top-rated collections and their ordering.
  static bool handles(String endpoint) =>
      endpoint.startsWith('catalog/') || endpoint == 'search/multi' ||
      endpoint == 'home/latest';

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
      selectedType = type == 'all' || endpoint == 'search/multi' ||
          endpoint == 'trending/all/week' ? null : type;
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
    final newest = endpoint == 'home/latest';
    final latestYearLimit = DateTime.now().year + 1;
    final first = (page - 1) * 20;
    final selected = <CatalogEntry>[];
    var matches = 0;

    for (final entry in order) {
      if (selectedType != null && entry.type != selectedType) continue;
      if (newest && (entry.year < 1900 || entry.year > latestYearLimit)) continue;
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
