import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
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
  String autoStatus = 'Belum ada hasil pemeriksaan otomatis.';
  Future<void> _readAutoStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final current=prefs.getString('filmstream_auto_sync_status_v1');
    if(mounted)setState(()=>autoStatus=current ?? 'Belum ada hasil pemeriksaan otomatis.');
  }
  bool busy = false;
  int added = 0;
  String _normalizeUrl(String url) => url.endsWith('/') ? url.substring(0,url.length-1) : url;

  Future<void> _sendToGitHub() async {
    final prefs=await SharedPreferences.getInstance();
    final raw=prefs.getString(_key)??'[]';
    dynamic decoded;
    try {decoded=jsonDecode(raw);} catch (_){decoded=null;}
    if(decoded is! List || decoded.isEmpty){
      if(mounted)setState(()=>status='Belum ada data hasil scan untuk dikirim.');
      return;
    }
    final input=TextEditingController();
    final key=await showDialog<String>(context:context,builder:(dialogContext)=>AlertDialog(
      title:const Text('Kirim katalog ke GitHub'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        const Text('Masukkan kunci sinkronisasi milik server FilmStream. Data akan dibuatkan PR untuk ditinjau, bukan langsung digabung.'),
        TextField(controller:input,obscureText:true,decoration:const InputDecoration(labelText:'Kunci sinkronisasi')),
      ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(dialogContext),child:const Text('Batal')),
        FilledButton(onPressed:()=>Navigator.pop(dialogContext,input.text.trim()),child:const Text('Kirim')),
      ],
    ));
    input.dispose();
    if(key==null||key.isEmpty)return;
    if(mounted)setState((){busy=true;status='Mengirim hasil scan ke server…';});
    try{
      final response=await http.post(
        Uri.parse('https://film-streeming-api.vercel.app/catalog/submit'),
        headers:{'Content-Type':'application/json','X-Filmstream-Sync-Key':key},
        body:jsonEncode({'items':decoded}),
      ).timeout(const Duration(seconds:40));
      if(response.statusCode!=200){
        throw StateError('Server mengembalikan HTTP ${response.statusCode}. Pastikan endpoint telah dideploy dan kunci disetel.');
      }
      final result=jsonDecode(response.body) as Map<String,dynamic>;
      final link=Uri.tryParse((result['pull_request_url']??'').toString());
      if(link==null||link.scheme!='https'||link.host!='github.com')throw StateError('Respons PR tidak valid');
      if(mounted){
        setState(()=>status='Berhasil mengajukan ${result['submitted']} judul. Periksa PR di GitHub sebelum merge.');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:const Text('Pull Request katalog dibuat.'),action:SnackBarAction(label:'Buka PR',onPressed:()=>launchUrl(link,mode:LaunchMode.externalApplication))));
      }
    }catch(e){
      if(mounted)setState(()=>status='Pengiriman gagal: $e. Data tetap aman di HP.');
    }finally{
      if(mounted)setState(()=>busy=false);
    }
  }

  Future<void> _export() async {
    final prefs=await SharedPreferences.getInstance();
    final raw=prefs.getString(_key)??'[]';
    final decoded=jsonDecode(raw);
    if(decoded is! List || decoded.isEmpty){
      if(mounted)setState(()=>status='Belum ada hasil scan lokal yang bisa diekspor.');
      return;
    }
    final document={'version':1,'source':'FilmStream Android WebView','items':decoded};
    await Clipboard.setData(ClipboardData(text:const JsonEncoder.withIndent('  ').convert(document)));
    if(mounted)setState(()=>status='${decoded.length} judul disalin sebagai JSON. Tempel ke crawler/imports/phone_catalog.json di GitHub.');
  }

  @override void initState() {
    super.initState();
    _readAutoStatus();
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
          const imageValue=img?.getAttribute('data-src') || img?.getAttribute('data-original') ||
            img?.getAttribute('data-lazy-src') || img?.currentSrc || img?.src || '';
          let poster='';
          try {
            const imageUri=new URL(imageValue,location.href);
            if(imageUri.protocol==='https:')poster=imageUri.href;
          } catch (_) {}
          const ratingNode=card.querySelector('.rating,.ratings,.imdb,.vote,.score,[class*="rating"]');
          const ratingText=(ratingNode?.textContent||'').trim();
          const ratingMatch=ratingText.match(/(?:^|\\s)(10(?:\\.0)?|[0-9](?:\\.[0-9])?)(?:\\s|$)/);
          const rating=ratingMatch?Number(ratingMatch[1]):null;
          rows.push({title,year:Number(m[1]),url:u.origin+u.pathname,type:'__KIND__',poster_url:poster,rating});
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
      var updated=0;
      for (final row in parsed.whereType<Map>()) {
        final title=(row['title']??'').toString().trim();
        final year=row['year'];
        final url=(row['url']??'').toString();
        final target=Uri.tryParse(url);
        if (title.isEmpty || title.length > 180 || year is! int || year < 1900 ||
            year > DateTime.now().year+2 || target == null || target.scheme != 'https' ||
            target.host != _hosts[kind] || target.userInfo.isNotEmpty || target.hasPort) continue;
        final media=kind=='series'?'tv':'movie';
        final poster=(row['poster_url']??'').toString();
        final posterUri=Uri.tryParse(poster);
        final safePoster=posterUri!=null && posterUri.scheme=='https' && posterUri.userInfo.isEmpty
            && !posterUri.hasPort ? poster : '';
        final ratingValue=row['rating'];
        final rating=ratingValue is num && ratingValue>0 && ratingValue<=10
            ? ratingValue.toDouble() : null;
        final urlKey='$media:${_normalizeUrl(url)}';
        final titleKey='$media:$year:${title.toLowerCase()}';
        final existingIndex=saved.indexWhere((item) =>
          item['type']==kind && (
            _normalizeUrl((item['url']??'').toString())==_normalizeUrl(url) ||
            ((item['title']??'').toString().toLowerCase().trim()==title.toLowerCase() &&
              item['year']==year)));
        if(existingIndex>=0){
          final item=saved[existingIndex];
          var changed=false;
          if(safePoster.isNotEmpty && (item['poster_url']??'').toString().isEmpty){
            item['poster_url']=safePoster;changed=true;
          }
          if(rating!=null && item['rating']==null){item['rating']=rating;changed=true;}
          if(changed)updated++;
          continue;
        }
        if(seenUrls.contains(urlKey)||seenTitles.contains(titleKey))continue;
        seenUrls.add(urlKey);
        seenTitles.add(titleKey);
        saved.add({'title':title,'year':year,'type':kind,'url':url,
          if(safePoster.isNotEmpty)'poster_url':safePoster,
          if(rating!=null)'rating':rating});
        count++;
      }
      if (count > 0 || updated > 0) {
        final ok=await storage.setString(_key,jsonEncode(saved));
        if (!ok) throw StateError('Gagal menyimpan katalog lokal.');
        FilmStreamCatalog.refresh();
      }
      if (mounted) setState(() { added+=count;status='Ditemukan ${parsed.length} kandidat. Baru: $count, metadata diperbarui: $updated.'; });
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
        TextButton.icon(onPressed:busy?null:_export,icon:const Icon(Icons.copy),label:const Text('Salin JSON hasil scan ke GitHub')),
        FilledButton.tonalIcon(onPressed:busy?null:_sendToGitHub,icon:const Icon(Icons.cloud_upload_outlined),label:const Text('Kirim otomatis ke GitHub')),
        if (added>0) Text('Total baru sesi ini: $added',style:const TextStyle(fontWeight:FontWeight.bold)),
      ])),
      Expanded(child:WebViewWidget(controller:controller)),
    ]),
  );
}

