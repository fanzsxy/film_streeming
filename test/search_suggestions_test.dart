import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstream_personal/filmstream_catalog.dart';
import 'package:filmstream_personal/search_suggestions.dart';

void main() {
  const entries = <CatalogEntry>[
    CatalogEntry(title: 'The Amazing Spider-Man', year: 2012, url: 'https://example.org/a', type: 'movie'),
    CatalogEntry(title: 'Spider-Man: No Way Home', year: 2021, url: 'https://example.org/b', type: 'movie', posterUrl: 'https://poster.example/spider.jpg'),
    CatalogEntry(title: 'Spider-Man: Far From Home', year: 2019, url: 'https://example.org/c', type: 'movie'),
    CatalogEntry(title: 'Spider-Man: Far From Home', year: 2019, url: 'https://example.org/dup', type: 'movie'),
    CatalogEntry(title: 'Spirit', year: 2021, url: 'https://example.org/d', type: 'movie'),
    CatalogEntry(title: 'Other Movie', year: 2025, url: 'https://example.org/e', type: 'movie'),
  ];

  test('spi suggests local Spider-Man titles, prefix first, no duplicates', () {
    final suggestions = matchCatalogSuggestions(entries, 'SPI');
    expect(suggestions.any((entry) => entry.title == 'Spider-Man: No Way Home'), isTrue);
    expect(suggestions.first.title, 'Spider-Man: No Way Home');
    expect(suggestions.where((entry) => entry.title == 'Spider-Man: Far From Home').length, 1);
    expect(suggestions.any((entry) => entry.title == 'Other Movie'), isFalse);
  });

  test('cached index keeps ranking, source poster and case-insensitive matching', () {
    final index = CatalogSuggestionIndex(entries);
    expect(index.match('SPI').first.title, 'Spider-Man: No Way Home');
    expect(index.match('spi').first.posterUrl, 'https://poster.example/spider.jpg');
    expect(index.match('  doraemon  '), isEmpty);
  });

  testWidgets('desktop mouse click selects exact suggestion, not just title',
      (tester) async {
    const exact = CatalogEntry(
      title: 'Dora and the Search for Sol Dorado',
      year: 2025,
      url: 'https://tv12.lk21official.cc/dora-and-the-search-for-sol-dorado-2025',
      type: 'movie',
    );
    const similar = CatalogEntry(
      title: 'Dora and the Search for Sol Dorado',
      year: 2026,
      url: 'https://tv12.lk21official.cc/dora-and-the-search-for-sol-dorado-2026',
      type: 'movie',
    );
    CatalogEntry? chosen;
    final controller = TextEditingController(text: 'dora');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Column(children: [
        TextField(controller: controller, focusNode: focus),
        FilmSearchSuggestions(
          text: 'dora',
          index: Future.value(CatalogSuggestionIndex(const [exact, similar])),
          onSelected: (entry) => chosen = entry,
        ),
      ])),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    final match = find.text('Dora and the Search for Sol Dorado');
    expect(match, findsNWidgets(2));
    await tester.tap(match.last);
    await tester.pump();
    expect(identical(chosen, exact), isTrue,
        reason: 'Tap must return the 2025 catalog row, not just title text');
  });

  testWidgets('suggestions stay available during a real mouse tap',
      (tester) async {
    const entry = CatalogEntry(
      title: 'Doraemon: Nobita and the New Castle of the Undersea Devil',
      year: 2026,
      url: 'https://tv12.lk21official.cc/doraemon-2026',
      type: 'movie',
    );
    var selected = 0;
    final controller = TextEditingController(text: 'dora');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Column(children: [
        TextField(controller: controller, focusNode: focus),
        AnimatedBuilder(
          animation: focus,
          builder: (_, __) => focus.hasFocus
              ? FilmSearchSuggestions(
                  text: 'dora',
                  index: Future.value(CatalogSuggestionIndex(const [entry])),
                  onSelected: (_) => selected++,
                )
              : const SizedBox.shrink(),
        ),
      ])),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text(entry.title), findsOneWidget);
    await tester.tap(find.text(entry.title));
    await tester.pump();
    expect(selected, 1,
        reason: 'Mouse click must fire onTap before dropdown disappears');
  });

  test('empty query has no suggestions and count is bounded', () {
    expect(matchCatalogSuggestions(entries, '   '), isEmpty);
    expect(matchCatalogSuggestions(entries, 'spi', limit: 2).length, 2);
  });
}
