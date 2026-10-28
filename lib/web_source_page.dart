import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// A visual reader mode for the source page. The site's actual player/iframe
/// remains in its original document. Nothing is proxied or extracted.
class WebSourcePage extends StatefulWidget {
  final String title;
  final Uri url;
  final bool focused;
  final bool embedded;
  final int tmdbId, season, episode;
  final String mediaType, year;
  final ValueChanged<Uri>? onPlayerReady;
  final ValueChanged<Uri>? onPlayIntent;
  final void Function(int positionMs, int durationMs, bool ended)? onVideoProgress;
  final VoidCallback? onFullscreenExit;
  final ValueChanged<String>? onSynopsisFound;
  const WebSourcePage({super.key, required this.title, required this.url, this.focused = false,
    this.embedded = false, this.tmdbId = 0, this.mediaType = 'movie', this.year = '', this.season = 0, this.episode = 0, this.onPlayerReady, this.onPlayIntent, this.onVideoProgress, this.onFullscreenExit, this.onSynopsisFound});
  @override
  State<WebSourcePage> createState() => _WebSourcePageState();
}

class _WebSourcePageState extends State<WebSourcePage> {
  late final WebViewController _controller;
  late bool _focused;
  bool _loading = true;
  bool _revealed = false;
  bool _search = false;
  bool _noMatch = false;
  String? _error;
  int _progress = 0;
  bool _matching = false;
  String _aiStatus = 'Gemini belum dicoba';
  bool _resolvingEpisode = false;
  int _episodeAttempts = 0;
  int _navigationGeneration = 0;
  String? _candidateUrl;
  bool _fullScreenRouteOpen = false;
  bool _fullScreenHiding = false;
  bool _readyNotified = false;
  bool _playIntentNotified = false;
  List<String> _serverNames = const [];
  List<String> _sourceGenres = const [];
  String _sourceSynopsis = '';
  List<Map<String,dynamic>> _sourceEpisodes = const [];
  String _selectedServer = '';
  bool _changingServer = false;
  final List<String> _titleAliases = [];
  final List<String> _searchQueries = [];
  final Set<String> _searchedTitles = {};
  static const _tmdbToken = String.fromEnvironment('TMDB_TOKEN');
  static const _sourceApiBase = String.fromEnvironment('SOURCE_API_BASE', defaultValue: 'https://film-streeming-api.vercel.app');


  // Follow normal HTTPS series redirects without a confirmation dialog.
  // Pop-up windows remain disabled by the Clean Player script.
  String get _matchTitle => widget.title.split(' • S').first.trim();
  bool get _isTv => widget.mediaType == 'tv' || widget.mediaType == 'series';
  String get _cacheKey => 'fs_detail_v59_${widget.mediaType}_${widget.tmdbId}_${widget.season}_${widget.episode}';
  bool get _canMatch => widget.tmdbId > 0 && widget.year.length == 4;
  String _normalizeTitle(String text) => text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  Future<void> _loadTitleAliases() async {
    _titleAliases
      ..clear()
      ..add(_matchTitle);
    _searchQueries
      ..clear()
      ..add(_matchTitle);
  }
    Future<bool> _searchNextAlias() async {
    if (!_isSearchUrl(await _controller.currentUrl())) return false;
    for (final title in _searchQueries) {
      final key = _normalizeTitle(title);
      if (key.isEmpty || !_searchedTitles.add(key)) continue;
      if (key == _normalizeTitle(_matchTitle)) continue;
      final next = widget.url.replace(path: '/search', queryParameters: {'s': title});
      if (next.scheme != 'https') return false;
      if (mounted) setState(() { _revealed = false; _loading = true; });
      await _controller.loadRequest(next);
      return true;
    }
    if (mounted) setState(() => _noMatch = true);
    return false;
  }
  bool _isSearchUrl(String? url) { final u = Uri.tryParse(url ?? ''); return u != null &&
    (u.path == '/search' || u.path == '/search/' || u.path.startsWith('/search/')); }
  Future<void> _initialLoad() async {
    _noMatch = false;
    _searchedTitles.clear();
    Uri target = widget.url;
    if (_isTv && widget.tmdbId > 0 && widget.season > 0 && widget.episode > 0) {
      final prefs = await SharedPreferences.getInstance();
      final cached = Uri.tryParse(prefs.getString(_episodeCacheKey(widget.season, widget.episode)) ?? '');
      if (cached != null && cached.scheme == 'https' && !_isSearchUrl(cached.toString())) target = cached;
    }
    if (_canMatch && _isSearchUrl(target.toString())) {
      final prefs = await SharedPreferences.getInstance();
      final cached = Uri.tryParse(prefs.getString(_cacheKey) ?? '');
      if (cached != null && cached.scheme == 'https' && cached.host == widget.url.host && !_isSearchUrl(cached.toString())) {
        target = cached; _candidateUrl = cached.toString();
      }
    }
    // A verified cached detail/episode does not need a TMDB title lookup.
    // Start opening it immediately instead of blocking playback for up to 6s.
    if (_isSearchUrl(target.toString())) {
      await _loadTitleAliases();
      _searchedTitles.add(_normalizeTitle(_matchTitle));
    }
    await _controller.loadRequest(target);
  }
  Future<bool> _geminiMatchCandidates(List<Map> candidates) async {
    // Only evaluate links actually discovered in the current source DOM.
    if (candidates.isEmpty || candidates.length > 12) { _aiStatus = 'Tidak ada kandidat untuk Gemini'; return false; }
    try {
      final base=Uri.tryParse(_sourceApiBase);
      if(base==null || base.scheme!='https' || base.host.isEmpty)return false;
      final values=<Map<String,String>>[];
      for(final c in candidates){
        final url=Uri.tryParse(c['url']?.toString()??'');
        if(url==null || url.scheme!='https' || url.host!=widget.url.host ||
           _isSearchUrl(url.toString()))continue;
        values.add({'title': c['title']?.toString()??'', 'year':c['year']?.toString()??'', 'url':url.toString()});
      }
      if(values.isEmpty){_aiStatus='Tidak ada tautan kandidat valid';return false;}
      _aiStatus='Menghubungi Gemini';
      final result=await http.post(base.replace(path:'/ai/match'),
        headers:{'Content-Type':'application/json'},
        body:jsonEncode({'title':_matchTitle,'year':widget.year,
          'media_type':_isTv?'tv':'movie','candidates':values}))
        .timeout(const Duration(seconds:10));
      if(result.statusCode!=200){_aiStatus='Backend Gemini HTTP ${result.statusCode}';return false;}
      final decoded=jsonDecode(result.body);
      if(decoded is! Map){_aiStatus='Respons Gemini tidak valid';return false;}
      if(decoded['matched']!=true){_aiStatus='Gemini: ${decoded['status'] ?? 'tidak cocok'}';return false;}
      final target=Uri.tryParse(decoded['url']?.toString()??'');
      if(target==null || !values.any((e)=>e['url']==target.toString()))return false;
      if(!mounted)return false;
      _aiStatus='Gemini menemukan kecocokan';
      _noMatch=false;
      _candidateUrl=target.toString();
      setState((){_revealed=false;_loading=true;});
      await _controller.loadRequest(target);
      return true;
    } catch (_) {_aiStatus='Gagal terhubung ke backend Gemini';return false;}
  }

