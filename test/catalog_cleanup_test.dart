import 'package:flutter_test/flutter_test.dart';
import 'package:filmstream_personal/filmstream_catalog.dart';

void main() {
  CatalogEntry item(String title, int year, String url, String type,
          {String poster = ''}) =>
      CatalogEntry(title: title, year: year, url: url,
          type: type, posterUrl: poster);

  test('movie source domain overrides a stale series label', () {
    final entry = CatalogEntry.fromJson({
      'title': 'Chosen', 'year': 2022,
      'type': 'series',
      'url': 'https://tv12.lk21official.cc/chosen-2022',
    });
    expect(entry.type, 'movie');
  });

  test('series domains override stale movie labels', () {
    for (final host in ['tv.nontondrama.vip', 'tv9.nontondrama.my',
      'tv.lk21online.de']) {
      final entry = CatalogEntry.fromJson({
        'title': 'Game of Thrones', 'year': 2011, 'type': 'movie',
        'url': 'https://$host/game-of-thrones-2011',
      });
      expect(entry.type, 'tv');
    }
  });

  test('game of thrones movie and series appears only once', () {
    final catalog = consolidateCatalogEntries([
      item('Game of Thrones', 2011,
          'https://tv12.lk21official.cc/game-of-thrones-2011',
          'movie'),
      item('Game of Thrones', 2011,
          'https://tv.nontondrama.vip/game-of-thrones-2011',
          'tv', poster: 'https://poster.example.org/got.jpg'),
    ]);
    expect(catalog.length, 1);
    expect(catalog.single.type, 'tv');
    expect(catalog.single.posterUrl, contains('got.jpg'));
  });

  test('100 Days Lies alias requires same year poster and type', () {
    final catalog = consolidateCatalogEntries([
      item('100 Days Lies', 2026,
          'https://tv9.nontondrama.my/100-days-lies-2026', 'tv',
          poster: 'https://images.example.org/100-days.jpg'),
      item('100 Days of Lies', 2026,
          'https://tv.nontondrama.vip/100-days-of-lies-2026', 'tv',
          poster: 'https://images.example.org/100-days.jpg'),
    ]);
    expect(catalog.length, 1);
    expect(catalog.single.title, '100 Days of Lies');
  });

  test('different artwork or release year are never merged as aliases', () {
    final catalog = consolidateCatalogEntries([
      item('100 Days Lies', 2026, 'https://tv9.nontondrama.my/a',
          'tv', poster: 'https://images.example.org/a.jpg'),
      item('100 Days of Lies', 2026, 'https://tv9.nontondrama.my/b',
          'tv', poster: 'https://images.example.org/b.jpg'),
      item('100 Days of Lies', 2025, 'https://tv9.nontondrama.my/c',
          'tv', poster: 'https://images.example.org/a.jpg'),
    ]);
    expect(catalog.length, 3);
  });

  test('same URL merges duplicate type without erasing valid poster', () {
    final catalog = consolidateCatalogEntries([
      item('Example', 2025,
          'https://tv12.lk21official.cc/example-2025', 'movie'),
      item('Example', 2025,
          'https://tv12.lk21official.cc/example-2025/', 'movie',
          poster: 'https://poster.example.org/example.jpg'),
    ]);
    expect(catalog.length, 1);
    expect(catalog.single.posterUrl, contains('example.jpg'));
  });

  test('different titles with no shared identity remain separate', () {
    final catalog = consolidateCatalogEntries([
      item('The Last Watch', 2019, 'https://tv12.lk21official.cc/last-watch',
          'movie'),
      item('Game of Thrones', 2011,
          'https://tv.nontondrama.vip/game-of-thrones-2011', 'tv'),
    ]);
    expect(catalog.length, 2);
  });
}
