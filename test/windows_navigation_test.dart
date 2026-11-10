import 'package:filmstream_personal/filmstream_icons.dart';
import 'package:filmstream_personal/windows_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Windows menu toggle stays left of Film Streaming in the header',
      (tester) async {
    var selected = 0;
    var expanded = true;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: StatefulBuilder(builder: (context, update) => Scaffold(
        appBar: AppBar(title: Row(mainAxisSize: MainAxisSize.min, children: [
          WindowsSidebarToggleButton(
            expanded: expanded,
            onPressed: () => update(() => expanded = !expanded),
          ),
          const Icon(FilmStreamIcons.brand),
          const SizedBox(width: 8),
          const Text('FILM STREAMING'),
        ])),
        body: Row(children: [
          WindowsNavigationRail(
            availableWidth: 1200,
            expanded: expanded,
            selectedIndex: selected,
            onSelected: (index) => update(() => selected = index),
          ),
          const Expanded(child: SizedBox()),
        ]),
      )),
    ));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('windows-nav-toggle'));
    expect(find.descendant(
      of: find.byType(AppBar), matching: toggle), findsOneWidget);
    expect(tester.getTopLeft(toggle).dx,
        lessThan(tester.getTopLeft(find.text('FILM STREAMING')).dx));
    expect(find.text('FILM STREAMING'), findsOneWidget);
    expect(find.byTooltip('Sembunyikan menu'), findsOneWidget);
    for (var index = 0; index < 5; index++) {
      expect(find.byKey(ValueKey('windows-nav-$index')), findsOneWidget);
      expect(find.text(FilmStreamIcons.navigationLabels[index]), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('windows-nav-2')));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(find.byIcon(FilmStreamIcons.seriesSelected), findsOneWidget);
    expect(find.byIcon(FilmStreamIcons.home), findsOneWidget);

    // The header remains fixed while the desktop sidebar collapses.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(expanded, isFalse);
    expect(find.byTooltip('Tampilkan menu'), findsOneWidget);
    expect(find.text('FILM STREAMING'), findsOneWidget);
    expect(find.text('Film'), findsNothing);
    for (var index = 0; index < 5; index++) {
      expect(find.byKey(ValueKey('windows-nav-$index')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('windows-nav-4')));
    await tester.pumpAndSettle();
    expect(selected, 4);
    expect(find.byIcon(FilmStreamIcons.favoritesSelected), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(expanded, isTrue);
    expect(find.text('Film'), findsOneWidget);
  });

  testWidgets('compact Windows still has all five icon actions',
      (tester) async {
    var selected = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          WindowsNavigationRail(
            availableWidth: 700,
            expanded: true,
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
