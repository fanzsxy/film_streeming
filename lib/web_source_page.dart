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
  final int tmdbId, season, episode;
  final String mediaType, year;
  const WebSourcePage({super.key, required this.title, required this.url, this.focused = false,
    this.tmdbId = 0, this.mediaType = 'movie', this.year = '', this.season = 0, this.episode = 0});
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
  String? _candidateUrl;
  Uri? _seriesDestination;
  String get _cacheKey => 'fs_detail_v54_${widget.mediaType}_${widget.tmdbId}_${widget.season}_${widget.episode}';
  bool get _canMatch => widget.tmdbId > 0 && widget.mediaType == 'movie' && widget.year.length == 4;
  bool _isSearchUrl(String? url) { final u = Uri.tryParse(url ?? ''); return u != null &&
    (u.path == '/search' || u.path == '/search/' || u.path.startsWith('/search/')); }
  Future<void> _initialLoad() async {
    Uri target = widget.url;
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
        const found = new Map();
        const selectors = '.sliders .slider a[href], .video-list a[href], article a[href], .poster a[href], .search-results a[href], .items a[href]';
        document.querySelectorAll(selectors).forEach(a => {
          const url = new URL(a.getAttribute('href') || '', location.href);
          if (url.host !== location.host || !/^https:$/.test(url.protocol) || !url.pathname || url.pathname === '/' || url.pathname.startsWith('/search')) return;
          const card = a.closest('article, li, .item, .result') || a;
          const heading = card.querySelector('.poster-title, .video-title, h2, h3, figcaption');
          const title = (heading?.textContent || a.querySelector('img')?.alt || a.getAttribute('title') || '').trim();
          const dateNode = card.querySelector('.year, [itemprop="datePublished"], .video-year');
          const year = (dateNode?.getAttribute('content') || dateNode?.textContent || '').match(/(?:19|20)\d{2}/)?.[0] || '';
          if (norm(title) === target && year === expectedYear) found.set(url.href, {url:url.href,title,year});
        });
        return JSON.stringify([...found.values()]);
      })()'''.replaceAll('TARGET_TITLE', jsonEncode(widget.title)).replaceAll('TARGET_YEAR', jsonEncode(widget.year)));
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
  Future<void> _rememberDetail() async {
    if (!_canMatch || (_isSearchUrl(widget.url.toString()) && _candidateUrl == null)) return;
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
    return u.host.toLowerCase() == origin;
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
          if (mounted) setState(() { _loading = true; _revealed = false; _error = null; _progress = 0; _seriesDestination = null; });
        },
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
        onPageFinished: (url) async {
          await _applyCleanPlayer();
          if (_focused && _isSearchUrl(url) && await _autoMatchSearch()) return;
          bool found = false;
          if (_focused) found = await _applyFocus();
          if (found) await _rememberDetail();
          if (mounted) setState(() {
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
            // Never silently follow an off-site redirect. For TV pages,
            // show the destination as an explicit user choice instead.
            if (widget.mediaType == 'tv' && next.scheme == 'https' && mounted) {
              setState(() { _seriesDestination = next; _loading = false; _revealed = true; });
            }
            return NavigationDecision.prevent;
          }
          if (r.isMainFrame && _isSearchUrl(widget.url.toString()) && _search && next.host == widget.url.host && !_isSearchUrl(next.toString()) && next.path != '/') { _candidateUrl = next.toString(); }
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
          const shell = document.querySelector('.player-section-wrapper');
          const iframe = shell?.querySelector('iframe#main-player');
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
          `;
          document.documentElement.classList.add('fs-focus-v53');
          window.scrollTo(0, 0);
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
  Future<void> _openSeriesDestination() async {
    final uri = _seriesDestination;
    if (uri != null && uri.scheme == 'https') {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
  Future<void> _external() async {
    final current = Uri.tryParse(await _controller.currentUrl() ?? '') ?? widget.url;
    if (current.scheme == 'https') await launchUrl(current, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) { if (!didPop) _back(); },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: IconButton(tooltip: 'Kembali ke katalog', icon: const Icon(Icons.arrow_back), onPressed: _back),
        actions: [
          IconButton(tooltip: 'Kembali satu halaman situs', icon: const Icon(Icons.history), onPressed: _siteBack),
          IconButton(tooltip: _focused ? 'Halaman lengkap' : 'Fokus player',
            icon: Icon(_focused ? Icons.crop_free : Icons.smart_display_outlined),
            onPressed: () => _setFocused(!_focused)),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => _controller.reload()),
          IconButton(tooltip: 'Buka browser', icon: const Icon(Icons.open_in_browser), onPressed: _external),
        ],
        bottom: _loading ? PreferredSize(preferredSize: const Size.fromHeight(3),
          child: LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100)) : null,
      ),
      body: Stack(children: [
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
        if (_seriesDestination != null && widget.mediaType == 'tv' && _error == null)
          Positioned(left: 12, right: 12, top: 20, child: Card(child: Padding(
            padding: const EdgeInsets.all(14), child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Sumber series mengalihkan ke situs episode lain. FilmStream tidak dapat memastikan episode ini tersedia atau aman diputar otomatis.', textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(_seriesDestination!.host, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              FilledButton(onPressed: _openSeriesDestination, child: const Text('Buka tujuan di browser')),
              TextButton(onPressed: _back, child: const Text('Kembali ke katalog')),
            ])))),
        if (_revealed && _search && _focused && _error == null && _seriesDestination == null)
          Positioned(left: 10, right: 10, bottom: 14, child: Card(child: Padding(
            padding: const EdgeInsets.all(10), child: Text(
              'Ini masih halaman pencarian. Pilih hasil film yang tepat; tampilan fokus aktif saat halaman player terbuka.',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall,
            )))),
      ]),
    ),
  );
}
