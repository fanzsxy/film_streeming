import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'filmstream_catalog.dart';

/// Two short, once-per-day on-device metadata checks. No hidden navigation
/// around an access-denied page, no media requests, and no GitHub credentials.
class StartupCatalogCheck extends StatefulWidget {
  final VoidCallback onCatalogUpdated;
  const StartupCatalogCheck({super.key, required this.onCatalogUpdated});
  @override State<StartupCatalogCheck> createState() => _StartupCatalogCheckState();
}

class _StartupCatalogCheckState extends State<StartupCatalogCheck> {
  static const storageKey = 'filmstream_local_catalog_v1';
  static const timestampKey = 'filmstream_last_auto_scan_v1';
  static const pendingKey = 'filmstream_auto_sync_pending_v1';
  static const sentKey = 'filmstream_auto_sync_sent_v1';
  static const diagnosticKey = 'filmstream_auto_sync_status_v1';
  Future<void> _log(String msg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(diagnosticKey, msg);
  }
  // Set at build time via GitHub Actions secret, never commit a literal key.
  static const syncKey = String.fromEnvironment('FILMSTREAM_SYNC_KEY');
  static const hosts = {
    'movie': 'tv12.lk21official.cc',
    'series': 'tv.lk21online.de',
  };
  final controllers = <String, WebViewController>{};
  final completed = <String>{};
  bool active = false;
  bool saving = false;
  bool anyScanSucceeded = false;

  @override void initState() {
    super.initState();
    _startIfDue();
  }

