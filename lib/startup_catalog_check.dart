import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'catalog_scan_helpers.dart';
import 'filmstream_catalog.dart';

/// Each Android app launch checks newest LK21 listings through an embedded
/// WebView. Only newly discovered URLs are visited for detail genres.
/// Assets inside the APK are read-only: new catalog rows are saved in the
/// existing on-device catalog overlay (SharedPreferences) and reloaded by
/// FilmStreamCatalog, so Home/Film/Series/Filter/Search see the same records.
///
/// Ordinary WebView navigation is not an access-restriction bypass. If the
/// source rejects a request or shows a verification page, stop that source.
class StartupCatalogCheck extends StatefulWidget {
  final VoidCallback onCatalogUpdated;
  const StartupCatalogCheck({super.key, required this.onCatalogUpdated});
  @override State<StartupCatalogCheck> createState() =>
      _StartupCatalogCheckState();
}

class _StartupCatalogCheckState extends State<StartupCatalogCheck> {
  static const storageKey = 'filmstream_local_catalog_v1';
  static const pendingKey = 'filmstream_auto_sync_pending_v1';
  static const sentKey = 'filmstream_auto_sync_sent_v1';
  static const diagnosticKey = 'filmstream_auto_sync_status_v1';
  static const uploadStatusKey = 'filmstream_auto_sync_upload_status_v1';
  static const lastPrKey = 'filmstream_auto_sync_last_pr_v1';
  static const scanStartedKey = 'filmstream_auto_sync_scan_started_v1';
  static const scanFinishedKey = 'filmstream_auto_sync_scan_finished_v1';
  static const syncTimeKey = 'filmstream_auto_sync_upload_checked_v1';
  // Never embed source cookies or TMDB credentials in scanning JS.
  static const syncKey = String.fromEnvironment('FILMSTREAM_SYNC_KEY');
  static const hosts = <String, String>{
    'movie': 'tv12.lk21official.cc',
    'series': 'tv.lk21online.de',
  };
  static const paths = <String, String>{
    'movie': '/latest',
    'series': '/latest-series',
  };
  static const listingPages = 2;
  static const newItemsPerKind = 10;
  static const maxDetailPerKind = 10;
  static const pageTimeout = Duration(seconds: 32);
  static const betweenDetails = Duration(seconds: 2);
  static const renderDelay = Duration(milliseconds: 1200);

  WebViewController? controller;
  Completer<String?>? pageFinished;
  String? expectedUrl;
  bool pageRejected = false;
  bool active = false;
  bool disposed = false;
  // Scan/upload progress is intentionally not rendered on the Home screen.
  // Logs remain available only in the explicitly opened diagnostics dialog.
  Future<void> _log(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(diagnosticKey, value);
  }