  Future<bool> _autoMatchSearch() async {
    if (!_canMatch || _matching) return false;
    _matching = true;
    try {
      final raw = await _controller.runJavaScriptReturningResult(r'''(() => {
        const norm = v => (v || '').toLowerCase().normalize('NFKD')
          .replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]+/g,' ')
          .trim().replace(/\s+/g,' ');
        const expected = norm(TARGET_TITLE);
        const year = TARGET_YEAR;
        const found = new Map();
        document.querySelectorAll('a[href]').forEach(a => {
          let u;
          try { u=new URL(a.getAttribute('href') || '',location.href); }
          catch (_) {return;}
          if(u.protocol!=='https:' || u.host!==location.host ||
             u.pathname==='/' || u.pathname.startsWith('/search'))return;
          let slug='';
          try {slug=decodeURIComponent(u.pathname.split('/').filter(Boolean).pop()||'');}
          catch (_) {slug=u.pathname.split('/').filter(Boolean).pop()||'';}
          const slugYear=slug.match(/(?:19|20)\d{2}$/)?.[0] || '';
          const titleFromSlug=slug.replace(/-(?:19|20)\d{2}$/,'')
            .replace(/^(?:nonton|watch|download|film|movie|series)-/i,'')
            .replace(/-/g,' ');
          // Use each link's OWN title, not the text of neighboring results.
          const card=a.closest('article,li,.item,.movie,.film,.poster,.ml-item,.grid-item');
          const ownTitle=a.getAttribute('title') ||
            a.querySelector('img')?.getAttribute('alt') ||
            a.textContent?.trim() || '';
          const heading=card?.querySelector('.poster-title,.video-title,.title,h2,h3,h4');
          const title=norm(titleFromSlug) || norm(ownTitle);
          if(!title) return;
          const yearText=slugYear || card?.querySelector('.year,.date')?.textContent?.match(/(?:19|20)\d{2}/)?.[0] ||
            card?.querySelector('img')?.getAttribute('alt')?.match(/(?:19|20)\d{2}/)?.[0] ||
            card?.textContent?.match(/(?:19|20)\d{2}/)?.[0] || '';
          if(yearText && Math.abs(Number(yearText)-Number(year))>1)return;
          // Never classify a different title as exact using text from a broad card.
          const display=norm(ownTitle);
          const cardTitle=norm(heading?.textContent || '');
          // LK21 can use a shortened permalink while displaying the full
          // English title on the same result tile.
          const matchesTitle=title===expected || display===expected || cardTitle===expected;
          const exact=matchesTitle && (!yearText || Math.abs(Number(yearText)-Number(year))<=1);
          const score=exact?100:0;
          // Ignore generic menu and footer links before limiting candidates.
          if(score===0)return;
          const candidate={url:u.href,title:titleFromSlug || ownTitle,year:yearText,
            exact:exact, score};
          if(!found.has(u.href) || found.get(u.href).score<candidate.score)
            found.set(u.href,candidate);
        });
        return JSON.stringify([...found.values()].sort((a,b)=>b.score-a.score).slice(0,30));
      })()'''.replaceAll('TARGET_TITLE', jsonEncode(_matchTitle))
             .replaceAll('TARGET_YEAR', jsonEncode(widget.year)));
      dynamic decoded=raw;
      if(decoded is String){try{decoded=jsonDecode(decoded);}catch(_){}}
      if(decoded is String){try{decoded=jsonDecode(decoded);}catch(_){}}
      if(decoded is List){
        final candidates=decoded.whereType<Map>().toList();
        if(candidates.isEmpty)_aiStatus='Tidak ada kandidat LK21 untuk Gemini';
        // A unique exact title+year can be opened without an AI call.
        final exact=candidates.where((e)=>e['exact']==true).toList();
        if(exact.length==1){
          final link=Uri.tryParse(exact.single['url']?.toString()??'');
          if(link!=null && link.scheme=='https' && link.host==widget.url.host &&
             !_isSearchUrl(link.toString())){
            _noMatch=false;
            _candidateUrl=link.toString();
            if(mounted)setState((){_revealed=false;_loading=true;});
            await _controller.loadRequest(link);
            return true;
          }
        }
        // Only observed search-page links are sent to Gemini.
        final possible=candidates.where((e){
          final year=e['year']?.toString()??'';
          return year.isEmpty || (RegExp(r'^(?:19|20)\d{2}$').hasMatch(year) &&
              (int.parse(year)-int.parse(widget.year)).abs() <= 1);
        }).toList();
        possible.sort((a,b)=>((b['score'] as num?)??0).compareTo((a['score'] as num?)??0));
        if(possible.isNotEmpty && await _geminiMatchCandidates(possible.take(12).toList()))return true;
      }
    }catch(_){/* Source layout can change; do not guess a URL. */}
    finally{_matching=false;}
    return _searchNextAlias();
  }
  String _episodeCacheKey(int season, int episode) =>
      'fs_episode_v512_${widget.tmdbId}_${season}_$episode';

