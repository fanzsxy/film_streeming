import 'package:filmstream_personal/catalog_poster_display.dart';
import 'package:filmstream_personal/main.dart' show Movie, MovieTile;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TMDB-first waits only for catalog entries with a verified TMDB ID', () {
    expect(CatalogPosterDisplay.waitsForVerifiedTmdb(
      poster: 'https://source.example/poster.jpg', tmdbId: 1234), isTrue);
    expect(CatalogPosterDisplay.waitsForVerifiedTmdb(
      poster: 'https://source.example/poster.jpg', tmdbId: null), isFalse);
    expect(CatalogPosterDisplay.waitsForVerifiedTmdb(
      poster: 'https://source.example/poster.jpg', tmdbId: -1234), isFalse);
    expect(CatalogPosterDisplay.waitsForVerifiedTmdb(
      poster: '/abc.jpg', tmdbId: 1234), isFalse);
    expect(CatalogPosterDisplay.waitsForVerifiedTmdb(
      poster: 'https://image.tmdb.org/t/p/w500/abc.jpg', tmdbId: 1234),
      isFalse);
    expect(CatalogPosterDisplay.waitsForVerifiedTmdb(
      poster: '', tmdbId: 1234), isTrue);
  });

  testWidgets('catalog TMDB lookup shows Home-style placeholder, no LK21 flash',
      (tester) async {
    final movie=Movie.fromJson({
      'id': 1234,
      'title': 'Sample Film',
      'poster_path': 'https://source.example/film.jpg',
      'vote_average': 8.0,
      'release_date': '2026-11-01',
      'media_type': 'movie',
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 220,
        height: 340,
        child: MovieTile(
          movie: movie,
          onTap: (_) {},
          showPoster: false,
        ),
      )),
    ));
    expect(find.text('Sample Film'), findsOneWidget);
    expect(find.text('Film  ·  2026'), findsOneWidget);
    // The app must not download or paint LK21 while a verified TMDB ID
    // is still being resolved. Placeholder and rating remain visible.
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    expect(find.text('8.0'), findsOneWidget);
  });
}
