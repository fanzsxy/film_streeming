import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:filmstream_personal/catalog_scan_helpers.dart';
import 'package:filmstream_personal/filmstream_catalog.dart';

void main() {
  const host = 'tv12.lk21official.cc';
  const known = <CatalogEntry>[
    CatalogEntry(title: 'Existing Film', year: 2026,
      type: 'movie', url: 'https://tv12.lk21official.cc/existing-film-2026'),
  ];

  test('listing candidates keep only allowed LK21 host and dated slugs', () {
    final row = CatalogScanHelpers.listingRow({
      'title': 'New Film', 'year': 2026,
      'url': 'https://tv12.lk21official.cc/new-film-2026',
      'poster_url': 'https://cdn.example/poster.jpg',
    }, 'movie', host, 2026);
    expect(row, isNotNull);
    expect(row!['scan_added_v2'], isTrue);
    expect(row['poster_url'], 'https://cdn.example/poster.jpg');
    expect(CatalogScanHelpers.listingRow({
      'title': 'Wrong Host', 'year': 2026,
      'url': 'https://bad.example/new-film-2026',
    }, 'movie', host, 2026), isNull);
    expect(CatalogScanHelpers.listingRow({
      'title': 'No Date', 'year': 2026,
      'url': 'https://tv12.lk21official.cc/new-film',
    }, 'movie', host, 2026), isNull);
    expect(CatalogScanHelpers.listingRow({
      'title': 'Conflicting Year', 'year': 2025,
      'url': 'https://tv12.lk21official.cc/new-film-2026',
    }, 'movie', host, 2026), isNull);
  });

  test('never trust different redirect path or host', () {
    const initial = 'https://tv12.lk21official.cc/new-film-2026';
    expect(CatalogScanHelpers.authorizedPage(
        initial, initial, host), isTrue);
    expect(CatalogScanHelpers.authorizedPage(
        initial, '$initial/', host), isTrue);
    expect(CatalogScanHelpers.authorizedPage(
        initial, 'https://tv12.lk21official.cc/login', host), isFalse);
    expect(CatalogScanHelpers.authorizedPage(
        initial, 'https://different.example/new-film-2026',host),isFalse);
    expect(CatalogScanHelpers.authorizedPage(
        initial, 'http://tv12.lk21official.cc/new-film-2026',host),isFalse);
    expect(CatalogScanHelpers.blockedPage('403 Forbidden'), isTrue);
    expect(CatalogScanHelpers.blockedPage('Verify you are human'), isTrue);
    expect(CatalogScanHelpers.blockedPage('Latest Movies'), isFalse);
  });

  test('deduplicates existing film but not different media types', () {
    final rows = [
      {
        'type': 'movie', 'title': 'Existing Film', 'year': 2026,
        'url': 'https://tv12.lk21official.cc/existing-film-2026',
      },
      {
        'type': 'movie', 'title': 'New Film', 'year': 2026,
        'url': 'https://tv12.lk21official.cc/new-film-2026',
      },
      {
        'type': 'movie', 'title': 'New Film!', 'year': 2026,
        'url': 'https://tv12.lk21official.cc/duplicate-film-2026',
      },
      {
        'type': 'series', 'title': 'New Film', 'year': 2026,
        'url': 'https://tv.lk21online.de/new-film-2026',
      },
    ];
    final fresh = CatalogScanHelpers.onlyNew(known,rows,limit:10);
    expect(fresh.length,2);
    expect(fresh[0]['title'],'New Film');
    expect(fresh[1]['type'],'series');
    expect(CatalogScanHelpers.onlyNew(known, rows, limit:1).length,1);
  });

  test('LK21 latest star ratings are accepted without guessing', () {
    expect(CatalogScanHelpers.parseRating(5.2), 5.2);
    expect(CatalogScanHelpers.parseRating('★ 7.7'), 7.7);
    expect(CatalogScanHelpers.parseRating('⭐ 8.1'), 8.1);
    expect(CatalogScanHelpers.parseRating('8/10'), 8);
    expect(CatalogScanHelpers.parseRating('10.0'), 10);
    expect(CatalogScanHelpers.parseRating('9.25'), 9.25);
    for (final invalid in [
      null, true, '', 'HD', '2026', '01:31', '11', '0',
      '7.7 votes', '5.2 2025 HD', '-1', 'NaN', '100',
    ]) {
      expect(CatalogScanHelpers.parseRating(invalid), isNull,
          reason: 'Not a source rating: ' + invalid.toString());
    }
  });

  test('scanner preserves LK21 ratings alongside genre and poster', () {
    final row = CatalogScanHelpers.listingRow({
      'title': 'Concessions',
      'year': 2025,
      'url': 'https://tv12.lk21official.cc/concessions-2025',
      'poster_url': 'https://cdn.example/concessions.jpg',
      'genres': 'Comedy, Drama',
      'rating': 5.2,
    }, 'movie', host, 2026)!;
    expect(row['rating'], 5.2);
    expect(row['genres'], ['Comedy', 'Drama']);
    expect(CatalogScanHelpers.needsDetail(row), isFalse);
    final inCatalog = CatalogEntry.fromJson(row);
    expect(inCatalog.rating, 5.2);
    expect(inCatalog.genres, ['Comedy', 'Drama']);
    expect(CatalogScanHelpers.onlyNew(known, [row]).single['rating'], 5.2);
    final bad = CatalogScanHelpers.listingRow({
      'title': 'Invalid Star', 'year': 2026,
      'url': 'https://tv12.lk21official.cc/invalid-star-2026',
      'genres': 'Drama', 'rating': '2026',
    }, 'movie', host, 2026)!;
    expect(bad.containsKey('rating'), isFalse);
    expect(CatalogScanHelpers.needsDetail(bad), isTrue);
  });

  test('detail rating fallback does not overwrite listing rating', () {
    final row = <String, dynamic>{
      'title': 'Film', 'year': 2026, 'type': 'movie',
      'url': 'https://tv12.lk21official.cc/film-2026',
      'genres': ['Drama'], 'rating': 7.7,
    };
    final matched = CatalogScanHelpers.withVerifiedDetail(row,
        {'genres': ['Horror'], 'rating': 5.0});
    expect(matched['rating'], 7.7);
    expect(matched['genres'], ['Drama']);
    final emptyScore = <String, dynamic>{
      'title': 'Other Film', 'year': 2026, 'type': 'movie',
      'url': 'https://tv12.lk21official.cc/other-film-2026',
      'genres': ['Action'],
    };
    final recovered = CatalogScanHelpers.withVerifiedDetail(emptyScore,
        {'rating': '⭐ 8.1'});
    expect(recovered['rating'], 8.1);
    expect(emptyScore.containsKey('rating'), isFalse);
    final invalid = CatalogScanHelpers.withVerifiedDetail(emptyScore,
        {'rating': '01:31'});
    expect(invalid.containsKey('rating'), isFalse);
  });

  test('genre text on LK21 latest cards is saved directly', () {
    final row = CatalogScanHelpers.listingRow({
      'title': 'Concessions',
      'year': 2025,
      'url': 'https://tv12.lk21official.cc/concessions-2025',
      'genres': 'Comedy, Drama',
    }, 'movie', host, 2026)!;
    expect(row['genres'], ['Comedy','Drama']);
    expect(row['genre_data_source'], 'lk21_source');
    // Genre is available; a detail page is only useful to recover a rating.
    expect(CatalogScanHelpers.needsDetail(row), isTrue);
    final fresh = CatalogScanHelpers.onlyNew(known,[row]);
    expect(fresh.single['genres'],['Comedy','Drama']);
    expect(CatalogEntry.fromJson(fresh.single).genres,['Comedy','Drama']);
  });

  test('LK21 listing genres accept Sci-fi, Short and optional label prefix', () {
    expect(CatalogScanHelpers.parseGenreLabels('Crime, Sci-fi'),
        ['Crime','Sci-Fi']);
    expect(CatalogScanHelpers.parseGenreLabels('Animation, Short'),
        ['Animation','Short']);
    expect(CatalogScanHelpers.parseGenreLabels('Genre: Action, Adventure'),
        ['Action','Adventure']);
    expect(CatalogScanHelpers.parseGenreLabels(
        ['Drama, Romance','Drama','Horror']),['Drama','Romance','Horror']);
    expect(CatalogScanHelpers.parseGenreLabels('Not a genre'), isEmpty);
    expect(CatalogScanHelpers.parseGenreLabels('Play Awal'), isEmpty);
    expect(CatalogScanHelpers.needsDetail(
        {'genres': 'Comedy, Drama', 'rating': 7.2}),isFalse);
    expect(CatalogScanHelpers.needsDetail(
        {'genres': 'Comedy, Drama'}),isTrue);
    expect(CatalogScanHelpers.needsDetail({'genres': []}),isTrue);
    expect(CatalogScanHelpers.needsDetail({'genres': '???'}),isTrue);
  });

  test('detail fallback never overwrites genres collected from listing', () {
    final card = {
      'type': 'movie', 'title': 'Known Card', 'year': 2026,
      'url': 'https://tv12.lk21official.cc/known-card-2026',
      'genres': ['Action', 'Adventure'],
      'genre_data_source': 'lk21_source',
      'poster_url': 'https://cdn.example/poster.jpg',
    };
    final result = CatalogScanHelpers.withVerifiedDetail(card, {
      'genres': ['Drama', 'Horror'],
      'poster_url': 'https://cdn.example/different.jpg',
    });
    expect(result['genres'],['Action','Adventure']);
    expect(result['poster_url'],'https://cdn.example/poster.jpg');
    expect(result['genre_data_source'],'lk21_source');
  });

  test('genre metadata from verified page only and never guessed', () {
    final row = {
      'type': 'movie', 'title': 'Another Listing Title',
      'year': 2026, 'url': 'https://tv12.lk21official.cc/new-film-2026',
    };
    final result = CatalogScanHelpers.withVerifiedDetail(row, {
      'genres': ['Drama', 'Romance', 'Horror', 'Horror',
        'Not A Genre', 'Play Awal', 'Action'],
      'poster_url': 'https://cdn.example/poster.jpg',
    });
    expect(result['genres'], ['Drama','Romance','Horror','Action']);
    expect(result['genre_data_source'], 'lk21_source');
    expect(result['poster_url'], 'https://cdn.example/poster.jpg');
    expect(row.containsKey('genres'),isFalse);
    final none = CatalogScanHelpers.withVerifiedDetail(row, {});
    expect(none.containsKey('genres'),isFalse);
    expect(none.containsKey('genre_data_source'),isFalse);
  });

  test('poster URLs, script decoding and scanner marker', () {
    expect(CatalogScanHelpers.validPoster('http://bad.example/image.jpg'), '');
    expect(CatalogScanHelpers.validPoster(
        'https://u:p@bad.example/image.jpg'),'');
    expect(CatalogScanHelpers.decoded(jsonEncode([
      {'title':'Example'},
    ])), isA<List>());
    expect(CatalogScanHelpers.decoded('not json'), isNull);
    final row = CatalogScanHelpers.listingRow({
      'title': 'Example', 'year': 2026,
      'url': 'https://tv12.lk21official.cc/example-2026'
    }, 'movie', host, 2026)!;
    final created = CatalogEntry.fromJson(
        Map<String,dynamic>.from(row));
    expect(created.title,'Example');
    expect(created.type,'movie');
    expect(created.genres,isEmpty);
  });
}
