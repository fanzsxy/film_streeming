import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:filmstream_personal/main.dart';
import 'package:filmstream_personal/filmstream_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local search returns catalog results without TMDB requests', () async {
    SharedPreferences.setMockInitialValues({});
    final catalog = await FilmStreamCatalog.load();
    final term = catalog.first.title.toLowerCase();
    final results = await Tmdb.list('search/multi', page: 1,
      params: {'query': term, 'include_adult': 'false'}, type: 'movie');
    expect(results, isNotEmpty);
    expect(results.first.sourceUrl, isNotEmpty);
    expect(results.first.title.toLowerCase().contains(term), isTrue);
  });

  testWidgets('numbered pages support previous and next', (tester) async {
    int selected = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CatalogPageControls(page: 2, maxPage: 12,
        busy: false, hasNext: true, onSelect: (n) => selected = n),
    )));
    expect(find.text('Halaman 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Halaman berikutnya'));
    expect(selected, 3);
    await tester.tap(find.byTooltip('Halaman sebelumnya'));
    expect(selected, 1);
  });

  testWidgets('single actual page never shows page 2 or 3', (tester) async {
    int selected = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CatalogPageControls(page: 1, maxPage: 1,
        busy: false, hasNext: false, onSelect: (n) => selected = n),
    )));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsNothing);
    await tester.tap(find.byTooltip('Halaman berikutnya'));
    expect(selected, 0);
  });

  testWidgets('filter does not number unverified next page', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CatalogPageControls(page: 1, maxPage: 2, displayedMaxPage: 1,
        busy: false, hasNext: true, onSelect: (_) {}),
    )));
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsNothing);
    await tester.tap(find.text('Lompat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '2');
    await tester.tap(find.text('Buka'));
    await tester.pumpAndSettle();
    expect(find.text('Halaman 1'), findsOneWidget);
  });

  testWidgets('filter page 8 shows 7, 8 and next candidate 9', (tester) async {
    int selected = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CatalogPageControls(page: 8, maxPage: 9, displayedMaxPage: 9,
        busy: false, hasNext: true, onSelect: (n) => selected = n),
    )));
    expect(find.text('7'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    await tester.tap(find.text('9'));
    expect(selected, 9);
  });

  testWidgets('filter hides next number after reaching last page', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CatalogPageControls(page: 8, maxPage: 8, displayedMaxPage: 8,
        busy: false, hasNext: false, onSelect: (_) {}),
    )));
    expect(find.text('9'), findsNothing);
    final nextButton = find.ancestor(
      of: find.byTooltip('Halaman berikutnya'),
      matching: find.byType(IconButton),
    );
    expect(nextButton, findsOneWidget);
    expect(tester.widget<IconButton>(nextButton).onPressed, isNull);
  });

  testWidgets('jump to a numbered page', (tester) async {
    int selected = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CatalogPageControls(page: 1, maxPage: 100,
        busy: false, hasNext: true, onSelect: (n) => selected = n),
    )));
    await tester.tap(find.text('Lompat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '85');
    await tester.tap(find.text('Buka'));
    await tester.pumpAndSettle();
    expect(selected, 85);
  });

  testWidgets('next button disabled when no further page', (tester) async {
    int selected = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      CatalogPageControls(page: 1, maxPage: 100,
        busy: false, hasNext: false, onSelect: (n) => selected = n),
    )));
    await tester.tap(find.byTooltip('Halaman berikutnya'));
    expect(selected, 0);
  });
}
