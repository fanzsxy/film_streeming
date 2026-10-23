import 'package:flutter/material.dart';
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
  const WebSourcePage({super.key, required this.title, required this.url, this.focused = false,
    this.embedded = false, this.tmdbId = 0, this.mediaType = 'movie', this.year = '', this.season = 0, this.episode = 0});
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
    return _isTv || u.host.toLowerCase() == origin;
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
          if (mounted) setState(() { _loading = true; _revealed = false; _error = null; _progress = 0; });
        },
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
        onPageFinished: (url) async {
          final generation = _navigationGeneration;
          await _applyCleanPlayer();
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
          if (found) await _rememberDetail();
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
            // Only movie pages keep the original-host navigation restriction.
            // Series HTTPS redirects are handled directly by the navigation rule.
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
            html.fs-focus-v53, html.fs-focus-v53 body { margin:0!important; background:#101014!important; }
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
            html.fs-focus-v53 .player-options, html.fs-focus-v53 #player-list,
            html.fs-focus-v53 #player-select { display:block!important; visibility:visible!important; }
            html.fs-focus-v53 .main-player, html.fs-focus-v53 .player-options {
              max-width:100%!important; width:100%!important; margin-left:0!important; margin-right:0!important; }
          `;
          document.documentElement.classList.add('fs-focus-v53');
          const player = document.querySelector('.main-player');
          if (player) player.scrollIntoView({block:'start'});
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
    if (widget.embedded) return ClipRect(child: _playerBody());
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
        body: _playerBody(),
      ),
    );
  }

}