  Future<void> _startIfDue() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(timestampKey) ?? 0;
    // Titles found in earlier manual scans must also be sent once. A previous
    // app version saved these locally but never placed them in the sync queue.
    await _queueUnsyncedLocal();
    // Retry unsent records from earlier sessions, even if scan is not due.
    await _sendPending();
    if (DateTime.now().millisecondsSinceEpoch - last <
        const Duration(hours: 24).inMilliseconds) {
      return;
    }
    await _log('Pemeriksaan otomatis LK21 sedang berjalan.');
    if (!mounted) return;
    for (final kind in hosts.keys) {
      final expectedHost = hosts[kind]!;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri != null && uri.scheme == 'https' &&
                    uri.host == expectedHost
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (_) => _scanOne(kind),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) _finish(kind, false);
          },
        ));
      controllers[kind] = controller;
    }
    setState(() => active = true);
    for (final kind in hosts.keys) {
      final path = kind == 'movie' ? '/latest' : '/latest-series';
      controllers[kind]!.loadRequest(Uri.https(hosts[kind]!, path));
    }
  }

  Future<void> _scanOne(String kind) async {
    if (!mounted || completed.contains(kind)) return;
    while (saving && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!mounted || completed.contains(kind)) return;
    saving = true;
    var success = false;
    try {
      final current = Uri.tryParse(await controllers[kind]!.currentUrl() ?? '');
      if (current == null || current.scheme != 'https' ||
          current.host != hosts[kind]) return;
      final raw = await controllers[kind]!.runJavaScriptReturningResult(r'''(() => {
        const records=[];
        for(const a of document.querySelectorAll('a[href]')){
          let uri;
          try { uri=new URL(a.getAttribute('href'),location.href); } catch(_) { continue; }
          if(uri.protocol!=='https:'||uri.host!==location.host||uri.search||uri.hash)continue;
          const match=uri.pathname.replace(/\/$/,'').match(/-(19\d{2}|20\d{2})$/);
          if(!match)continue;
          const card=a.closest('article,li,.item,.poster,.movie,.series,.film');
          if(!card||!card.querySelector('img,h2,h3,h4,.title,.poster-title'))continue;
          const heading=card.querySelector('h2,h3,h4,.title,.poster-title');
          const image=card.querySelector('img');
          const title=(heading?.textContent||a.title||image?.alt||'').trim().replace(/\s+/g,' ');
          if(!title||title.length>180)continue;
          const src=image?.getAttribute('data-src')||image?.getAttribute('data-original')||
            image?.getAttribute('data-lazy-src')||image?.currentSrc||image?.src||'';
          let poster='';
          try {const u=new URL(src,location.href);if(u.protocol==='https:')poster=u.href;}catch(_){}
          const scoreText=(card.querySelector('.rating,.ratings,.imdb,.score,[class*="rating"]')?.textContent||'').trim();
          const score=scoreText.match(/(?:^|\s)(10(?:\.0)?|[0-9](?:\.[0-9])?)(?=\s|$)/);
          records.push({title,year:Number(match[1]),url:uri.origin+uri.pathname,
            poster_url:poster,rating:score?Number(score[1]):null});
        }
        return JSON.stringify(records.slice(0,100));
      })()''');
      dynamic data=raw;
      if(data is String)data=jsonDecode(data);
      if(data is String)data=jsonDecode(data);
      if(data is! List || data.isEmpty){
        await _log('Scan otomatis $kind: tidak menemukan kartu judul pada halaman.');
        return;
      }
      final storage=await SharedPreferences.getInstance();
      final catalog=await FilmStreamCatalog.load();
      final saved=<Map<String,dynamic>>[];
      try {
        final decoded=jsonDecode(storage.getString(storageKey)??'[]');
        if(decoded is List){
          for(final row in decoded.whereType<Map>()) {
            saved.add(Map<String,dynamic>.from(row));
          }
        }
      }catch(_){}
      String cleanUrl(String u)=>u.endsWith('/')?u.substring(0,u.length-1):u;
      String identity(String type,int year,String title)=>
          '$type:$year:${title.toLowerCase().trim()}';
      final seenUrls=catalog.map((e)=>'${e.type}:${cleanUrl(e.url)}').toSet();
      final seenTitles=catalog.map((e)=>identity(e.type,e.year,e.title)).toSet();
      final type=kind=='series'?'tv':'movie';
      var changes=0;
      final newRecords=<Map<String,dynamic>>[];
      for(final row in data.whereType<Map>()){
        final title=(row['title']??'').toString().trim();
        final year=row['year'];
        final url=(row['url']??'').toString();
        final uri=Uri.tryParse(url);
        if(title.isEmpty||title.length>180||year is! int||
            year<1900||year>DateTime.now().year+2||uri==null||
            uri.scheme!='https'||uri.host!=hosts[kind]||uri.hasPort||
            uri.userInfo.isNotEmpty)continue;
        final poster=(row['poster_url']??'').toString();
        final posterUri=Uri.tryParse(poster);
        final safePoster=posterUri!=null&&posterUri.scheme=='https'&&
            posterUri.userInfo.isEmpty&&!posterUri.hasPort?poster:'';
        final rating=row['rating'];
        final safeRating=rating is num&&rating>0&&rating<=10?rating:null;
        final index=saved.indexWhere((r)=>r['type']==kind&&
            (cleanUrl((r['url']??'').toString())==cleanUrl(url)||
             identity(type,year,(r['title']??'').toString())==
                identity(type,year,title)));
        if(index>=0){
          final entry=saved[index];
          if(safePoster.isNotEmpty&&(entry['poster_url']??'').toString().isEmpty){
            entry['poster_url']=safePoster;changes++;
          }
          if(safeRating!=null&&entry['rating']==null){
            entry['rating']=safeRating;changes++;
          }
          continue;
        }
        if(seenUrls.contains('$type:${cleanUrl(url)}')||
            seenTitles.contains(identity(type,year,title)))continue;
        seenUrls.add('$type:${cleanUrl(url)}');
        seenTitles.add(identity(type,year,title));
        final newItem=<String,dynamic>{'type':kind,'title':title,'year':year,'url':url,
          if(safePoster.isNotEmpty)'poster_url':safePoster,
          if(safeRating!=null)'rating':safeRating};
        saved.add(newItem);
        newRecords.add(newItem);
        changes++;
      }
      if(changes>0){
        final written=await storage.setString(storageKey,jsonEncode(saved));
        if(!written)return;
        if(newRecords.isNotEmpty){
          final pending=<dynamic>[];
          try {
            final old=jsonDecode(storage.getString(pendingKey)??'[]');
            if(old is List)pending.addAll(old);
          }catch(_){}
          final known=pending.whereType<Map>().map((e)=>'${e['type']}:${e['url']}').toSet();
          for(final entry in newRecords){
            if(known.add('${entry['type']}:${entry['url']}'))pending.add(entry);
          }
          await storage.setString(pendingKey,jsonEncode(pending));
        }
        FilmStreamCatalog.refresh();
        if(mounted)widget.onCatalogUpdated();
      }
      success=true;
      anyScanSucceeded = true;
      if(newRecords.isEmpty){
        await _log('Scan otomatis $kind: ${data.length} kandidat, tidak ada judul baru.');
      } else {
        await _log('Scan otomatis $kind: ${newRecords.length} judul baru tersimpan. Mengirim ke backend.');
      }
      // Never block the catalog UI on a network request. Failed submissions
      // remain queued for the next app launch.
      await _sendPending();
    }catch(e){
      await _log('Scan otomatis $kind gagal: ${e.runtimeType}. Coba scan manual.');
      // Page may be denied, temporarily unavailable, or have changed markup.
    }finally{
      saving=false;
      _finish(kind,success);
    }
  }

  String _recordId(Map item) {
    final kind=(item['type']??'').toString();
    final title=(item['title']??'').toString().toLowerCase().trim();
    final year=(item['year']??'').toString();
    return '$kind:$year:$title';
  }

  Future<void> _queueUnsyncedLocal() async {
    try {
      final prefs=await SharedPreferences.getInstance();
      final local=jsonDecode(prefs.getString(storageKey)??'[]');
      if(local is! List||local.isEmpty)return;
      final bundled=await FilmStreamCatalog.bundledOnly();
      final existingUrls=bundled.map((x)=>'${x.type}:${x.url.replaceFirst(RegExp(r'/+
    if(sending)return;
    if(syncKey.isEmpty){
      await _log('Sinkronisasi tidak aktif: FILMSTREAM_SYNC_KEY kosong saat build.');
      return;
    }
    sending=true;
    try {
      final prefs=await SharedPreferences.getInstance();
      final raw=prefs.getString(pendingKey)??'[]';
      final decoded=jsonDecode(raw);
      if(decoded is! List||decoded.isEmpty)return;
      final batch=decoded.whereType<Map>().take(100).map(
        (entry)=>Map<String,dynamic>.from(entry)).toList();
      if(batch.isEmpty)return;
      final response=await http.post(
        Uri.parse('https://film-streeming-api.vercel.app/catalog/submit'),
        headers:{'Content-Type':'application/json','X-Filmstream-Sync-Key':syncKey},
        body:jsonEncode({'items':batch}),
      ).timeout(const Duration(seconds:30));
      if(response.statusCode==200){
        final result=jsonDecode(response.body);
        if(result is! Map||result['status']!='review_required'){
          await _log('Server tidak mengonfirmasi pembuatan PR. Data tetap tersimpan.');
          return;
        }
        final oldSent=jsonDecode(prefs.getString(sentKey)??'[]');
        final sent=oldSent is List?oldSent.whereType<String>().toSet():<String>{};
        sent.addAll(batch.map(_recordId));
        await prefs.setString(sentKey,jsonEncode(sent.toList()));
        final remaining=decoded.skip(batch.length).toList();
        await prefs.setString(pendingKey,jsonEncode(remaining));
        await _log('Berhasil mengirim ${batch.length} judul ke backend; PR dibuat: ${result['pull_request_url']}.');
      } else {
        await _log('Pengiriman ke backend gagal: HTTP ${response.statusCode}. Data tetap tersimpan di HP.');
      }
    }catch(e){
      await _log('Pengiriman ke backend gagal: ${e.runtimeType}. Data tetap tersimpan.');
      // Keep pending submissions for a later launch.
    }finally{
      sending=false;
    }
  }

  Future<void> _finish(String kind,bool success) async {
    if(!mounted||!completed.add(kind))return;
    if(completed.length==hosts.length){
      if(anyScanSucceeded){
        final prefs=await SharedPreferences.getInstance();
        await prefs.setInt(timestampKey,DateTime.now().millisecondsSinceEpoch);
      }
      if(mounted)setState(()=>active=false);
    }
  }

  @override Widget build(BuildContext context) {
    if(!active)return const SizedBox.shrink();
    return SizedBox(
      width:1,height:1,
      child:Stack(children:[
        for(final controller in controllers.values)
          IgnorePointer(child:Opacity(opacity:0,child:SizedBox(
            width:1,height:1,child:WebViewWidget(controller:controller)))),
      ]),
    );
  }
}
),'')}').toSet();
      final existingTitles=bundled.map((x)=>'${x.type}:${x.year}:${x.title.toLowerCase().trim()}').toSet();
      final rawSent=jsonDecode(prefs.getString(sentKey)??'[]');
      final sent=rawSent is List?rawSent.whereType<String>().toSet():<String>{};
      final rawPending=jsonDecode(prefs.getString(pendingKey)??'[]');
      final pending=rawPending is List
          ?rawPending.whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList()
          :<Map<String,dynamic>>[];
      final known=pending.map(_recordId).toSet();
      var added=0;
      for(final row in local.whereType<Map>()){
        final item=Map<String,dynamic>.from(row);
        final kind=item['type'];
        final media=kind=='series'?'tv':kind=='movie'?'movie':null;
        if(media==null)continue;
        final title=(item['title']??'').toString().trim();
        final year=int.tryParse((item['year']??'').toString());
        final url=(item['url']??'').toString();
        final uri=Uri.tryParse(url);
        if(title.isEmpty||year==null||year<1900||year>DateTime.now().year+2||
           uri==null||uri.scheme!='https'||uri.host!=hosts[kind]||
           uri.userInfo.isNotEmpty||uri.hasPort)continue;
        final id=_recordId(item);
        if(sent.contains(id)||known.contains(id)||
           existingUrls.contains('$media:${url.replaceFirst(RegExp(r'/+
    if(sending)return;
    if(syncKey.isEmpty){
      await _log('Sinkronisasi tidak aktif: FILMSTREAM_SYNC_KEY kosong saat build.');
      return;
    }
    sending=true;
    try {
      final prefs=await SharedPreferences.getInstance();
      final raw=prefs.getString(pendingKey)??'[]';
      final decoded=jsonDecode(raw);
      if(decoded is! List||decoded.isEmpty)return;
      final batch=decoded.whereType<Map>().take(100).map(
        (entry)=>Map<String,dynamic>.from(entry)).toList();
      if(batch.isEmpty)return;
      final response=await http.post(
        Uri.parse('https://film-streeming-api.vercel.app/catalog/submit'),
        headers:{'Content-Type':'application/json','X-Filmstream-Sync-Key':syncKey},
        body:jsonEncode({'items':batch}),
      ).timeout(const Duration(seconds:30));
      if(response.statusCode==200){
        await _log('Berhasil mengirim ${batch.length} judul ke backend; PR dibuat.');
        final remaining=decoded.skip(batch.length).toList();
        await prefs.setString(pendingKey,jsonEncode(remaining));
      } else {
        await _log('Pengiriman ke backend gagal: HTTP ${response.statusCode}. Data tetap tersimpan di HP.');
      }
    }catch(e){
      await _log('Pengiriman ke backend gagal: ${e.runtimeType}. Data tetap tersimpan.');
      // Keep pending submissions for a later launch.
    }finally{
      sending=false;
    }
  }

  Future<void> _finish(String kind,bool success) async {
    if(!mounted||!completed.add(kind))return;
    if(completed.length==hosts.length){
      if(anyScanSucceeded){
        final prefs=await SharedPreferences.getInstance();
        await prefs.setInt(timestampKey,DateTime.now().millisecondsSinceEpoch);
      }
      if(mounted)setState(()=>active=false);
    }
  }

  @override Widget build(BuildContext context) {
    if(!active)return const SizedBox.shrink();
    return SizedBox(
      width:1,height:1,
      child:Stack(children:[
        for(final controller in controllers.values)
          IgnorePointer(child:Opacity(opacity:0,child:SizedBox(
            width:1,height:1,child:WebViewWidget(controller:controller)))),
      ]),
    );
  }
}
),'')}')||
           existingTitles.contains('$media:$year:${title.toLowerCase()}'))continue;
        pending.add(item);
        known.add(id);
        added++;
      }
      if(added>0){
        await prefs.setString(pendingKey,jsonEncode(pending));
        await _log('Menyiapkan $added judul lokal yang belum ada di katalog GitHub untuk sinkronisasi.');
      }
    }catch(e){
      await _log('Pemeriksaan hasil scan lokal gagal: ${e.runtimeType}.');
    }
  }

  bool sending=false;
  Future<void> _sendPending() async {
    if(sending)return;
    if(syncKey.isEmpty){
      await _log('Sinkronisasi tidak aktif: FILMSTREAM_SYNC_KEY kosong saat build.');
      return;
    }
    sending=true;
    try {
      final prefs=await SharedPreferences.getInstance();
      final raw=prefs.getString(pendingKey)??'[]';
      final decoded=jsonDecode(raw);
      if(decoded is! List||decoded.isEmpty)return;
      final batch=decoded.whereType<Map>().take(100).map(
        (entry)=>Map<String,dynamic>.from(entry)).toList();
      if(batch.isEmpty)return;
      final response=await http.post(
        Uri.parse('https://film-streeming-api.vercel.app/catalog/submit'),
        headers:{'Content-Type':'application/json','X-Filmstream-Sync-Key':syncKey},
        body:jsonEncode({'items':batch}),
      ).timeout(const Duration(seconds:30));
      if(response.statusCode==200){
        await _log('Berhasil mengirim ${batch.length} judul ke backend; PR dibuat.');
        final remaining=decoded.skip(batch.length).toList();
        await prefs.setString(pendingKey,jsonEncode(remaining));
      } else {
        await _log('Pengiriman ke backend gagal: HTTP ${response.statusCode}. Data tetap tersimpan di HP.');
      }
    }catch(e){
      await _log('Pengiriman ke backend gagal: ${e.runtimeType}. Data tetap tersimpan.');
      // Keep pending submissions for a later launch.
    }finally{
      sending=false;
    }
  }

  Future<void> _finish(String kind,bool success) async {
    if(!mounted||!completed.add(kind))return;
    if(completed.length==hosts.length){
      if(anyScanSucceeded){
        final prefs=await SharedPreferences.getInstance();
        await prefs.setInt(timestampKey,DateTime.now().millisecondsSinceEpoch);
      }
      if(mounted)setState(()=>active=false);
    }
  }

  @override Widget build(BuildContext context) {
    if(!active)return const SizedBox.shrink();
    return SizedBox(
      width:1,height:1,
      child:Stack(children:[
        for(final controller in controllers.values)
          IgnorePointer(child:Opacity(opacity:0,child:SizedBox(
            width:1,height:1,child:WebViewWidget(controller:controller)))),
      ]),
    );
  }
}