  Future<void> _logSync(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(uploadStatusKey, value);
    await prefs.setInt(syncTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  void _completeNavigation(String? url) {
    final waiting = pageFinished;
    if (waiting != null && !waiting.isCompleted) waiting.complete(url);
  }

  @override void initState() {
    super.initState();
    // Existing local additions are readable immediately; the scanner never
    // delays startup navigation, posters or on-device search.
    unawaited(_startOnLaunch());
  }

  @override void dispose() {
    disposed = true;
    _completeNavigation(null);
    super.dispose();
  }

  Future<void> _startOnLaunch() async {
    if (!Platform.isAndroid) {
      unawaited(_syncAfterScan());
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(scanStartedKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.remove(scanFinishedKey);
      await _log('Pemindaian WebView LK21 dimulai.');
      final browser = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (request) {
            // Ignore subframe adverts/players. A blocked iframe is not an
            // indication that the main listing/detail navigation failed.
            if (!request.isMainFrame) return NavigationDecision.prevent;
            final target = expectedUrl;
            if (target == null) return NavigationDecision.prevent;
            final host = Uri.tryParse(target)?.host ?? '';
            if (!CatalogScanHelpers.authorizedPage(
                target, request.url, host)) {
              pageRejected = true;
              _completeNavigation(null);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (url) => _completeNavigation(url),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) _completeNavigation(null);
          },
        ));
      controller = browser;
      if (!mounted) return;
      setState(() => active = true);
      // The platform WebView has to enter the widget tree before loading.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      await _scanAll();
    } catch (error) {
      await _log('Scanner LK21 gagal: ' + error.runtimeType.toString());
    } finally {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(scanFinishedKey, DateTime.now().millisecondsSinceEpoch);
      if (mounted) setState(() => active = false);
      // Reviewing existing GitHub catalog and optional backend submissions
      // should not keep the WebView open or delay initial page rendering.
      unawaited(_syncAfterScan());
    }
  }

  Future<bool> _navigate(String url, String host) async {
    final browser = controller;
    if (!mounted || browser == null || disposed) return false;
    expectedUrl = url;
    pageRejected = false;
    final waiting = Completer<String?>();
    pageFinished = waiting;
    try {
      await browser.loadRequest(Uri.parse(url));
      final completedUrl = await waiting.future.timeout(
        pageTimeout, onTimeout: () => null,
      );
      if (completedUrl == null || pageRejected || !mounted) return false;
      await Future<void>.delayed(renderDelay);
      final actual = await browser.currentUrl() ?? '';
      if (!CatalogScanHelpers.authorizedPage(url, actual, host)) {
        return false;
      }
      // Read only text visible to users, rather than script source, when
      // checking for source-side verification and access-denied messages.
      final visible = await browser.runJavaScriptReturningResult(
        r'''(document.body ? document.body.innerText.slice(0,1800) : '')''',
      );
      if (CatalogScanHelpers.blockedPage(visible)) return false;
      return true;
    } catch (_) {
      return false;
    } finally {
      expectedUrl = null;
      pageFinished = null;
    }
  }

  static const listingScript = r'''(() => {
    // Genres can be printed directly on each /latest card (above the title).
    // Read them from the single card only; never from the site genre menu.
    const allowed = new Set([
      'action','adventure','animation','biography','comedy','crime',
      'documentary','drama','family','fantasy','history','horror',
      'musical','music','mystery','romance','sci-fi','science fiction',
      'sport','short','thriller','war','western','reality','soap','kids',
      'tv movie','war & politics','action & adventure','sci-fi & fantasy'
    ]);
    const parseGenreLine = (raw) => {
      const text = (raw||'').replace(/\s+/g,' ').trim()
        .replace(/^genres?\s*:\s*/i,'');
      if(!text || text.length>110)return null;
      const names = text.split(/\s*[,|•]\s*/).map(s=>s.trim());
      if(names.length<1 || names.length>10 ||
          !names.every(n=>allowed.has(n.toLowerCase())))return null;
      return [...new Set(names)];
    };
    const genresInside = (container) => {
      const nodes=container.querySelectorAll(
        '[class*="genre"],[class*="Genre"],[class*="meta"],' +
        '[class*="Meta"],small,p,span,div');
      for(const el of Array.from(nodes).slice(0,90)) {
        if(el.closest('nav,header,footer'))continue;
        const fromText=parseGenreLine(el.textContent);
        if(fromText)return fromText;
        // Some cards present genre names as adjacent links rather than CSV.
        if(el.className && typeof el.className==='string' &&
           /genre/i.test(el.className)){
          const anchors=Array.from(el.querySelectorAll('a'));
          if(anchors.length>=1 && anchors.length<=10){
            const names=anchors.map(x=>(x.textContent||'').trim());
            if(names.every(x=>allowed.has(x.toLowerCase())))
              return [...new Set(names)];
          }
        }
      }
      return null;
    };
    const genresNear = (card,urlPath) => {
      let scope=card;
      for(let depth=0;scope && depth<3;depth++,scope=scope.parentElement){
        // Moving up is safe only while the container includes a single
        // dated title URL (the poster and title may link to that same URL).
        const titlePaths=new Set();
        for(const link of scope.querySelectorAll('a[href]')){
          try {
            const href=new URL(link.getAttribute('href'),location.href);
            if(href.host===location.host &&
               /-(19\d{2}|20\d{2})\/?$/.test(href.pathname))
              titlePaths.add(href.pathname.replace(/\/$/,''));
            if(titlePaths.size>1)break;
          }catch(_){}
        }
        if(titlePaths.size>1 || (titlePaths.size===1 &&
           !titlePaths.has(urlPath)))break;
        const found=genresInside(scope);
        if(found)return found;
      }
      return [];
    };

    // LK21 puts the starred 0-10 score in the poster/card (e.g. ★ 7.7).
    // Only scan rating-tagged elements belonging to this one film card.
    const parseScore=(input)=>{
      const text=String(input??'').trim().replace(/\s+/g,' ');
      const match=text.match(
        /^(?:[★☆⭐]\s*)?(10(?:\.0+)?|[0-9](?:\.\d{1,2})?)(?:\s*\/\s*10)?$/
      );
      if(!match)return null;
      const value=Number(match[1]);
      return value>0 && value<=10 && Number.isFinite(value)?value:null;
    };
    const ratingInside=(scope)=>{
      const nodes=scope.querySelectorAll(
        '[class*="rating"],[class*="Rating"],[class*="score"],' +
        '[class*="Score"],[class*="imdb"],[class*="IMDB"],' +
        '[data-rating],[itemprop="ratingValue"]'
      );
      for(const el of Array.from(nodes).slice(0,40)){
        if(el.closest('header,nav,footer'))continue;
        const candidates=[
          el.getAttribute('data-rating'),
          el.getAttribute('content'),
          el.getAttribute('aria-label'),
          el.getAttribute('title'),
          el.textContent
        ];
        for(const text of candidates){
          const value=parseScore(text);
          if(value!==null)return value;
        }
        // A star icon may be a separate child from its number.
        for(const child of Array.from(
          el.querySelectorAll('span,b,strong,small')).slice(0,12)){
          const value=parseScore(child.textContent);
          if(value!==null)return value;
        }
      }
      return null;
    };
    const ratingNear=(card,urlPath)=>{
      let scope=card;
      for(let depth=0;scope && depth<3;depth++,scope=scope.parentElement){
        const titlePaths=new Set();
        for(const link of scope.querySelectorAll('a[href]')){
          try{
            const href=new URL(link.getAttribute('href'),location.href);
            if(href.host===location.host &&
               /-(19\d{2}|20\d{2})\/?$/.test(href.pathname)){
              titlePaths.add(href.pathname.replace(/\/$/,''));
            }
            if(titlePaths.size>1)break;
          }catch(_){}
        }
        if(titlePaths.size>1 ||
           (titlePaths.size===1 && !titlePaths.has(urlPath)))break;
        const rating=ratingInside(scope);
        if(rating!==null)return rating;
      }
      return null;
    };

    const items=[];
    const used=new Set();
    for(const a of document.querySelectorAll('a[href]')) {
      let url;
      try {url=new URL(a.getAttribute('href'),location.href);}catch(_){continue;}
      if(url.protocol!=='https:' || url.host!==location.host ||
          url.search || url.hash)continue;
      const path=url.pathname.replace(/\/$/,'');
      const match=path.match(/-(19\d{2}|20\d{2})$/);
      if(!match || used.has(path))continue;
      const card=a.closest(
        'article,li,.item,.poster,.movie,.series,.film,' +
        '[class*="item"],[class*="poster"],[class*="movie"]');
      if(!card)continue;
      const heading=card.querySelector('h2,h3,h4,.title,.poster-title');
      const picture=card.querySelector('img');
      if(!heading && !picture)continue;
      const title=(heading?.textContent||a.title||picture?.alt||'')
        .trim().replace(/\s+/g,' ');
      if(!title || title.length>180)continue;
      used.add(path);
      const src=picture?.getAttribute('data-src')||
        picture?.getAttribute('data-original')||
        picture?.getAttribute('data-lazy-src')||
        picture?.getAttribute('src')||'';
      let poster='';
      try {const p=new URL(src,location.href);
        if(p.protocol==='https:')poster=p.href;}catch(_){}
      items.push({
        title:title,year:Number(match[1]),url:url.origin+url.pathname,
        poster_url:poster,genres:genresNear(card,path),
        rating:ratingNear(card,path)
      });
      if(items.length>=100)break;
    }
    return JSON.stringify(items);
  })()''';

  static const detailScript = r'''(() => {
    // Read genres beside the detail H1, not the header navigation, related
    // movies, or sections after the playback controls.
    const h1=document.querySelector('h1');
    if(!h1 || !h1.textContent.trim()) return JSON.stringify({});
    const allowed=new Set([
      'Action','Adventure','Animation','Biography','Comedy','Crime',
      'Documentary','Drama','Family','Fantasy','History','Horror',
      'Musical','Music','Mystery','Romance','Sci-Fi','Science Fiction',
      'Sport','Short','Thriller','War','Western','Reality','Soap','Kids',
      'TV Movie','War & Politics','Action & Adventure','Sci-Fi & Fantasy'
    ]);
    const genres=[];
    const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT);
    walk.currentNode=h1;
    let node, count=0, anchors=0;
    while((node=walk.nextNode()) && count++<200) {
      const tag=node.tagName;
      if(['H2','H3','IFRAME','VIDEO','FOOTER'].includes(tag)) break;
      if(node.id && /player|related|recommend/i.test(node.id))break;
      if(tag==='A') {
        if(++anchors>25)break;
        const label=(node.textContent||'').trim().replace(/\s+/g,' ');
        if(/play awal|play terbaru|trailer/i.test(label))break;
        if(allowed.has(label) && !genres.includes(label))genres.push(label);
      }
      if(node.children.length===0 &&
          /play awal|play terbaru|beri rating film ini/i.test(
            (node.textContent||'').slice(0,70)))break;
    }
    const meta=document.querySelector(
      'meta[property="og:image"],meta[name="twitter:image"]');
    let poster='';
    try {const p=new URL(meta?.content||'',location.href);
      if(p.protocol==='https:')poster=p.href;}catch(_){}
    // Detail-page rating is a fallback if no score was present on the
    // listing card. Do not infer ratings from unrelated movie links.
    const parseScore=(input)=>{
      const text=String(input??'').trim().replace(/\s+/g,' ');
      const match=text.match(
        /^(?:[★☆⭐]\s*)?(10(?:\.0+)?|[0-9](?:\.\d{1,2})?)(?:\s*\/\s*10)?$/
      );
      if(!match)return null;
      const value=Number(match[1]);
      return value>0 && value<=10 && Number.isFinite(value)?value:null;
    };
    let rating=null;
    const ratingFields=document.querySelectorAll(
      '[itemprop="ratingValue"],[data-rating],.rating,.rating-value,' +
      '.imdb-rating,[class*="vote_average"]'
    );
    for(const field of Array.from(ratingFields).slice(0,25)){
      if(field.closest('nav,header,footer'))continue;
      for(const candidate of [
        field.getAttribute('data-rating'),
        field.getAttribute('content'),
        field.textContent
      ]){
        rating=parseScore(candidate);
        if(rating!==null)break;
      }
      if(rating!==null)break;
    }
    return JSON.stringify({genres:genres.slice(0,10),
      poster_url:poster,rating:rating});
  })()''';

  Future<List<Map<String, dynamic>>?> _listPage(
      String kind, int pageNumber) async {
    final host = hosts[kind]!;
    final path = paths[kind]! +
        (pageNumber == 1 ? '' : '/page/' + pageNumber.toString());
    if (!await _navigate(Uri.https(host, path).toString(), host)) return null;
    final browser = controller!;
    for (var attempt=0; attempt<2; attempt++) {
      try {
        final raw = await browser.runJavaScriptReturningResult(listingScript);
        final data = CatalogScanHelpers.decoded(raw);
        if (data is List && data.isNotEmpty) {
          final rows = [
            for (final row in data)
              if (CatalogScanHelpers.listingRow(
                      row, kind, host, DateTime.now().year) case final found?)
                found,
          ];
          if (rows.isNotEmpty) return rows;
        }
      } catch (_) { /* One same-page DOM retry. */ }
      if(attempt==0) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if(!mounted || !CatalogScanHelpers.authorizedPage(
            Uri.https(host,path).toString(),
            await browser.currentUrl() ?? '', host)) return null;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _detail(
      String kind, Map<String, dynamic> row) async {
    final host = hosts[kind]!;
    final url = (row['url'] ?? '').toString();
    if (!await _navigate(url, host)) return row;
    try {
      final raw = await controller!.runJavaScriptReturningResult(detailScript);
      final detail = CatalogScanHelpers.decoded(raw);
      return CatalogScanHelpers.withVerifiedDetail(row, detail);
    } catch (_) {
      return row;
    }
  }

  Future<void> _scanAll() async {
    final prefs = await SharedPreferences.getInstance();
    final catalog = await FilmStreamCatalog.load();
    final oldLocal = prefs.getString(storageKey) ?? '[]';
    final decoded = CatalogScanHelpers.decoded(oldLocal);
    final saved = <Map<String, dynamic>>[
      if(decoded is List)
        for(final row in decoded)
          if(row is Map) Map<String,dynamic>.from(row),
    ];
    final known = List<CatalogEntry>.of(catalog);
    var totalAdded = 0;
    var totalGenres = 0;
    var unavailableKinds = 0;
    for (final kind in hosts.keys) {
      if(!mounted) break;
      await _log('Memeriksa ' + (kind == 'movie' ? 'film' : 'series') +
          ' terbaru LK21...');
      var available = 0;
      final candidates = <Map<String, dynamic>>[];
      for (var p=1; p<=listingPages; p++) {
        if (!mounted) break;
        final rows = await _listPage(kind,p);
        if (rows == null) {
          await _log('Scan ' + kind +
              ': daftar tidak tersedia atau akses dibatasi.');
          break;
        }
        available++;
        candidates.addAll(rows);
        if(p<listingPages) await Future<void>.delayed(betweenDetails);
      }
      if(available==0) {
        unavailableKinds++;
        continue;
      }
      final fresh = CatalogScanHelpers.onlyNew(
        known,candidates,limit:newItemsPerKind,
      );
      if(fresh.isEmpty) {
        await _log('Scan ' + kind + ': tidak ada judul baru.');
        continue;
      }
      final enriched = <Map<String,dynamic>>[];
      var fromListing = 0;
      var detailsChecked = 0;
      for (final row in fresh) {
        if (!mounted) break;
        // LK21 /latest often prints comma-separated genres on the card.
        // Skip expensive detail-page navigation when those are available.
        final cardHasGenres =
            CatalogScanHelpers.parseGenreLabels(row['genres']).isNotEmpty;
        if (cardHasGenres) fromListing++;
        // Skip navigation when both genre and rating are already on the
        // listing. A missing value can be checked on the detail page.
        if (!CatalogScanHelpers.needsDetail(row)) {
          enriched.add(row);
          if (cardHasGenres) totalGenres++;
          continue;
        }
        if (detailsChecked >= maxDetailPerKind) {
          enriched.add(row); // Preserve a new title even if genre is absent.
          continue;
        }
        if (detailsChecked > 0) {
          await Future<void>.delayed(betweenDetails);
        }
        detailsChecked++;
        final checked = await _detail(kind, row);
        enriched.add(checked);
        if (CatalogScanHelpers.parseGenreLabels(
            checked['genres']).isNotEmpty) totalGenres++;
      }
      if(enriched.isEmpty)continue;
      // Save after each source, so an error from the next source cannot
      // discard already discovered titles.
      saved.addAll(enriched);
      final written=await prefs.setString(storageKey,jsonEncode(saved));
      if(!written) {
        saved.removeRange(saved.length-enriched.length,saved.length);
        await _log('Penyimpanan katalog di HP gagal.');
        continue;
      }
      known.addAll(enriched.map(CatalogEntry.fromJson));
      totalAdded += enriched.length;
      FilmStreamCatalog.refresh();
      if(mounted)widget.onCatalogUpdated();
      await _log('Scan ' + kind + ': ' + enriched.length.toString() +
          ' judul baru, ' + fromListing.toString() +
          ' genre dari daftar, ' + detailsChecked.toString() +
          ' detail diperiksa.');
    }
    await _log((unavailableKinds == 0
        ? 'Scan LK21 selesai: '
        : 'Scan LK21 sebagian gagal (' + unavailableKinds.toString() +
          ' sumber tidak tersedia): ') +
        totalAdded.toString() + ' judul baru, ' +
        totalGenres.toString() + ' memiliki genre.');
  }

  Future<void> _syncAfterScan() async {
    try {
      await _queueUnsyncedLocal();
      await _sendPending();
      final reviewed = await FilmStreamCatalog.syncReviewedCatalog();
      if(reviewed>0 && mounted) widget.onCatalogUpdated();
    } catch (error) {
      await _logSync('Pemeriksaan backend/katalog gagal: '
          + error.runtimeType.toString() + '. Data HP tetap tersimpan.');
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
      String norm(String url)=>url.endsWith('/')?url.substring(0,url.length-1):url;
      final existingUrls=bundled.map((x)=>'${x.type}:${norm(x.url)}').toSet();
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
           existingUrls.contains('$media:${norm(url)}')||
           existingTitles.contains('$media:$year:${title.toLowerCase()}'))continue;
        pending.add(item);
        known.add(id);
        added++;
      }
      if(added>0){
        await prefs.setString(pendingKey,jsonEncode(pending));
        await _logSync('Menyiapkan $added judul lokal untuk pengiriman GitHub.');
      }
    }catch(e){
      await _logSync('Pemeriksaan antrean lokal gagal: ${e.runtimeType}.');
    }
  }

  bool sending=false;
  Future<void> _sendPending() async {
    if (sending) return;
    sending = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(pendingKey) ?? '[]';
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) {
        await _logSync('Tidak ada judul baru menunggu pengiriman; '
            'PR GitHub baru tidak dibuat.');
        return;
      }
      if (syncKey.isEmpty) {
        await _logSync('Kunci pengiriman FILMSTREAM_SYNC_KEY tidak ada '
            'di APK. Hasil scan tetap disimpan di HP.');
        return;
      }
      final batch = decoded.whereType<Map>().take(100)
          .map((row) => Map<String, dynamic>.from(row)).toList();
      if (batch.isEmpty) {
        await _logSync('Antrean pengiriman berisi data tidak valid; '
            'perlu diperiksa.');
        return;
      }
      await _logSync('Mengirim ${batch.length} judul ke backend FilmStream...');
      final response = await http.post(
        Uri.parse('https://film-streeming-api.vercel.app/catalog/submit'),
        headers: {
          'Content-Type': 'application/json',
          'X-Filmstream-Sync-Key': syncKey,
        },
        body: jsonEncode({'items': batch}),
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await _logSync('Backend menolak pengiriman: HTTP '
            '${response.statusCode}. Antrean tetap di HP.');
        return;
      }
      final body = jsonDecode(response.body);
      if (body is! Map ||
          (body['status'] != 'review_required' &&
           body['status'] != 'already_known')) {
        await _logSync('Backend belum mengonfirmasi PR atau data yang ada. '
            'Antrean tetap di HP.');
        return;
      }
      final confirmedAlready = body['status'] == 'already_known';
      final oldSent = jsonDecode(prefs.getString(sentKey) ?? '[]');
      final sent = oldSent is List
          ? oldSent.whereType<String>().toSet() : <String>{};
      sent.addAll(batch.map(_recordId));
      await prefs.setString(sentKey, jsonEncode(sent.toList()));
      await prefs.setString(pendingKey,
          jsonEncode(decoded.skip(batch.length).toList()));
      final prUrl = (body['pull_request_url'] ?? '').toString();
      if (!confirmedAlready && prUrl.startsWith(
          'https://github.com/fanzsxy/film_streeming/pull/')) {
        await prefs.setString(lastPrKey, prUrl);
      }
      if (confirmedAlready) {
        await _logSync('${batch.length} judul sudah dikenal GitHub/backend. '
            'Tidak perlu membuat PR duplikat.');
      } else {
        await _logSync('Backend menerima ${batch.length} judul dan '
            'membuat PR review: $prUrl');
        // The scanner runs silently. Confirmation is available only when
        // the user opens the status dialog from the Info icon.
      }
    } catch (error) {
      await _logSync('Pengiriman backend gagal: '
          '${error.runtimeType}. Antrean tetap di HP.');
    } finally {
      sending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final webview = controller;
    if (!active || webview == null) return const SizedBox.shrink();
    // Keep the embedded WebView mounted for browser navigation/JavaScript
    // without a visible "Memeriksa film terbaru..." bar, spinner or toast.
    // The scanner must not steal gestures or shift the Home layout.
    return SizedBox(
      width: 1,
      height: 1,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 360,
          maxWidth: 360,
          minHeight: 640,
          maxHeight: 640,
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.01,
              child: SizedBox(
                width: 360,
                height: 640,
                child: WebViewWidget(controller: webview),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
