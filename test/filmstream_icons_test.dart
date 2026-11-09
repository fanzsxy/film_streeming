import 'package:filmstream_personal/filmstream_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

void main() {
  test('main tabs use one Phosphor family with solid selected states', () {
    expect(FilmStreamIcons.home, PhosphorIconsRegular.house);
    expect(FilmStreamIcons.homeSelected, PhosphorIconsFill.house);
    expect(FilmStreamIcons.film, PhosphorIconsRegular.filmSlate);
    expect(FilmStreamIcons.filmSelected, PhosphorIconsFill.filmSlate);
    expect(FilmStreamIcons.series, PhosphorIconsRegular.monitorPlay);
    expect(FilmStreamIcons.seriesSelected, PhosphorIconsFill.monitorPlay);
    expect(FilmStreamIcons.filter, PhosphorIconsRegular.slidersHorizontal);
    expect(FilmStreamIcons.filterSelected, PhosphorIconsFill.slidersHorizontal);
    expect(FilmStreamIcons.favorites, PhosphorIconsRegular.heart);
    expect(FilmStreamIcons.favoritesSelected, PhosphorIconsFill.heart);
  });

  test('genre IDs remain distinct, including TV subgenres and fallback', () {
    expect(FilmStreamIcons.genre(28), PhosphorIconsFill.lightning);
    expect(FilmStreamIcons.genre(12), PhosphorIconsFill.compass);
    expect(FilmStreamIcons.genre(10759), PhosphorIconsFill.mapTrifold);
    expect(FilmStreamIcons.genre(16), PhosphorIconsFill.filmStrip);
    expect(FilmStreamIcons.genre(35), PhosphorIconsFill.smiley);
    expect(FilmStreamIcons.genre(80), PhosphorIconsFill.detective);
    expect(FilmStreamIcons.genre(18), PhosphorIconsFill.maskHappy);
    expect(FilmStreamIcons.genre(10765), PhosphorIconsFill.alien);
    expect(FilmStreamIcons.genre(27), PhosphorIconsFill.ghost);
    expect(FilmStreamIcons.genre(10749), PhosphorIconsFill.heart);
    expect(FilmStreamIcons.genre(878), PhosphorIconsFill.rocketLaunch);
    expect(FilmStreamIcons.genre(10752), PhosphorIconsFill.shieldChevron);
    expect(FilmStreamIcons.genre(-1), PhosphorIconsFill.tag);
  });

  testWidgets('genre and navigation glyphs render in a dark UI',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: const Center(
          child: Icon(
            PhosphorIconsFill.lightning,
            color: Color(0xffe5aa55),
            size: 29,
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: 0,
          destinations: const [
            NavigationDestination(
              icon: Icon(FilmStreamIcons.home),
              selectedIcon: Icon(FilmStreamIcons.homeSelected),
              label: 'Beranda',
            ),
            NavigationDestination(
              icon: Icon(FilmStreamIcons.film),
              selectedIcon: Icon(FilmStreamIcons.filmSelected),
              label: 'Film',
            ),
            NavigationDestination(
              icon: Icon(FilmStreamIcons.series),
              selectedIcon: Icon(FilmStreamIcons.seriesSelected),
              label: 'Series',
            ),
            NavigationDestination(
              icon: Icon(FilmStreamIcons.filter),
              selectedIcon: Icon(FilmStreamIcons.filterSelected),
              label: 'Filter',
            ),
            NavigationDestination(
              icon: Icon(FilmStreamIcons.favorites),
              selectedIcon: Icon(FilmStreamIcons.favoritesSelected),
              label: 'Favorit',
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Beranda'), findsOneWidget);
    expect(find.text('Film'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    expect(find.text('Filter'), findsOneWidget);
    expect(find.text('Favorit'), findsOneWidget);
    expect(find.byIcon(PhosphorIconsFill.lightning), findsOneWidget);
    expect(find.byIcon(FilmStreamIcons.homeSelected), findsOneWidget);
  });
}
