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
