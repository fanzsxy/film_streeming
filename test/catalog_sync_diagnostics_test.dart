import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:filmstream_personal/catalog_sync_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('status dialog separates local scan from GitHub submission',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'filmstream_local_catalog_v1': jsonEncode([
        {'title': 'New Movie'}, {'title': 'New Series'},
      ]),
      'filmstream_auto_sync_pending_v1': jsonEncode([
        {'title': 'New Movie'},
      ]),
      'filmstream_auto_sync_sent_v1': jsonEncode([
        'movie:2026:older movie',
      ]),
      'filmstream_auto_sync_status_v1':
          'Scan LK21 selesai: 2 judul baru, 2 memiliki genre.',
      'filmstream_auto_sync_upload_status_v1':
          'Backend menolak pengiriman: HTTP 503. Antrean tetap di HP.',
      'filmstream_auto_sync_last_pr_v1':
          'https://github.com/fanzsxy/film_streeming/pull/279',
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Builder(builder: (context) => TextButton(
        onPressed: () => CatalogSyncDiagnostics.show(context),
        child: const Text('Cek sinkronisasi'),
      )),
    )));
    await tester.tap(find.text('Cek sinkronisasi'));
    await tester.pumpAndSettle();
    expect(find.text('Status scanner & GitHub'), findsOneWidget);
    expect(find.text('Tambahan tersimpan: 2 judul'), findsOneWidget);
    expect(find.text('Menunggu pengiriman: 1 judul'), findsOneWidget);
    expect(find.text('Pernah dikonfirmasi backend: 1 judul'), findsOneWidget);
    expect(find.textContaining('Scan LK21 selesai:'), findsOneWidget);
    expect(find.textContaining('Backend menolak pengiriman: HTTP 503'),
        findsOneWidget);
    expect(find.textContaining('/pull/279'), findsOneWidget);
    await tester.tap(find.text('Tutup'));
    await tester.pumpAndSettle();
    expect(find.text('Status scanner & GitHub'), findsNothing);
  });

  testWidgets('new installs without sync activity are not marked successful',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Builder(builder: (context) => TextButton(
        onPressed: () => CatalogSyncDiagnostics.show(context),
        child: const Text('Cek sinkronisasi'),
      )),
    )));
    await tester.tap(find.text('Cek sinkronisasi'));
    await tester.pumpAndSettle();
    expect(find.text('Tambahan tersimpan: 0 judul'), findsOneWidget);
    expect(find.text('Menunggu pengiriman: 0 judul'), findsOneWidget);
    expect(find.text('Belum ada laporan scanner.'), findsOneWidget);
    expect(find.text('Belum ada laporan pengiriman ke backend.'),
        findsOneWidget);
  });
}
