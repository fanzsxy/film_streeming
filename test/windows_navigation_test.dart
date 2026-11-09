import 'package:filmstream_personal/filmstream_icons.dart';
import 'package:filmstream_personal/windows_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Windows sidebar uses exactly the same five tabs and icon states',
      (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: StatefulBuilder(builder: (context, update) => Scaffold(
        body: Row(children: [
          WindowsNavigationRail(
            availableWidth: 1200,
            selectedIndex: selected,
            onSelected: (index) => update(() => selected = index),
          ),
          const Expanded(child: SizedBox()),
        ]),
      )),
    ));
    await tester.pumpAndSettle();

    expect(FilmStreamIcons.navigationLabels,
        ['Beranda', 'Film', 'Series', 'Filter', 'Favorit']);
    for (var index = 0; index < 5; index++) {
      expect(find.byKey(ValueKey('windows-nav-$index')), findsOneWidget);
      expect(find.text(FilmStreamIcons.navigationLabels[index]), findsOneWidget);
    }
    expect(find.byIcon(FilmStreamIcons.homeSelected), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('windows-nav-2')));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(find.byIcon(FilmStreamIcons.seriesSelected), findsOneWidget);
    expect(find.byIcon(FilmStreamIcons.home), findsOneWidget);

    // Unlike the old Windows implementation, collapsed navigation retains
    // all five reachable destinations rather than leaving an empty rail.
    await tester.tap(find.byKey(const ValueKey('windows-nav-toggle')));
    await tester.pumpAndSettle();
    for (var index = 0; index < 5; index++) {
      expect(find.byKey(ValueKey('windows-nav-$index')), findsOneWidget);
    }
    expect(find.text('Film'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('windows-nav-4')));
    await tester.pumpAndSettle();
    expect(selected, 4);
    expect(find.byIcon(FilmStreamIcons.favoritesSelected), findsOneWidget);
  });

  testWidgets('compact Windows windows keep every navigation action',
      (tester) async {
    var selected = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          WindowsNavigationRail(
            availableWidth: 700,
            selectedIndex: 0,
            onSelected: (index) => selected = index,
          ),
          const Expanded(child: SizedBox()),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    for (var index = 0; index < 5; index++) {
      expect(find.byKey(ValueKey('windows-nav-$index')), findsOneWidget);
    }
    expect(find.text('Beranda'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('windows-nav-3')));
    expect(selected, 3);
  });
}
