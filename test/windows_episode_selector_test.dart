import 'package:filmstream_personal/windows_episode_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Windows episode cards preserve exact links and opened status',
      (tester) async {
    final opened = <String>{'4:2'};
    var selectedEpisode = 0;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SizedBox(width: 420, child: WindowsEpisodeSelector(
          seasons: const [1, 2, 3, 4, 5],
          selectedSeason: 4,
          episodes: List.generate(13, (index) => index + 1),
          openedEpisodes: opened,
          onSeasonSelected: (_) {},
          onEpisodeSelected: (episode) => selectedEpisode = episode,
        )),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Season & Episode'), findsOneWidget);
    expect(find.text('5 season'), findsOneWidget);
    expect(find.text('13 episode'), findsOneWidget);
    expect(find.text('Episode · Season 4'), findsOneWidget);
    expect(find.text('Pernah dibuka'), findsOneWidget);
    expect(find.byKey(const ValueKey('windows-episode-grid-4')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('windows-episode-4-1')));
    expect(selectedEpisode, 1);
    await tester.tap(find.byKey(const ValueKey('windows-episode-4-2')));
    expect(selectedEpisode, 2);
  });

  testWidgets('Windows season dropdown changes selected season cleanly',
      (tester) async {
    var season = 1;
    var chosenEpisode = 0;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: StatefulBuilder(builder: (context, update) => Scaffold(
        body: SizedBox(width: 430, child: WindowsEpisodeSelector(
          seasons: const [1, 2, 3, 4, 5],
          selectedSeason: season,
          episodes: season == 1 ? const [1, 2, 3] : const [1, 2],
          openedEpisodes: const {},
          onSeasonSelected: (number) => update(() => season = number),
          onEpisodeSelected: (number) => chosenEpisode = number,
        )),
      )),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('windows-season-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Season 2').last);
    await tester.pumpAndSettle();
    expect(season, 2);
    expect(find.text('Episode · Season 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('windows-episode-2-1')));
    expect(chosenEpisode, 1);
  });

  testWidgets('episode grid is bounded and scrolling handles long seasons',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SizedBox(width: 430, child: WindowsEpisodeSelector(
          seasons: const [1],
          selectedSeason: 1,
          episodes: List.generate(50, (index) => index + 1),
          openedEpisodes: const {},
          onSeasonSelected: (_) {},
          onEpisodeSelected: (_) {},
        )),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('50 episode'), findsOneWidget);
    expect(find.text('Gulir untuk melihat episode lainnya'), findsOneWidget);
    final height = tester.getSize(find.byKey(
        const ValueKey('windows-episode-grid-1'))).height;
    expect(height, lessThanOrEqualTo(304));
  });

  testWidgets('unknown season and pending episode loads do not invent links',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: const Scaffold(body: WindowsEpisodeSelector(
        seasons: [],
        selectedSeason: null,
        episodes: [],
        openedEpisodes: {},
        loadingSeasons: false,
        onSeasonSelected: _noop,
        onEpisodeSelected: _noop,
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Season belum ditemukan dari halaman sumber.'),
        findsOneWidget);
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('switching season disables episode links until source is ready',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: WindowsEpisodeSelector(
        seasons: const [1, 2],
        selectedSeason: 2,
        episodes: const [1, 2],
        openedEpisodes: const {},
        changingSeason: true,
        onSeasonSelected: (_) {},
        onEpisodeSelected: (_) => calls++,
      )),
    ));
    await tester.pump();
    expect(find.text('Mengganti ke Season 2...'), findsOneWidget);
    expect(find.byKey(const ValueKey('windows-episode-2-1')), findsNothing);
    expect(calls, 0);
  });
}

void _noop(int _) {}
