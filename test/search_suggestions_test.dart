import 'package:flutter_test/flutter_test.dart';
import 'package:film_streeming/filmstream_catalog.dart';
import 'package:film_streeming/search_suggestions.dart';

void main() {
  const entries = <CatalogEntry>[
    CatalogEntry(title: 'The Amazing Spider-Man', year: 2012, url: 'https://example.org/a', type: 'movie'),
    CatalogEntry(title: 'Spider-Man: No Way Home', year: 2021, url: 'https://example.org/b', type: 'movie'),
    CatalogEntry(title: 'Spider-Man: Far From Home', year: 2019, url: 'https://example.org/c', type: 'movie'),
    CatalogEntry(title: 'Spider-Man: Far From Home', year: 2019, url: 'https://example.org/dup', type: 'movie'),
    CatalogEntry(title: 'Spirit', year: 2021, url: 'https://example.org/d', type: 'movie'),
    CatalogEntry(title: 'Other Movie', year: 2025, url: 'https://example.org/e', type: 'movie'),
  ];

  test('spi suggests local Spider-Man titles, prefix first, no duplicates', () {
    final suggestions = matchCatalogSuggestions(entries, 'SPI');
    expect(suggestions.any((entry) => entry.title == 'Spider-Man: No Way Home'), isTrue);
    expect(suggestions.first.title, 'Spider-Man: No Way Home');
    expect(suggestions.where((entry) => entry.title == 'Spider-Man: Far From Home').length, 1);
    expect(suggestions.any((entry) => entry.title == 'Other Movie'), isFalse);
  });

  test('empty query has no suggestions and count is bounded', () {
    expect(matchCatalogSuggestions(entries, '   '), isEmpty);
    expect(matchCatalogSuggestions(entries, 'spi', limit: 2).length, 2);
  });
}
