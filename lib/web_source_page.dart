import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

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
  final void Function(int positionMs, int durationMs, bool ended)? onVideoProgress;
  final VoidCallback? onFullscreenExit;
  const WebSourcePage({super.key, required this.title, required this.url, this.focused = false,
    this.embedded = false, this.tmdbId = 0, this.mediaType = 'movie', this.year = '', this.season = 0, this.episode = 0, this.onPlayerReady, this.onVideoProgress, this.onFullscreenExit});
  @override
  State<WebSourcePage> createState() => _WebSourcePageState();
}

class _WebSourcePageState extends State<WebSourcePage> {
  late final WebViewController _controller;
  late bool _focused;
  bool _loading = true;
  bool _revealed = false;
  bool _search = false;
  String? _error;
  int _progress = 0;
  bool _matching = false;
  bool _resolvingEpisode = false;
  int _episodeAttempts = 0;
  int _navigationGeneration = 0;
  String? _candidateUrl;
  bool _fullScreenRouteOpen = false;
  bool _fullScreenHiding = false;
  bool _readyNotified = false;
  List<String> _serverNames = const [];
  String _selectedServer = '';
  bool _changingServer = false;

  // Follow normal HTTPS series redirects without a confirmation dialog.
  // Pop-up windows remain disabled by the Clean Player script.
  String get _matchTitle => widget.title.split(' • S').first.trim();
  bool get _isTv => widget.mediaType == 'tv' || widget.mediaType == 'series';
  String get _cacheKey => 'fs_detail_v54_${widget.mediaType}_${widget.tmdbId}_${widget.season}_${widget.episode}';
  bool get _canMatch => widget.tmdbId > 0 && widget.year.length == 4;
  bool _isSearchUrl(String? url) { final u = Uri.tryParse(url ?? ''); return u != null &&
    (u.path == '/search' || u.path == '/search/' || u.path.startsWith('/search/')); }
  Future<void> _initialLoad() async {
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
    await _controller.loadRequest(target);
  }
  Future<bool> _autoMatchSearch() async {
    if (!_canMatch || _matching) return false;
    _matching = true;
    try {
      final raw = await _controller.runJavaScriptReturningResult(r'''(() => {
        const norm = s => (s || '').toLowerCase().normalize('NFKD')
          .replace(/[\u0300-\u036f]/g, '').replace(/&amp;/g, '&')
          .replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
        const target = norm(TARGET_TITLE);
        const expectedYear = TARGET_YEAR;
        const isSeries = TARGET_SERIES;
        const matches = new Map();
        // A series search result often links its poster and title separately.
        // Inspect a small shared card and avoid using unrelated surrounding results.
        document.querySelectorAll('a[href]').forEach(a => {
          let u; try { u = new URL(a.getAttribute('href') || '', location.href); } catch (_) { return; }
          if (u.protocol !== 'https:' || u.host !== location.host ||
              u.pathname === '/' || u.pathname.startsWith('/search')) return;
          let card = a;
          for (let i = 0; i < 4 && card.parentElement; i++) {
            if (card.querySelector('img') &&
                (card.querySelector('h2,h3,h4,.title,.poster-title,.video-title') ||
                 (card.innerText || '').trim().length > 8)) break;
            card = card.parentElement;
          }
          const poster = card.querySelector('img') || a.querySelector('img');
          if (!poster) return;
          const heading = card.querySelector('.poster-title,.video-title,.title,h2,h3,h4,figcaption');
          const possible = [heading?.textContent, a.getAttribute('title'),
            poster.getAttribute('alt'), a.textContent,
            card.querySelector('a[title]')?.getAttribute('title')].filter(Boolean);
          const titleOK = possible.some(v => {
            const cleaned = v.replace(/\s*\((?:19|20)\d{2}\)\s*[-–]?\s*(?:series|movie|film)?\s*$/i,'').trim();
            return norm(cleaned) === target || norm(cleaned) === norm(TARGET_TITLE + ' (' + expectedYear + ') - Series');
          });
          if (!titleOK) return;
          const text = [card.innerText, poster.getAttribute('alt'), a.getAttribute('title'),
            card.querySelector('.year,.date,[itemprop="datePublished"]')?.textContent].filter(Boolean).join(' ');
          const years = text.match(/(?:19|20)\d{2}/g) || [];
          if (expectedYear && !years.includes(expectedYear)) return;
          const tag = (card.innerText || '').toLowerCase();
          if (isSeries && /\b(movie|film)\b/.test(tag) && !/\b(series|eps|episode|s\.?[1-9])\b/.test(tag)) return;
          // Only same-site title detail links are candidates; do not guess a URL.
          matches.set(u.href, {url:u.href});
        });
        return JSON.stringify([...matches.values()]);
      })()'''.replaceAll('TARGET_TITLE', jsonEncode(_matchTitle))
             .replaceAll('TARGET_YEAR', jsonEncode(widget.year))
             .replaceAll('TARGET_SERIES', _isTv ? 'true' : 'false'));
      // Android WebView can return either a JSON string or a JS-quoted JSON string.
      dynamic decoded = raw;
      if (decoded is String) { try { decoded = jsonDecode(decoded); } catch (_) {} }
      if (decoded is String) { try { decoded = jsonDecode(decoded); } catch (_) {} }
      if (decoded is List && decoded.length == 1 && decoded.first is Map) {
        final link = Uri.tryParse((decoded.first as Map)['url']?.toString() ?? '');
        if (link != null && link.scheme == 'https' && link.host == widget.url.host && !_isSearchUrl(link.toString())) {
          _candidateUrl = link.toString();
          if (mounted) setState(() { _revealed = false; _loading = true; });
          await _controller.loadRequest(link);
          return true;
        }
      }
    } catch (_) { /* A changed site DOM must fall back to manual search. */ }
    finally { _matching = false; }
    return false;
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
    const sources = ['nontondrama.my', 'layanfilem.my', 'lk21.de', 'lk21official.cc'];
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

  Future<void> _installProgressObserver() async {
    if (widget.onVideoProgress == null) return;
    try {
      await _controller.runJavaScript(r'''(() => {
        if (window.__fsProgressObserver) return;
        window.__fsProgressObserver = true;
        const bound = new WeakSet();
        const attach = () => {
          document.querySelectorAll('video').forEach(v => {
            if (bound.has(v)) return;
            bound.add(v);
            let last = -1;
            const send = (ended = false) => {
              const d = Number(v.duration), p = Number(v.currentTime);
              if (!Number.isFinite(d) || !Number.isFinite(p) || d <= 0 || d > 86400 || p < 0) return;
              const sec = Math.floor(p);
              if (!ended && sec - last < 5) return;
              last = sec;
              FilmStreamProgress.postMessage(JSON.stringify({positionMs: Math.round(p*1000), durationMs: Math.round(d*1000), ended}));
            };
            v.addEventListener('timeupdate', () => send());
            v.addEventListener('pause', () => send());
            v.addEventListener('ended', () => send(true));
          });
        };
        attach();
        new MutationObserver(attach).observe(document.documentElement, {childList:true, subtree:true});
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
          if (mounted) setState(() { _loading = true; _revealed = false; _error = null; _progress = 0; _serverNames = const []; _selectedServer = ''; });
        },
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
        onPageFinished: (url) async {
          final generation = _navigationGeneration;
          await _applyCleanPlayer();
          await _installProgressObserver();
          if (!mounted || generation != _navigationGeneration) return;
          if (_focused && _isSearchUrl(url) && await _autoMatchSearch()) return;
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
          // A source redirect splash may finish loading before its countdown
          // navigates away. Keep the Flutter cover in place for that transition.
          // This is visual only: no cookies, authentication or redirects are altered.
          if (_focused) {
            bool redirectSplash = false;
            try {
              final splash = await _controller.runJavaScriptReturningResult(r'''(() => {
                const text = (document.body?.innerText || '').toLowerCase();
                return (text.includes('anda akan dialihkan') || text.includes('you will be redirected'))
                  && (text.includes('nontondrama') || text.includes('detik') || text.includes('seconds'));
              })()''');
              redirectSplash = splash == true || splash.toString() == 'true';
            } catch (_) {}
            if (redirectSplash) {
              await Future<void>.delayed(const Duration(milliseconds: 4300));
              if (!mounted || generation != _navigationGeneration) return;
            }
          }
          bool found = false;
          if (_focused) found = await _applyFocus();
          if (!mounted || generation != _navigationGeneration) return;
          if (found) {
            await _readServers();
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
            html.fs-focus-v53 .main-player, html.fs-focus-v53 .player-options {
              max-width:100%!important; width:100%!important; margin-left:0!important; margin-right:0!important; }
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

  Widget _playerBody() => Stack(children: [
        WebViewWidget(controller: _controller),
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
          Positioned(left: 10, right: 10, bottom: 14, child: Card(child: Padding(
            padding: const EdgeInsets.all(10), child: Text(
              _isTv ? 'Halaman belum menampilkan player.' : 'Ini masih halaman pencarian. Pilih hasil film yang tepat; tampilan fokus aktif saat halaman player terbuka.',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall,
            )))),
      ]);

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return ClipRect(child: Column(children: [
      // Reserve all remaining height for the actual WebView. Flutter server chips
      // take their own space below it instead of overlaying video controls.
      Expanded(child: SizedBox(width: double.infinity, child: _playerBody())),
      _flutterServers(),
    ]));
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
