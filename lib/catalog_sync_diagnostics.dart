import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shows the current *on-device* scanner and upload state without exposing
/// credentials. A visible film on Home is not proof of a WebView scan or PR.
class CatalogSyncDiagnostics {
  static const _localKey = 'filmstream_local_catalog_v1';
  static const _pendingKey = 'filmstream_auto_sync_pending_v1';
  static const _sentKey = 'filmstream_auto_sync_sent_v1';
  static const _statusKey = 'filmstream_auto_sync_status_v1';
  static const _syncStatusKey = 'filmstream_auto_sync_upload_status_v1';
  static const _lastPrKey = 'filmstream_auto_sync_last_pr_v1';
  static const _scanStartedKey = 'filmstream_auto_sync_scan_started_v1';
  static const _scanFinishedKey = 'filmstream_auto_sync_scan_finished_v1';
  static const _syncTimeKey = 'filmstream_auto_sync_upload_checked_v1';

  static int _listCount(String? raw) {
    if (raw == null) return 0;
    try {
      final data = jsonDecode(raw);
      return data is List ? data.length : 0;
    } catch (_) {
      return 0;
    }
  }

  static String _time(int? timestamp) {
    if (timestamp == null) return 'Belum tercatat';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  static Future<void> show(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final isWindows = Platform.isWindows;
    final started = prefs.getInt(_scanStartedKey);
    final finished = prefs.getInt(_scanFinishedKey);
    final latestScan = prefs.getString(_statusKey) ?? 'Belum ada laporan scanner.';
    final latestSync = prefs.getString(_syncStatusKey) ??
        'Belum ada laporan pengiriman ke backend.';
    final lastPr = prefs.getString(_lastPrKey) ?? '';
    final localCount = _listCount(prefs.getString(_localKey));
    final pendingCount = _listCount(prefs.getString(_pendingKey));
    final sentCount = _listCount(prefs.getString(_sentKey));
    final syncTime = prefs.getInt(_syncTimeKey);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isWindows ? 'Status katalog & GitHub'
            : 'Status scanner & GitHub'),
        content: SizedBox(
          width: 370,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(isWindows ? 'Data lokal di Windows' : 'Data lokal di HP',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('Tambahan tersimpan: $localCount judul'),
                Text('Menunggu pengiriman: $pendingCount judul'),
                Text('Pernah dikonfirmasi backend: $sentCount judul'),
                const SizedBox(height: 12),
                if (isWindows) ...[
                  const Text('Pembaruan katalog Windows',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Text('Windows membaca penambahan yang sudah '
                      'disetujui dari katalog GitHub. Pemindaian WebView '
                      'LK21 otomatis hanya berjalan pada aplikasi Android.'),
                ] else ...[
                  const Text('Pemindaian LK21',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('Mulai: ${_time(started)}'),
                  Text('Selesai: ${_time(finished)}'),
                  SelectableText(latestScan),
                ],
                const SizedBox(height: 12),
                const Text('Pengiriman GitHub',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Terakhir diperiksa: ${_time(syncTime)}'),
                SelectableText(latestSync),
                if (lastPr.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('PR pengiriman terakhir:'),
                  SelectableText(lastPr),
                ],
                const SizedBox(height: 12),
                Text(
                  isWindows
                      ? 'Film Terbaru dapat berasal dari katalog bawaan '
                        'atau hasil review GitHub. Memasang aplikasi '
                        'Windows tidak membuat PR scanner LK21 baru.'
                      : 'Film Terbaru di Beranda juga dapat berasal dari '
                        'katalog bawaan. PR hanya dibuat jika ada judul '
                        'lokal baru dan backend berhasil menerima kiriman.',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                const Text(
                  'FilmStream Personal menggunakan metadata dari TMDB, '
                  'tetapi tidak disponsori atau disertifikasi oleh TMDB.',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }
}