  // Persist ONLY real episode links observed in the website DOM. Do not
  // synthesize a slug or confuse a series landing page with an episode.
  Future<void> _collectEpisodeLinks() async {
    if (!_isTv || widget.tmdbId <= 0) return;
    try {
      final raw = await _controller.runJavaScriptReturningResult(r'''(() => {
        const selections = [...document.querySelectorAll('select')];
        const selected = selections.flatMap(s => [...s.selectedOptions].map(o =>
          (o.textContent || '') + ' ' + (o.value || ''))).join(' ');
        const fromSelection = selected.match(/(?:season|musim)[\s-]*(\d+)/i);
        const fromUrl = location.pathname.match(/(?:season|musim)[-_ ]*(\d+)/i);
        const season = Number(fromSelection?.[1] || fromUrl?.[1] || 0);
        const found = [];
        for (const a of document.querySelectorAll('a[href]')) {
          let u; try { u = new URL(a.getAttribute('href'), location.href); } catch (_) { continue; }
          if (u.protocol !== 'https:' || !u.pathname || u.pathname === '/') continue;
          const explicit = u.pathname.match(/(?:season|musim)[-_ ]*(\d+).*?(?:episode|eps?|ep)[-_ ]*0*(\d+)(?!\d)/i);
          let sn = explicit ? Number(explicit[1]) : season;
          let ep = explicit ? Number(explicit[2]) : 0;
          const panel = a.closest('.episode,.episodes,.episode-list,.episode-grid,.ep-list,.server-episode,.series-episode');
          if (!ep && panel && season) {
            const m = (a.textContent || '').trim().match(/^(?:episode|eps?|ep)?\s*0*(\d+)$/i);
            if (m) ep = Number(m[1]);
          }
          if (sn > 0 && ep > 0 && ep < 1000 && (explicit || panel))
            found.push({season:sn, episode:ep, url:u.href});
        }
        return JSON.stringify(found);
      })()''');
      dynamic decoded = raw;
      if (decoded is String) { try { decoded = jsonDecode(decoded); } catch (_) {} }
      if (decoded is String) { try { decoded = jsonDecode(decoded); } catch (_) {} }
      if (decoded is! List) return;
      final buckets = <String, Set<String>>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final sn = int.tryParse('${item['season']}') ?? 0;
        final ep = int.tryParse('${item['episode']}') ?? 0;
        final uri = Uri.tryParse('${item['url']}');
        if (sn < 1 || ep < 1 || uri == null || uri.scheme != 'https') continue;
        buckets.putIfAbsent(_episodeCacheKey(sn, ep), () => <String>{}).add(uri.toString());
      }
      final prefs = await SharedPreferences.getInstance();
      for (final entry in buckets.entries) {
        if (entry.value.length == 1) await prefs.setString(entry.key, entry.value.single);
      }
    } catch (_) { /* Incompatible DOM; retain manual fallback. */ }
  }

  Future<bool> _openCachedEpisode() async {
    if (!_isTv || widget.tmdbId <= 0 || widget.season < 1 || widget.episode < 1) return false;
    final prefs = await SharedPreferences.getInstance();
    final uri = Uri.tryParse(prefs.getString(_episodeCacheKey(widget.season, widget.episode)) ?? '');
    if (uri == null || uri.scheme != 'https' || _isSearchUrl(uri.toString())) return false;
    if (mounted) setState(() { _revealed = false; _loading = true; });
    await _controller.loadRequest(uri);
    return true;
  }

  // The series landing page contains the real season selector and episode links.
  // Resolve them from the loaded page instead of constructing speculative URLs.
  Future<bool> _resolveEpisode() async {
    if (!_isTv || widget.season < 1 || widget.episode < 1 || _resolvingEpisode || _episodeAttempts >= 3) return false;
    _resolvingEpisode = true;
    _episodeAttempts++;
    try {
      await _collectEpisodeLinks();
      final js = r'''(() => {
        const season = TARGET_SEASON, episode = TARGET_EPISODE;
        const selected = new RegExp('(?:season|musim)[\\s-]*' + season + '(?![0-9])','i');
        const episodePattern = new RegExp('(?:episode|eps?|ep)[\\s-]*0*' + episode + '(?![0-9])','i');
        const current = location.href;
        if (selected.test(current) && episodePattern.test(current)) return JSON.stringify({state:'ready'});
        // A season selector may swap the episode list without changing the URL.
        const selectors = [...document.querySelectorAll('select')];
        let seasonSelect = selectors.find(s => [...s.options].some(o => selected.test((o.textContent || '')+' '+o.value)));
        if (seasonSelect) {
          const option = [...seasonSelect.options].find(o => selected.test((o.textContent || '')+' '+o.value));
          if (option && seasonSelect.value !== option.value) {
            seasonSelect.value = option.value;
            seasonSelect.dispatchEvent(new Event('change',{bubbles:true}));
            return JSON.stringify({state:'changed'});
          }
        }
        const links = [...document.querySelectorAll('a[href]')].filter(a => {
          const text = (a.textContent || '').trim();
          const href = a.getAttribute('href') || '';
          if (!href || /^(#|javascript:)/i.test(href)) return false;
          let u; try { u = new URL(href,location.href); } catch (_) { return false; }
          if (u.protocol !== 'https:') return false;
          const combined = (text + ' ' + u.pathname).toLowerCase();
          const explicit = selected.test(combined) && episodePattern.test(combined);
          const inEpisodePanel = !!a.closest('.episode, .episodes, .episode-list, .episode-grid, .ep-list, .server-episode, .series-episode');
          const numeric = new RegExp('^0*' + episode + '$').test(text);
          const onCorrectSeason = seasonSelect && selected.test((seasonSelect.selectedOptions[0]?.textContent || '')+' '+seasonSelect.value);
          return explicit || (inEpisodePanel && numeric && onCorrectSeason);
        });
        const unique = [...new Set(links.map(a => new URL(a.getAttribute('href'),location.href).href))];
        if (unique.length === 1) return JSON.stringify({state:'found',url:unique[0]});
        return JSON.stringify({state:'missing'});
      })()'''.replaceAll('TARGET_SEASON', widget.season.toString()).replaceAll('TARGET_EPISODE', widget.episode.toString());
      dynamic result = await _controller.runJavaScriptReturningResult(js);
      if (result is String) { try { result = jsonDecode(result); } catch (_) {} }
      if (result is String) { try { result = jsonDecode(result); } catch (_) {} }
      if (result is Map && result['state'] == 'found') {
        final url = Uri.tryParse(result['url']?.toString() ?? '');
        if (url != null && url.scheme == 'https') {
          if (mounted) setState(() { _loading = true; _revealed = false; });
          final prefs = await SharedPreferences.getInstance();
          if (widget.tmdbId > 0) await prefs.setString(_episodeCacheKey(widget.season, widget.episode), url.toString());
          await _controller.loadRequest(url);
          return true;
        }
      }
      if (result is Map && result['state'] == 'changed') {
        // Allow the site's own season-change handler to populate its episode list.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await _collectEpisodeLinks();
        if (await _openCachedEpisode()) return true;
        return await _resolveEpisodeAfterChange();
      }
    } catch (_) { /* No reliable episode link: show the page for manual selection. */ }
    finally { _resolvingEpisode = false; }
    return false;
  }
  Future<bool> _resolveEpisodeAfterChange() async {
    _resolvingEpisode = false;
    return _resolveEpisode();
  }

  Future<void> _rememberDetail() async {
    if (!_canMatch || _isTv || (_isSearchUrl(widget.url.toString()) && _candidateUrl == null)) return;
    final current = await _controller.currentUrl();
    final uri = Uri.tryParse(current ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host != widget.url.host || _isSearchUrl(current)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, uri.toString());
  }

  // Guard top-level navigations; iframe/subresource requests are not blocked.
  bool _allowedMainNavigation(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    if (u.scheme == 'about') return true;
    if (u.scheme != 'https') return false;
    final origin = widget.url.host.toLowerCase();
    // Keep navigation within the original website. Embed frames load separately.
    final host = u.host.toLowerCase();
    if (host == origin) return true;
    if (!_isTv) return false;
    // Only known source site families may redirect the TOP-LEVEL series page.
    // Do not allow an arbitrary HTTPS advertising/gambling page to replace it.
    const sources = ['nontondrama.my', 'nontondrama.vip', 'layanfilem.my', 'lk21.de', 'lk21official.cc'];
    return sources.any((base) => host == base || host.endsWith('.$base'));
  }

  Future<void> _applyCleanPlayer() async {
    try {
      await _controller.runJavaScript(r'''(() => {
        if (window.__filmstreamCleanV1) return;
        window.__filmstreamCleanV1 = true;
        // Keep popups from replacing the Flutter player; do not touch video requests.
        try { window.open = function() { return null; }; } catch (_) {}
        const clean = () => {
          document.querySelectorAll('a[target="_blank"]').forEach(a => a.removeAttribute('target'));
          document.querySelectorAll('#adContainer, #nativeAds, #adsLink').forEach(el => {
            el.style.setProperty('display','none','important');
          });
        };
        clean();
        new MutationObserver(clean).observe(document.documentElement, {childList:true,subtree:true});
      })();''');
    } catch (_) { /* Site may reject script injection; keep original player available. */ }
  }

  // Controls are native Flutter widgets. The original page owns the iframe and
  // performs server switching; no embed URL is reconstructed or loaded top-level.
  Future<void> _readServers() async {
    if (!_focused) return;
    try {
      final raw = await _controller.runJavaScriptReturningResult(r'''(() => {
        const select = document.querySelector('#player-select');
        const opts = select ? [...select.options].map(o => ({name:(o.textContent||'').trim(), value:o.value, selected:o.selected})) : [];
        const anchors = [...document.querySelectorAll('#player-list a[data-server],.player-options a[data-server]')].map(a => ({name:(a.getAttribute('data-server')||a.textContent||'').trim(), value:a.getAttribute('data-url')||a.href, selected:a.classList.contains('active')}));
        const data = [...opts,...anchors].filter(x => x.name && x.value && !/^(select|pilih|choose|ganti player)/i.test(x.name));
        const unique = new Map(); data.forEach(x => { const key=x.name.toUpperCase(); if (!unique.has(key)) unique.set(key,{name:key,selected:x.selected}); });
        return JSON.stringify([...unique.values()]);
      })()''');
      dynamic data = raw;
      if (data is String) { try { data = jsonDecode(data); } catch (_) {} }
      if (data is String) { try { data = jsonDecode(data); } catch (_) {} }
      if (data is! List || !mounted) return;
      final names = <String>[];
      String selected = '';
      for (final item in data) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString().trim().toUpperCase();
        if (name.isEmpty || names.contains(name)) continue;
        names.add(name);
        if (item['selected'] == true) selected = name;
      }
      setState(() {
        _serverNames = names;
        if (selected.isNotEmpty) _selectedServer = selected;
        else if (!names.contains(_selectedServer)) _selectedServer = names.isEmpty ? '' : names.first;
      });
    } catch (_) { /* Site DOM may not expose a server chooser. */ }
  }

  Future<void> _switchServer(String name) async {
    if (_changingServer || !_serverNames.contains(name)) return;
    setState(() => _changingServer = true);
    try {
      final script = r'''(() => {
        const name = TARGET_NAME;
        const norm = x => (x || '').trim().toUpperCase();
        const select = document.querySelector('#player-select');
        const option = select && [...select.options].find(o => norm(o.textContent) === name);
        if (option) {
          select.value = option.value;
          select.dispatchEvent(new Event('input',{bubbles:true}));
          select.dispatchEvent(new Event('change',{bubbles:true}));
          return true;
        }
        const a = [...document.querySelectorAll('#player-list a[data-server],.player-options a[data-server]')].find(x => norm(x.getAttribute('data-server') || x.textContent) === name);
        if (a) { a.click(); return true; }
        return false;
      })()'''.replaceAll('TARGET_NAME', jsonEncode(name));
      final result = await _controller.runJavaScriptReturningResult(script);
      if (mounted && (result == true || result.toString() == 'true')) setState(() => _selectedServer = name);
      // Some site scripts swap the iframe asynchronously.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (mounted) { await _applyFocus(); await _readServers(); }
    } catch (_) { /* Preserve currently playing video on switch failure. */ }
    finally { if (mounted) setState(() => _changingServer = false); }
  }

  Widget _flutterServers() {
    if (!_focused || !_revealed || _search || _serverNames.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity, color: const Color(0xff17171c),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Text('Pilih Server', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white70)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: _serverNames.map((name) {
          final active = name == _selectedServer;
          return ChoiceChip(
            label: Text(name, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
            selected: active,
            showCheckmark: active,
            selectedColor: const Color(0xff70404a),
            backgroundColor: const Color(0xff292a30),
            side: BorderSide(color: active ? const Color(0xffedabae) : Colors.white24),
            onSelected: _changingServer ? null : (_) => _switchServer(name),
          );
        }).toList()),
      ]),
    );
  }

  // Read only metadata and real episode links present in the source document.
  // Never generate episode addresses or replace the site-owned player.
  Future<void> _readSourceDetails() async {
    if (widget.onSynopsisFound == null && !widget.embedded) return;
    try {
      // Expand the source site's collapsed synopsis before reading its DOM.
      // Only activate a local expand control; do not follow external links.
      await _controller.runJavaScript(r'''(() => {
        const nodes=document.querySelectorAll('button,a,[role="button"],span');
        const expand=[...nodes].find(el=>{
          const text=(el.textContent||'').trim().toLowerCase();
          if(!/^(lihat selengkapnya|baca selengkapnya|read more|show more)$/.test(text))return false;
          if(el.tagName==='A'){
            const href=(el.getAttribute('href')||'').trim();
            if(href && href!=='#' && !href.startsWith('javascript:'))return false;
          }
          return true;
        });
        if(expand)expand.click();
      })()''');
      await Future<void>.delayed(const Duration(milliseconds:300));
      final raw=await _controller.runJavaScriptReturningResult(r'''(() => {
        const txt = e => (e?.textContent || '').trim().replace(/\\s+/g,' ');
        const synopsis = document.querySelector('[itemprop="description"],.sinopsis,.synopsis,.entry-content .desc,.film-synopsis,.summary,.description');
        const genreNodes = document.querySelectorAll('.genres a,.genre a,[rel="tag"],a[href*="/genre/"]');
        const genres = [...new Set([...genreNodes].map(txt).filter(x=>x && x.length<35))].slice(0,12);
        const episodes = [];
        document.querySelectorAll('.episode-list a[href],.episodes a[href],.ep-list a[href],.series-episode a[href]').forEach(a => {
          try {
            const uri = new URL(a.getAttribute('href'),location.href);
            if(uri.protocol !== 'https:' || uri.host !== location.host)return;
            const text=txt(a);
            const season = Number((uri.pathname.match(/(?:season|musim)[-_ ]*(\\d+)/i)||[])[1]||0);
            const number = Number((text.match(/(?:episode|eps?|ep)\\s*0*(\\d+)/i)||uri.pathname.match(/(?:episode|eps?|ep)[-_ ]*0*(\\d+)/i)||[])[1]||0);
            if(number>0)episodes.push({season,episode:number,url:uri.href});
          }catch(_){}
        });
        return JSON.stringify({genres,synopsis:txt(synopsis),episodes:episodes.slice(0,150)});
      })()''');
      dynamic parsed=raw;
      if(parsed is String){try{parsed=jsonDecode(parsed);}catch(_){}}
      if(parsed is String){try{parsed=jsonDecode(parsed);}catch(_){}}
      if(parsed is! Map || !mounted)return;
      final genres=(parsed['genres'] as List? ?? const []).whereType<String>().toList();
      final synopsis=(parsed['synopsis']??'').toString();
      final episodes=(parsed['episodes'] as List? ?? const []).whereType<Map>()
        .map((e)=>Map<String,dynamic>.from(e)).toList();
      if(synopsis.isNotEmpty && widget.onSynopsisFound != null) widget.onSynopsisFound!(synopsis);
      setState((){_sourceGenres=genres;_sourceSynopsis=synopsis;_sourceEpisodes=episodes;});
    }catch(_){/* Site metadata is optional. */}
  }
  Widget _flutterSourceDetails() {
    if(!_revealed || !_focused || _sourceEpisodes.isEmpty)return const SizedBox.shrink();
    return Container(width:double.infinity,color:const Color(0xff17171c),padding:const EdgeInsets.fromLTRB(14,10,14,12),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[
        if(_isTv && _sourceEpisodes.isNotEmpty)...[
          const SizedBox(height:10),
          const Text('Episode tersedia di sumber',style:TextStyle(fontWeight:FontWeight.bold)),
          const SizedBox(height:6),
          SizedBox(height:42,child:ListView.separated(scrollDirection:Axis.horizontal,
            itemCount:_sourceEpisodes.length,separatorBuilder:(_,__)=>const SizedBox(width:6),
            itemBuilder:(context,i){
              final e=_sourceEpisodes[i];
              return OutlinedButton(
                onPressed:(){
                  final uri=Uri.tryParse((e['url']??'').toString());
                  if(uri!=null && uri.scheme=='https' && uri.host==widget.url.host)_controller.loadRequest(uri);
                },
                child:Text('${(e['season'] as num?)?.toInt()==0?'':'S${e['season']} · '}E${e['episode']}'));
            })),
        ],
      ]));
  }
  Future<void> _installProgressObserver() async {
    if (widget.onVideoProgress == null) return;
    try {
      await _controller.runJavaScript(r'''(() => {
        if (window.__fsProgressObserver) return;
        window.__fsProgressObserver = true;
        const bound = new WeakSet();
        const attach = (doc) => {
          try {
            doc.querySelectorAll('video').forEach(v => {
              if (bound.has(v)) return;
              bound.add(v);
              let lastSentAt = -1;
              let started = false;
              const send = (ended = false) => {
                const d = Number(v.duration), p = Number(v.currentTime);
                if (!Number.isFinite(d) || !Number.isFinite(p) || d <= 0 || d > 86400 || p < 0) return;
                // A loaded page or a play click is not proof of watching.
                // Record as soon as measured playback reaches 0.1 seconds.
                if (!ended && p < 0.1) return;
                if (!ended && started && p - lastSentAt < 1 && p < d * 0.9) return;
                started = true;
                lastSentAt = p;
                FilmStreamProgress.postMessage(JSON.stringify({positionMs: Math.round(p*1000), durationMs: Math.round(d*1000), ended}));
              };
              v.addEventListener('timeupdate', () => send());
              v.addEventListener('playing', () => send());
              v.addEventListener('pause', () => send());
              v.addEventListener('seeked', () => send());
              v.addEventListener('ended', () => send(true));
            });
            doc.querySelectorAll('iframe').forEach(frame => {
              // Same-origin frames are readable; cross-origin players cannot be
              // inspected or claimed to have completed without an official API.
              try { if (frame.contentDocument) attach(frame.contentDocument); } catch (_) {}
            });
          } catch (_) {}
        };
        attach(document);
        new MutationObserver(() => attach(document)).observe(document.documentElement, {childList:true, subtree:true});
        document.addEventListener('load', e => {
          if (e.target && e.target.tagName === 'IFRAME') attach(document);
        }, true);
      })();''');
    } catch (_) { /* Cross-origin iframe progress is not accessible. */ }
  }

  @override
  void initState() {
    super.initState();
    _focused = widget.focused;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xff101014))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          _navigationGeneration++;
          _episodeAttempts = 0; // Each new document gets its own resolution attempts.
          if (mounted) setState(() { _loading = true; _revealed = false; _error = null; _progress = 0; _serverNames = const []; _selectedServer = ''; _sourceGenres = const []; _sourceSynopsis = ''; _sourceEpisodes = const []; });
        },
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
        onPageFinished: (url) async {
          final generation = _navigationGeneration;
          await _applyCleanPlayer();
          await _installProgressObserver();
          if (!mounted || generation != _navigationGeneration) return;
          // The source sometimes finishes its countdown/redirect document before
          // navigating to the actual series page. Never briefly reveal that page.
          // This visual cover does not block redirects, login or user navigation.
          if (_focused && await _isRedirectInterstitial()) {
            for (var tick = 0; tick < 14; tick++) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
              if (!mounted || generation != _navigationGeneration) return;
              if (!await _isRedirectInterstitial()) break;
            }
            if (!mounted || generation != _navigationGeneration) return;
            // If the upstream redirect never happens, make the real page available
            // for user interaction instead of showing an endless spinner.
            if (await _isRedirectInterstitial()) {
              setState(() { _loading = false; _search = true; _revealed = true; });
              return;
            }
          }
          if (_focused && _isSearchUrl(url)) {
            await Future<void>.delayed(const Duration(milliseconds: 650));
            if (!mounted || generation != _navigationGeneration) return;
            if (await _autoMatchSearch()) return;
          }
          if (!mounted || generation != _navigationGeneration) return;
          if (_focused && _isTv && !_isSearchUrl(url)) {
            await _collectEpisodeLinks();
            if (!mounted || generation != _navigationGeneration) return;
            // Series landing pages can briefly show an interstitial before the
            // episode list is populated by the source site's own scripts.
            // Keep the Flutter loading cover visible throughout resolution.
            for (var attempt = 0; attempt < 3; attempt++) {
              if (!mounted || generation != _navigationGeneration) return;
              if (await _resolveEpisode()) return;
              if (!mounted || generation != _navigationGeneration) return;
              if (attempt < 2) {
                await Future<void>.delayed(Duration(milliseconds: 450 * (attempt + 1)));
              }
            }
          }
          if (!mounted || generation != _navigationGeneration) return;
          if (!_focused && widget.onSynopsisFound != null) await _readSourceDetails();
          if (!mounted || generation != _navigationGeneration) return;
          bool found = false;
          if (_focused) found = await _applyFocus();
          if (!mounted || generation != _navigationGeneration) return;
          if (found) {
            await _readServers();
            await _readSourceDetails();
            await _rememberDetail();
            if (!_readyNotified && widget.onPlayerReady != null) {
              _readyNotified = true;
              final current = Uri.tryParse(await _controller.currentUrl() ?? '');
              if (current != null && current.scheme == 'https') widget.onPlayerReady!(current);
            }
          }
          if (mounted && generation == _navigationGeneration) setState(() {
            _loading = false;
            _search = !found;
            _revealed = true;
          });
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true && mounted) {
            setState(() { _error = e.description; _loading = false; _revealed = true; });
          }
        },
        onNavigationRequest: (r) {
          final next = Uri.tryParse(r.url);
          if (next == null || (next.scheme != 'https' && next.scheme != 'about')) return NavigationDecision.prevent;
          if (r.isMainFrame && !_allowedMainNavigation(r.url)) {
            // Reject off-site top-level redirects, including gambling landing pages.
            // Embedded video frames are not affected by this top-level rule.
            return NavigationDecision.prevent;
          }
          if (r.isMainFrame && _isSearchUrl(widget.url.toString()) && _search && next.host == widget.url.host && !_isSearchUrl(next.toString()) && next.path != '/') { _candidateUrl = next.toString(); }
          // Cover the old website before any new top-level document is shown.
          if (r.isMainFrame && mounted && _focused) {
            setState(() { _revealed = false; _loading = true; });
          }
          return NavigationDecision.navigate;
        },
      ))
      ;
    _controller.addJavaScriptChannel('FilmStreamProgress', onMessageReceived: (msg) {
      if (!mounted || widget.onVideoProgress == null) return;
      try {
        final v = jsonDecode(msg.message) as Map<String, dynamic>;
        final p = (v['positionMs'] as num).toInt();
        final d = (v['durationMs'] as num).toInt();
        if (d > 0 && d <= 86400000 && p >= 0 && p <= d + 3000) {
          widget.onVideoProgress!(p.clamp(0, d).toInt(), d, v['ended'] == true);
        }
      } catch (_) {}
    });
    // Android WebChromeClient fullscreen is separate from the document CSS.
    // Keep its native custom video view inside a landscape Flutter route.
    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController).setCustomWidgetCallbacks(
        onShowCustomWidget: (videoWidget, onCustomWidgetHidden) {
          if (!mounted || _fullScreenRouteOpen) return;
          _fullScreenRouteOpen = true;
          _fullScreenHiding = false;
          Navigator.of(context).push(MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => _FilmStreamLandscapeVideo(video: videoWidget),
          )).then((_) async {
            _fullScreenRouteOpen = false;
            if (!_fullScreenHiding) onCustomWidgetHidden();
            _fullScreenHiding = false;
            if (!mounted) return;
            // Some sites replace the DOM after the custom fullscreen view closes.
            if (_focused) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
              await _applyFocus();
              await _readServers();
              try { await _controller.runJavaScript("window.scrollTo(0,0);document.documentElement.scrollTop=0;document.body.scrollTop=0;"); } catch (_) {}
              widget.onFullscreenExit?.call();
            }
          });
        },
        onHideCustomWidget: () {
          if (!_fullScreenRouteOpen || !mounted) return;
          _fullScreenHiding = true;
          final nav = Navigator.of(context);
          if (nav.canPop()) nav.pop();
        },
      );
    }
    _initialLoad();
  }

  /// Restrict *visual* focus to a known film-page DOM, never on search pages.
  /// Return true only after the main iframe exists. Avoid rewriting display or
  /// height on the iframe itself: doing so broke some site player layouts in V5.2.
  Future<bool> _applyFocus() async {
    try {
      final result = await _controller.runJavaScriptReturningResult(r'''
        (() => {
          const shell = document.querySelector('.player-section-wrapper, .player-area, .main-player') || (document.querySelector('iframe#main-player')?.parentElement);
          const iframe = shell?.querySelector('iframe#main-player, iframe[src]');
          if (!shell || !iframe) return false;
          let style = document.getElementById('fs-focus-v53');
          if (!style) {
            style = document.createElement('style');
            style.id = 'fs-focus-v53';
            document.head.appendChild(style);
          }
          style.textContent = `
            html.fs-focus-v53, html.fs-focus-v53 body { margin:0!important; background:#101014!important;
              overflow-x:hidden!important; overscroll-behavior:none!important; }
            html.fs-focus-v53 body { position:relative!important; top:0!important; left:0!important; }
            html.fs-focus-v53 .player-section-wrapper { top:0!important; transform:none!important; }
            html.fs-focus-v53 body > nav, html.fs-focus-v53 body > header,
            html.fs-focus-v53 body > footer, html.fs-focus-v53 .sub-header,
            html.fs-focus-v53 .main-header, html.fs-focus-v53 .main-section,
            html.fs-focus-v53 .player-right, html.fs-focus-v53 .mobile-nav,
            html.fs-focus-v53 .site-footer, html.fs-focus-v53 .bottom-nav,
            html.fs-focus-v53 .mobile-bottom-nav,
            html.fs-focus-v53 .player-section-wrapper ~ * { display:none!important; }
            html.fs-focus-v53 .player-section-wrapper,
            html.fs-focus-v53 .player-section-wrapper .container,
            html.fs-focus-v53 .player-area,
            html.fs-focus-v53 .player-wrapper,
            html.fs-focus-v53 .player-left { width:100%!important; max-width:100%!important;
              margin:0!important; padding:0!important; box-sizing:border-box!important; }
            html.fs-focus-v53 .player-section-wrapper .player-action { display:none!important; }
            /* Only Flutter renders the server controls; preserve original DOM for JS. */
            html.fs-focus-v53 .player-options {position:absolute!important;left:-20000px!important;top:0!important;
              width:1px!important;height:1px!important;overflow:hidden!important;opacity:0!important;pointer-events:none!important;}
            html.fs-focus-v53 .main-player { width:100vw!important; max-width:100vw!important;
              aspect-ratio:16 / 9!important; height:calc(100vw * 9 / 16)!important; min-height:0!important;
              margin:0!important; padding:0!important; overflow:hidden!important; position:fixed!important;
              top:0!important;left:0!important;z-index:10!important;background:#000!important; }
            html.fs-focus-v53 .main-player > iframe,
            html.fs-focus-v53 .main-player > #main-player { display:block!important;
              position:absolute!important; inset:0!important; width:100%!important; height:100%!important;
              min-height:0!important; max-height:100%!important; border:0!important; margin:0!important; }
            html.fs-focus-v53 .player-options { max-width:100%!important; width:100%!important;
              margin-left:0!important; margin-right:0!important; }
          `;
          document.documentElement.classList.add('fs-focus-v53');
          const player = document.querySelector('.main-player');
          if (player) {
            window.scrollTo(0, 0);
            document.documentElement.scrollTop = 0;
            document.body.scrollTop = 0;
            // Ensure the embedded WebView cannot drift between player and server control.
            if (!window.__fsFocusScrollGuard) {
              window.__fsFocusScrollGuard = true;
              window.addEventListener('scroll', () => {
                if (document.documentElement.classList.contains('fs-focus-v53') && window.scrollY !== 0)
                  window.scrollTo(0, 0);
              }, {passive:true});
            }
          }
          return true;
        })();
      ''');
      return result == true || result.toString() == 'true';
    } catch (_) { return false; }
  }

  Future<bool> _isRedirectInterstitial() async {
    try {
      final value = await _controller.runJavaScriptReturningResult(r'''(() => {
        const t = (document.body?.innerText || '').toLowerCase();
        return (t.includes('anda akan dialihkan') || t.includes('you will be redirected'))
          && (t.includes('nontondrama') || t.includes('detik') || t.includes('seconds'));
      })()''');
      return value == true || value.toString() == 'true';
    } catch (_) { return false; }
  }

  Future<void> _setFocused(bool value) async {
    if (!value) {
      try { await _controller.runJavaScript("document.documentElement.classList.remove('fs-focus-v53');"); } catch (_) {}
      if (mounted) setState(() { _focused = false; _revealed = true; });
    } else {
      if (mounted) setState(() { _focused = true; _revealed = false; });
      final ok = await _applyFocus();
      if (mounted) setState(() { _search = !ok; _revealed = true; });
    }
  }
  // App back always exits the Web Player. Do not traverse ad/search history.
  void _back() { if (mounted) Navigator.of(context).pop(); }
  // Site history is an explicit secondary action only.
  Future<void> _siteBack() async {
    if (await _controller.canGoBack()) await _controller.goBack();
  }
  Future<void> _external() async {
    final current = Uri.tryParse(await _controller.currentUrl() ?? '') ?? widget.url;
    if (current.scheme == 'https') await launchUrl(current, mode: LaunchMode.externalApplication);
  }

  Future<void> _notifyPlayTap() async {
    if (_playIntentNotified || !mounted || !_revealed || _search || _error != null || widget.onPlayIntent == null) return;
    _playIntentNotified = true;
    try {
      final page = Uri.tryParse(await _controller.currentUrl() ?? '');
      if (page != null && page.scheme == 'https' && !_isSearchUrl(page.toString())) {
        widget.onPlayIntent!(page);
      } else {
        _playIntentNotified = false;
      }
    } catch (_) { _playIntentNotified = false; }
  }

  Widget _playerBody() => Stack(children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) { _notifyPlayTap(); },
          child: WebViewWidget(controller: _controller),
        ),
        if (!_revealed && _error == null)
          Positioned.fill(child: ColoredBox(color: const Color(0xff101014),
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(), const SizedBox(height:16),
              const Text('Menyiapkan halaman pemutar…'),
              const SizedBox(height:16),
              TextButton(onPressed: () => _setFocused(false), child: const Text('Tampilkan halaman lengkap')),
            ])))),
        if (_error != null)
          Positioned.fill(child: ColoredBox(color: const Color(0xff101014),
            child: Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(
              mainAxisSize: MainAxisSize.min, children: [
                Text('Halaman gagal dimuat: $_error', textAlign: TextAlign.center),
                FilledButton(onPressed: () => _controller.reload(), child: const Text('Coba lagi')),
                TextButton(onPressed: _external, child: const Text('Buka di browser')),
              ]))))),
        if (_revealed && _search && _focused && _error == null)
          Positioned.fill(child: ColoredBox(color: const Color(0xff101014),
            child: Center(child: Padding(padding: const EdgeInsets.all(18),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(_noMatch ? Icons.movie_filter_outlined : Icons.info_outline, size: 38, color: Colors.white70),
                const SizedBox(height: 12),
                Text(_noMatch ? 'Belum menemukan hasil yang cocok' : 'Sumber pemutar belum dapat dipastikan',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(_noMatch
                  ? 'Tidak ditemukan hasil yang meyakinkan dengan judul lengkap dan tahun rilis. Ketersediaan di sumber belum dapat dipastikan.'
                  : 'Halaman sumber belum menyediakan player yang dapat dikenali.',
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                if (_noMatch) Padding(padding: const EdgeInsets.only(top: 10),
                  child: Text(_aiStatus, textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.amber, fontSize: 12))),
                const SizedBox(height: 16),
                TextButton(onPressed: _back, child: const Text('Kembali ke katalog')),
                TextButton(onPressed: () { setState(() { _noMatch = false; _revealed = false; _loading = true; }); _initialLoad(); },
                  child: const Text('Coba lagi')),
              ]))))),
      ]);

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return ClipRect(child: Column(mainAxisSize: MainAxisSize.min, children: [AspectRatio(aspectRatio: 16 / 9, child: _playerBody()), _flutterServers(), _flutterSourceDetails()]));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _back(); },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          leading: IconButton(tooltip: 'Kembali ke katalog', icon: const Icon(Icons.arrow_back), onPressed: _back),
          actions: [
            IconButton(tooltip: 'Kembali satu halaman situs', icon: const Icon(Icons.history), onPressed: _siteBack),
            IconButton(tooltip: _focused ? 'Halaman lengkap' : 'Fokus player', icon: Icon(_focused ? Icons.crop_free : Icons.smart_display_outlined), onPressed: () => _setFocused(!_focused)),
            IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => _controller.reload()),
            IconButton(tooltip: 'Buka browser', icon: const Icon(Icons.open_in_browser), onPressed: _external),
          ],
        ),
        body: Column(children: [Expanded(child: _playerBody()), _flutterServers()]),
      ),
    );
  }

}


/// Native Android video fullscreen: keep source video widget intact and rotate
/// only this route, returning to portrait when it is dismissed.
class _FilmStreamLandscapeVideo extends StatefulWidget {
  final Widget video;
  const _FilmStreamLandscapeVideo({required this.video});
  @override
  State<_FilmStreamLandscapeVideo> createState() => _FilmStreamLandscapeVideoState();
}

class _FilmStreamLandscapeVideoState extends State<_FilmStreamLandscapeVideo> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(top:false, bottom:false, child: Stack(children: [
      Positioned.fill(child: widget.video),
      Positioned(top: 8, left: 8, child: SafeArea(child: IconButton(
        tooltip: 'Keluar fullscreen',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
        style: IconButton.styleFrom(backgroundColor: Colors.black54),
      ))),
    ])),
  );
}