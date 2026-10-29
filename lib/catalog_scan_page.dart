import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'filmstream_catalog.dart';

/// User-initiated, visible-page metadata scan. Never navigates around access denial.
class CatalogScanPage extends StatefulWidget {
  const CatalogScanPage({super.key});
  @override State<CatalogScanPage> createState() => _CatalogScanPageState();
}

class _CatalogScanPageState extends State<CatalogScanPage> {
  static const _key = 'filmstream_local_catalog_v1';
  static const _hosts = {'movie': 'tv12.lk21official.cc', 'series': 'tv.lk21online.de'};
  late final WebViewController controller;
  String kind = 'movie';
  String status = 'Buka halaman, lalu tekan Scan halaman ini.';
  bool busy = false;
  int added = 0;

  @override void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest:(request) {
          final uri = Uri.tryParse(request.url);
          if (uri == null || uri.scheme != 'https' || uri.host != _hosts[kind]) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onWebResourceError:(error) {
          if (mounted && error.isForMainFrame == true) {
            setState(()=>status='Halaman tidak dapat dibuka: ${error.description}');
          }
        },
      ));
    _open();
  }

  void _open() {
    final path = kind == 'movie' ? '/latest' : '/latest-series';
    controller.loadRequest(Uri.https(_hosts[kind]!, path));
    setState(()=>status='Memuat halaman sumber. Scan hanya dilakukan ketika tombol ditekan.');
  }

  Future<void> _scan() async {
    if (busy) return;
    setState(() { busy=true; status='Membaca metadata halaman yang tampil…'; });
    try {
      final uri = await controller.currentUrl();
      final current = Uri.tryParse(uri ?? '');
      if (current == null || current.scheme != 'https' || current.host != _hosts[kind]) {
        throw StateError('Alamat halaman bukan sumber yang diizinkan.');
      }
      final raw = await controller.runJavaScriptReturningResult(r'''(() => {
        const rows = [];
        for (const a of document.querySelectorAll('a[href]')) {
          const u = new URL(a.getAttribute('href'), location.href);
          if (u.protocol !== 'https:' || u.host !== location.host || u.search || u.hash) continue;
          const m = u.pathname.replace(/\/$/, '').match(/-(19\d{2}|20\d{2})$/);
          if (!m) continue;
          const card = a.closest('article,li,.item,.poster,.movie,.series,.film');
          if (!card || !card.querySelector('img,h2,h3,h4,.title,.poster-title')) continue;
          const heading=card.querySelector('h2,h3,h4,.title,.poster-title');
          const img=card.querySelector('img');
          const title=(heading?.textContent || a.title || img?.alt || '').trim().replace(/\s+/g,' ');
          if (!title || title.length > 180) continue;
          rows.push({title,year:Number(m[1]),url:u.origin+u.pathname,type:'__KIND__'});
        }
        return JSON.stringify(rows.slice(0,200));
      })()'''.replaceAll('__KIND__', kind));
      dynamic parsed = raw;
      if (parsed is String) parsed = jsonDecode(parsed);
      if (parsed is String) parsed = jsonDecode(parsed);
      if (parsed is! List) throw StateError('Format halaman tidak dikenali.');
      final existing = await FilmStreamCatalog.load();
      final seenUrls = existing.map((e)=>'${e.type}:${e.url.replaceAll(RegExp(r'/+$'),'')}').toSet();
      final seenTitles = existing.map((e)=>'${e.type}:${e.year}:${e.title.toLowerCase().trim()}').toSet();
      final storage = await SharedPreferences.getInstance();
      final saved = <Map<String,dynamic>>[];
      try {
        final loaded=jsonDecode(storage.getString(_key) ?? '[]');
        if (loaded is List) {
          for (final row in loaded.whereType<Map>()) {
            saved.add(Map<String,dynamic>.from(row));
          }
        }
      } catch (_) {}
      var count=0;
      for (final row in parsed.whereType<Map>()) {
        final title=(row['title']??'').toString().trim();
        final year=row['year'];
        final url=(row['url']??'').toString();
        final target=Uri.tryParse(url);
        if (title.isEmpty || title.length > 180 || year is! int || year < 1900 ||
            year > DateTime.now().year+2 || target == null || target.scheme != 'https' ||
            target.host != _hosts[kind] || target.userInfo.isNotEmpty || target.hasPort) continue;
        final media=kind=='series'?'tv':'movie';
        if (!seenUrls.add('$media:${url.replaceAll(RegExp(r'/+$'),'')}')) continue;
        if (!seenTitles.add('$media:$year:${title.toLowerCase()}')) continue;
        saved.add({'title':title,'year':year,'type':kind,'url':url});
        count++;
      }
      if (count > 0) {
        final ok=await storage.setString(_key,jsonEncode(saved));
        if (!ok) throw StateError('Gagal menyimpan katalog lokal.');
        FilmStreamCatalog.refresh();
      }
      if (mounted) setState(() { added+=count;status='Ditemukan ${parsed.length} kandidat. Ditambahkan $count judul baru ke katalog lokal.'; });
    } catch (e) {
      if (mounted) setState(()=>status='Scan gagal: $e. Katalog tidak diubah.');
    } finally {
      if (mounted) setState(()=>busy=false);
    }
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar:AppBar(title:const Text('Periksa Katalog Baru')),
    body:Column(children:[
      Padding(padding:const EdgeInsets.all(12),child:Column(children:[
        SegmentedButton<String>(
          segments:const [ButtonSegment(value:'movie',label:Text('Film')),ButtonSegment(value:'series',label:Text('Series'))],
          selected:{kind},onSelectionChanged:(values) { if(busy)return;setState(()=>kind=values.first);_open(); },
        ),
        const SizedBox(height:8),
        Text(status,textAlign:TextAlign.center),
        const SizedBox(height:8),
        Row(mainAxisAlignment:MainAxisAlignment.center,children:[
          OutlinedButton.icon(onPressed:busy?null:_open,icon:const Icon(Icons.refresh),label:const Text('Muat ulang')),
          const SizedBox(width:8),
          FilledButton.icon(onPressed:busy?null:_scan,icon:const Icon(Icons.search),label:const Text('Scan halaman ini')),
        ]),
        if (added>0) Text('Total baru sesi ini: $added',style:const TextStyle(fontWeight:FontWeight.bold)),
      ])),
      Expanded(child:WebViewWidget(controller:controller)),
    ]),
  );
}
