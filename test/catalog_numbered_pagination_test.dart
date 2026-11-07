import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstream_personal/main.dart';

void main() {
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
