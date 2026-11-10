import 'dart:async';

import 'package:filmstream_personal/windows_poster_reveal_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Windows rails show loading before first visible posters',
      (tester) async {
    final cached = Completer<void>();
    final requested = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WindowsPosterRevealGate(
          enabled: true,
          batchKey: 'home-popular-1',
          itemCount: 3,
          preloadCount: 2,
          maxWait: const Duration(seconds: 10),
          resolvePoster: (index) async => 'image-$index',
          precachePoster: (_, poster) {
            requested.add(poster);
            return cached.future;
          },
          child: const Text('Poster batch ready'),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Memuat poster...'), findsOneWidget);
    expect(find.text('Poster batch ready'), findsNothing);
    expect(requested, ['image-0', 'image-1']);

    cached.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Poster batch ready'), findsOneWidget);
    expect(find.text('Memuat poster...'), findsNothing);
  });

  testWidgets('offline image loading cannot lock Windows screen forever',
      (tester) async {
    final never = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WindowsPosterRevealGate(
          enabled: true,
          batchKey: 'home-latest',
          itemCount: 1,
          maxWait: const Duration(milliseconds: 200),
          resolvePoster: (_) async => 'poster.jpg',
          precachePoster: (_, __) => never.future,
          child: const Text('Catalog visible with fallback'),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Memuat poster...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('Catalog visible with fallback'), findsOneWidget);
  });

  testWidgets('Android retains original immediate card rendering',
      (tester) async {
    var requested = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WindowsPosterRevealGate(
          enabled: false,
          batchKey: 'android',
          itemCount: 20,
          resolvePoster: (_) async {
            requested++;
            return 'unused.jpg';
          },
          precachePoster: (_, __) => Future<void>.value(),
          child: const Text('Android shows cards immediately'),
        ),
      ),
    ));
    expect(find.text('Android shows cards immediately'), findsOneWidget);
    expect(find.text('Memuat poster...'), findsNothing);
    expect(requested, 0);
  });

  testWidgets('Windows filter sliver keeps filter/header visible while loading',
      (tester) async {
    final cached = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: Text('Filter dan urutkan')),
            WindowsPosterRevealGate(
              enabled: true,
              asSliver: true,
              batchKey: 'filter-page-2',
              itemCount: 2,
              maxWait: const Duration(seconds: 10),
              resolvePoster: (index) async => 'poster-$index',
              precachePoster: (_, __) => cached.future,
              child: const SliverToBoxAdapter(
                child: Text('All posters decoded'),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Filter dan urutkan'), findsOneWidget);
    expect(find.text('Memuat poster...'), findsOneWidget);
    expect(find.text('All posters decoded'), findsNothing);
    cached.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('All posters decoded'), findsOneWidget);
    expect(find.text('Filter dan urutkan'), findsOneWidget);
  });

  testWidgets('changing poster batch restarts the initial loading state',
      (tester) async {
    final first = Completer<void>();
    final second = Completer<void>();
    var current = 'batch-a';
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (_, setState) {
          update = setState;
          return WindowsPosterRevealGate(
            enabled: true,
            batchKey: current,
            itemCount: 1,
            maxWait: const Duration(seconds: 10),
            resolvePoster: (_) async => current,
            precachePoster: (_, poster) =>
                poster == 'batch-a' ? first.future : second.future,
            child: Text('Ready $current'),
          );
        }),
      ),
    ));
    await tester.pump();
    expect(find.text('Memuat poster...'), findsOneWidget);
    first.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Ready batch-a'), findsOneWidget);
    update(() => current = 'batch-b');
    await tester.pump();
    expect(find.text('Memuat poster...'), findsOneWidget);
    second.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Ready batch-b'), findsOneWidget);
  });
}
