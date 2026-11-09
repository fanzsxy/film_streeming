import 'package:flutter_test/flutter_test.dart';
import 'package:filmstream_personal/catalog_query.dart';
import 'package:filmstream_personal/filmstream_catalog.dart';

void main() {
  const entries = <CatalogEntry>[
    CatalogEntry(title: 'The World of Love', year: 2015, type: 'tv',
      url: 'https://example.org/world-love',
      genres: ['Drama', 'History', 'Romance']),
    CatalogEntry(title: 'When I Meet the Moon', year: 2026, type: 'tv',
      url: 'https://example.org/moon', genres: ['Drama', 'Romance'],
      originalLanguage: 'zh'),
    CatalogEntry(title: 'The Remarried Empress', year: 2026, type: 'tv',
      url: 'https://example.org/empress',
      genres: ['Drama', 'Fantasy', 'History', 'Romance'],
      originalLanguage: 'ko'),
    CatalogEntry(title: 'An Action Movie', year: 2025, type: 'movie',
      url: 'https://example.org/action',
      genreIds: [28, 53], genres: ['Action', 'Thriller']),
    CatalogEntry(title: 'Adventure TV', year: 2024, type: 'tv',
      url: 'https://example.org/adventure',
      genreIds: [10759], genres: ['Action & Adventure']),
    CatalogEntry(title: 'Biography Movie', year: 2022, type: 'movie',
      url: 'https://example.org/biography',
      genres: ['Biography', 'Drama']),
  ];

  test('parse source genre names and TMDB IDs separately', () {
    final item = CatalogEntry.fromJson({
      'title': 'Example', 'year': 2026,
      'type': 'series', 'url': 'https://example.org/example',
      'genres': ['Drama', 'Romance'], 'genre_ids': <int>[],
      'original_language': 'ko',
    });
    expect(item.type, 'tv');
    expect(item.genres, ['Drama', 'Romance']);
    expect(item.genreIds, isEmpty);
    expect(item.originalLanguage, 'ko');
  });

  test('genre filter includes LK21-only records without TMDB IDs', () {
    final index = CatalogQueryIndex.fromEntries(entries);
    final drama = index.select('catalog/filter', type: 'all',
        params: {'genre1': '18', 'sort': 'latest'});
    expect(drama.total, 4);
    expect(drama.items.first.title, 'The Remarried Empress');
    expect(drama.items.any((e) => e.title == 'When I Meet the Moon'), isTrue);
  });

  test('main and additional genres combine without TMDB', () {
    final index = CatalogQueryIndex.fromEntries(entries);
    final selection = index.select('catalog/filter', type: 'all',
        params: {'genre1': '18', 'genre2': '10749'});
    expect(selection.total, 3);
    expect(selection.items.every((e) => e.genres.contains('Romance')), isTrue);
  });

  test('filter and home genres use actual catalog data', () {
    final index = CatalogQueryIndex.fromEntries(entries);
    expect(index.availableGenres.any((g) =>
        g.key == 900001 && g.value == 'Biography'), isTrue);
    expect(index.select('catalog/filter',
        params: {'genre1': '10749'}).total, 3);
    expect(index.select('home/family', type: 'movie').total, 0);
    expect(index.availableLanguages, containsAll(['zh', 'ko']));
  });

  test('search spans film and series, See All shares catalog', () {
    final index = CatalogQueryIndex.fromEntries(entries);
    final found = index.select('search/multi', type: 'movie',
        params: {'query': 'the'});
    expect(found.total, 3);
    expect(found.items.every((e) => e.type == 'tv'), isTrue);
    expect(index.select('tv/popular', type: 'tv').total, 4);
    expect(index.select('catalog/movie', type: 'movie').total, 2);
  });

  test('language filter excludes unknown languages', () {
    final index = CatalogQueryIndex.fromEntries(entries);
    final korean = index.select('catalog/filter', type: 'tv',
        params: {'language': 'ko', 'genre1': '18'});
    expect(korean.total, 1);
    expect(korean.items.single.title, 'The Remarried Empress');
  });

  test('20 per page, stable ordering and no repeated results', () {
    final many = [
      for (var i = 0; i < 45; i++)
        CatalogEntry(
          title: 'Film ' + i.toString().padLeft(3, '0'),
          year: 2020 + i % 3,
          type: 'movie', url: 'https://example.org/' + i.toString(),
          genres: ['Drama'],
        ),
    ];
    final index = CatalogQueryIndex.fromEntries(many);
    final pages = [
      for (var p = 1; p <= 3; p++)
        index.select('catalog/filter', page: p,
            params: {'genre1': '18', 'sort': 'title'}),
    ];
    expect(pages.map((p) => p.items.length).toList(), [20, 20, 5]);
    expect(pages.first.pages, 3);
    final all = pages.expand((p) => p.items).map((e) => e.url).toList();
    expect(all.toSet().length, 45);
    expect(index.select('catalog/filter', page: 4).items, isEmpty);
  });
}
