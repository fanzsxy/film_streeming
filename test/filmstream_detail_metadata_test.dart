import 'package:filmstream_personal/filmstream_detail_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android and Windows share LK21-source-first synopsis fallback', () {
    expect(FilmStreamDetailMetadata.synopsis(
        source: 'Sinopsis LK21', catalog: 'Sinopsis katalog'),
        'Sinopsis LK21');
    expect(FilmStreamDetailMetadata.synopsis(
        source: '', catalog: 'Sinopsis katalog'), 'Sinopsis katalog');
    expect(FilmStreamDetailMetadata.synopsis(
        source: '  ', catalog: '  Ringkasan lokal  '), 'Ringkasan lokal');
    expect(FilmStreamDetailMetadata.synopsis(
        source: '', catalog: ''), isEmpty);
  });

  test('catalog genres precede TMDB and page genres across platforms', () {
    expect(FilmStreamDetailMetadata.genres(
      catalog: ['Drama', 'Crime'],
      tmdb: ['Action'],
      source: ['Comedy'],
    ), ['Drama', 'Crime']);
    expect(FilmStreamDetailMetadata.genres(
      catalog: [], tmdb: ['Fantasy'], source: ['Comedy'],
    ), ['Fantasy']);
    expect(FilmStreamDetailMetadata.genres(
      catalog: [], tmdb: [], source: ['Horror', 'Horror'],
    ), ['Horror']);
    expect(FilmStreamDetailMetadata.genres(
      catalog: [], tmdb: [], source: [],
    ), isEmpty);
  });

  test('Windows watch history accepts catalog-only stable negative IDs', () {
    final source = Uri.parse(
        'https://tv12.lk21official.cc/film-without-tmdb-2026');
    expect(FilmStreamDetailMetadata.canRecordOpened(-192802, source), isTrue);
    expect(FilmStreamDetailMetadata.canRecordOpened(1234, source), isTrue);
    expect(FilmStreamDetailMetadata.canRecordOpened(0, source), isFalse);
    expect(FilmStreamDetailMetadata.canRecordOpened(
        1234, Uri.parse('http://tv12.lk21official.cc/movie')), isFalse);
    expect(FilmStreamDetailMetadata.canRecordOpened(
        -1, Uri.parse('https://someone:password@tv12.lk21official.cc/a')),
        isFalse);
  });
}
