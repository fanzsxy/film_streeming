import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'filmstream_icons.dart';

/// Windows WebView2 version of the Android focused source player.
/// Keep the provider-owned iframe and its JS in the original document.
class WindowsSourcePlayer extends StatefulWidget {
  final String title;
  final Uri url;
  final bool embedded;
  final List<String> genres;
  final String year;
  final String catalogSynopsis;
  final int tmdbId;
  final String mediaType;
  final ValueChanged<String>? onSynopsisFound;
  final ValueChanged<List<String>>? onGenresFound;
  const WindowsSourcePlayer({
    super.key, required this.title, required this.url, this.embedded = false,
    this.genres = const [], this.year = '', this.catalogSynopsis = '', this.tmdbId = 0,
    this.mediaType = 'movie',
    this.onSynopsisFound, this.onGenresFound,
  });

  @override
  State<WindowsSourcePlayer> createState() => _WindowsSourcePlayerState();
}

class _WindowsSourcePlayerState extends State<WindowsSourcePlayer> {
  final WebviewController _controller = WebviewController();
  Timer? _poller;
  StreamSubscription<bool>? _nativeFullscreenSubscription;
  final OverlayPortalController _fullscreenPortal = OverlayPortalController();
  bool _nativeFullscreen = false;
  bool _ready = false;
  bool _showFullPage = false;
  bool _focusAvailable = false;
  String _playerDiagnostic = 'Memeriksa struktur player...';
  bool _switching = false;
  String? _error;
  List<String> _servers = const [];
  String _selectedServer = '';
  List<String> _tmdbGenres = const [];
  List<String> _lk21Genres = const [];
  String _lk21Synopsis = '';
  static const _tmdbToken = String.fromEnvironment('TMDB_TOKEN');
  List<String> get _displayGenres => _tmdbGenres.isNotEmpty
      ? _tmdbGenres : _lk21Genres;

  // Match Android WebSourcePage's tested player selectors.
  // Do not promote the iframe to a new URL or modify playback requests.
  // Keep the source document and its own playback scripts intact.
  // A pre-play poster does not always contain an iframe. The previous version
  // required an iframe, so it silently fell back to the whole LK21 page.
  static const _playerScript = r'''
    (() => {
      if (window.__filmstreamWindowsFocus) return true;
      let focused = true;
      let scheduled = false;
      let currentRoot = null;
      const marker = 'data-fs-player-root';
      const hidden = 'data-fs-hidden';

      function visible(el) {
        if (!el || !el.isConnected) return false;
        const rect = el.getBoundingClientRect();
        return rect.width >= 250 && rect.height >= 150;
      }
      function locate() {
        // Prefer the provider's *left* media column, not its whole wrapper.
        // It remains present while the playable iframe is still a poster.
        const selectors = [
          '.main-player:has(iframe),.main-player:has(video)',
          '.player-left','.player-area','.main-player',
          '#main-player','#player','.player-wrapper','.video-container',
          '.player-section-wrapper'
        ];
        for (const selector of selectors) {
          for (const el of document.querySelectorAll(selector)) {
            if (!visible(el) || el.closest('header,nav,footer,aside')) continue;
            if (el.classList.contains('player-section-wrapper')) {
              const left = el.querySelector('.player-left,.main-player,.player-area');
              if (visible(left)) return left;
            }
            return el;
          }
        }
        return null;
      }
      function style() {
        if (!document.documentElement || document.getElementById('fs-windows-focus-style')) return;
        const el = document.createElement('style');
        el.id = 'fs-windows-focus-style';
        el.textContent = [
          'html.fs-focus,html.fs-focus body {margin:0!important;',
          'padding:0!important;background:#101014!important;',
          'overflow:hidden!important;}',
          'html.fs-focus ['+hidden+'] {display:none!important;}',
          'html.fs-focus ['+marker+'] {display:block!important;',
          'position:fixed!important;inset:0!important;z-index:2147483000!important;',
          'width:100vw!important;max-width:100vw!important;',
          'height:100vh!important;min-height:0!important;',
          'padding:0!important;margin:0!important;',
          'background:#000!important;overflow:auto!important;}',
          'html.fs-focus ['+marker+'] iframe,',
          'html.fs-focus ['+marker+'] video {max-width:100%!important;}',
          'html.fs-focus #adContainer,html.fs-focus #nativeAds,',
          'html.fs-focus #adsLink,html.fs-focus .ads-container,',
          'html.fs-focus .advertisement,html.fs-focus .advertising,',
          'html.fs-focus [data-ad-slot] {display:none!important;}',
          'html.fs-focus ['+marker+'] .main-player {width:100%!important;',
          'max-width:100%!important;margin:0 auto!important;}'
        ].join(' ');
        (document.head || document.documentElement).appendChild(el);
      }
      function apply() {
        style();
        if (!document.documentElement || !document.body) return;
        const root = locate();
        document.documentElement.classList.toggle('fs-focus', focused && !!root);
        if (!focused) return;
        if (!root) {
          if (currentRoot) currentRoot.removeAttribute(marker);
          currentRoot = null;
          return;
        }
        if (root !== currentRoot) {
          document.querySelectorAll('['+marker+'],['+hidden+']').forEach(el => {
            el.removeAttribute(marker);
            el.removeAttribute(hidden);
          });
          currentRoot = root;
        }
        root.setAttribute(marker,'');
        let node = root;
        while (node && node !== document.body && node.parentElement) {
          const parent = node.parentElement;
          for (const sibling of parent.children) {
            if (sibling === node ||
                ['SCRIPT','STYLE','LINK'].includes(sibling.tagName)) continue;
            sibling.setAttribute(hidden,'');
          }
          node = parent;
        }
        window.scrollTo(0,0);
      }
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; apply(); });
      }
      window.__filmstreamWindowsFocus = value => {
        focused = !!value;
        if (!focused) document.documentElement?.classList.remove('fs-focus');
        schedule();
        return {
          found: !!locate(),
          focused,
          player: locate()?.className || locate()?.id || '',
          iframe: document.querySelectorAll('iframe').length,
          poster: document.querySelectorAll('.player-left img,.main-player img').length
        };
      };
      style();
      document.addEventListener('DOMContentLoaded', schedule);
      const startObserver = () => {
        if (!document.documentElement) return;
        // Observe inserted nodes only: attribute observation would loop.
        new MutationObserver(schedule).observe(document.documentElement,
          {childList:true,subtree:true});
        schedule();
      };
      if (document.documentElement) startObserver();
      else document.addEventListener('DOMContentLoaded', startObserver, {once:true});
      return true;
    })();
  ''';

  static const _serverScript = r'''
    (() => {
      const select = document.querySelector('#player-select');
      const opts = select ? [...select.options].map(o =>
        ({name:(o.textContent||'').trim(), selected:o.selected, value:o.value})) : [];
      const links = [...document.querySelectorAll(
        '#player-list a[data-server],.player-options a[data-server]'
      )].map(a => ({name:(a.getAttribute('data-server')||a.textContent||'').trim(),
        selected:a.classList.contains('active'),value:a.getAttribute('data-url')||a.href}));
      const unique = new Map();
      for (const row of [...opts,...links]) {
        if (!row.name || !row.value ||
            /^(select|pilih|choose|ganti player)/i.test(row.name)) continue;
        const name = row.name.toUpperCase();
        if (!unique.has(name)) unique.set(name,{name,selected:row.selected});
      }
      return JSON.stringify([...unique.values()]);
    })();
  ''';

  // Metadata read directly from the source page, as in Android.
  // Do not use TMDB or catalog overviews as synopsis fallbacks.
  static const _sourceMetadataScript = r'''
    (() => {
      const text = el => (el?.textContent || '').trim().replace(/\s+/g,' ');
      // Source pages sometimes collapse the synopsis with "read more".
      // Only activate local text expansion controls, not external links.
      if (!window.__fsSynopsisExpandAttempted) {
        const candidates=[...document.querySelectorAll('button,a,[role="button"],span')];
        const expand=candidates.find(el=>{
          const label=text(el).toLowerCase();
          if(!/^(lihat selengkapnya|baca selengkapnya|selengkapnya|read more|show more|more)$/i.test(label))return false;
          if(el.tagName==='A') {
            const href=(el.getAttribute('href')||'').trim();
            if(href && href!=='#' && !href.startsWith('javascript:'))return false;
          }
          return true;
        });
        if(expand) {
          window.__fsSynopsisExpandAttempted=true;
          expand.click();
        }
      }
      const synopsisSelectors=[
        '[itemprop="description"]','.sinopsis','.synopsis',
        '.entry-content .desc','.film-synopsis','.summary','.description'
      ];
      const descriptions=synopsisSelectors
        .flatMap(sel=>[...document.querySelectorAll(sel)].map(text))
        .filter(x=>x.length>=30);
      // Meta descriptions are still directly supplied by the source page.
      for(const name of ['description','og:description','twitter:description']) {
        const meta=document.querySelector('meta[name="'+name+'"],meta[property="'+name+'"]');
        const value=(meta?.content||'').trim().replace(/\s+/g,' ');
        if(value.length>=30) descriptions.push(value);
      }
      // Prefer the longest available original source text over an abbreviated teaser.
      descriptions.sort((a,b)=>{
        const ta=/(\.\.\.|…)$/u.test(a)?1:0;
        const tb=/(\.\.\.|…)$/u.test(b)?1:0;
        return ta===tb ? b.length-a.length : ta-tb;
      });
      const synopsis=descriptions[0]||'';
      const genreNodes=document.querySelectorAll(
        '.genres a,.genre a,[rel="tag"],a[href*="/genre/"]'
      );
      return JSON.stringify({
        synopsis: synopsis,
        genres:[...new Set([...genreNodes].map(text)
          .filter(x=>x&&x.length<35))].slice(0,12),
      });
    })();
  ''';

  Future<void> _loadTmdbGenres() async {
    // Verified catalog genres are already displayed by Android; reuse them
    // on Windows instead of fetching another TMDB detail response.
    if (_tmdbGenres.isNotEmpty || widget.tmdbId <= 0 || _tmdbToken.isEmpty) return;
    try {
      final media = widget.mediaType == 'tv' || widget.mediaType == 'series'
          ? 'tv' : 'movie';
      final uri = Uri.https('api.themoviedb.org',
          '/3/$media/' + widget.tmdbId.toString(), {'language':'id-ID'});
      final response = await http.get(uri, headers: {
        'Authorization':'Bearer $_tmdbToken', 'accept':'application/json',
      }).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body);
      if (data is! Map) return;
      final genres = (data['genres'] as List? ?? const [])
          .whereType<Map>()
          .map((entry) => (entry['name'] ?? '').toString().trim())
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (mounted && genres.isNotEmpty) setState(() => _tmdbGenres = genres);
    } catch (_) {
      // Keep cached TMDB genres; if absent use LK21.
    }
  }

  Future<void> _readLk21Metadata() async {
    if (!_ready || !mounted) return;
    try {
      dynamic data = await _controller.executeScript(_sourceMetadataScript);
      for (var i = 0; i < 2 && data is String; i++) {
        data = jsonDecode(data);
      }
      if (data is! Map || !mounted) return;
      final genres = (data['genres'] as List? ?? const [])
          .whereType<String>()
          .where((name) => name.trim().isNotEmpty)
          .toSet()
          .toList(growable: false);
      final synopsis = (data['synopsis'] ?? '').toString().trim();
      final changedSynopsis = synopsis.isNotEmpty && synopsis != _lk21Synopsis;
      final changedGenres = genres.isNotEmpty &&
          genres.join('|') != _lk21Genres.join('|');
      if (changedSynopsis || changedGenres) {
        setState(() {
          if (changedSynopsis) _lk21Synopsis = synopsis;
          if (changedGenres) _lk21Genres = genres;
        });
        if (changedSynopsis) widget.onSynopsisFound?.call(synopsis);
        if (changedGenres) widget.onGenresFound?.call(genres);
      }
    } catch (_) {
      // The source may not have finished loading its detail metadata.
    }
  }

  @override
  void initState() {
    super.initState();
    _tmdbGenres = widget.genres.where((name) => name.isNotEmpty).toList();
    _loadTmdbGenres();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      // WebView2 raises this when the P2P/HYDRAX iframe uses its own
      // Fullscreen button. Move the *same* Webview into a window-filling
      // overlay; do not navigate, reload or simulate a player click.
      _nativeFullscreenSubscription =
          _controller.containsFullScreenElementChanged.listen(_onNativeFullscreen);
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.addScriptToExecuteOnDocumentCreated(_playerScript);
      await _controller.loadUrl(widget.url.toString());
      if (!mounted) return;
      setState(() => _ready = true);
      await _updateFocusAndServers();
      _poller = Timer.periodic(const Duration(seconds: 2), (_) {
        _updateFocusAndServers();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _updateFocusAndServers() async {
    if (!_ready || !mounted) return;
    await _readLk21Metadata();
    try {
      final result = await _controller.executeScript(
        "window.__filmstreamWindowsFocus ? "
        "window.__filmstreamWindowsFocus(" + (!_showFullPage).toString() +
        ") : false");
      final focus = result is Map && result['found'] == true;
      final diagnostic = result is Map
          ? 'Player: ${focus ? "ditemukan" : "belum ditemukan"} · '
            'iframe: ${result['iframe'] ?? 0} · '
            'poster: ${result['poster'] ?? 0} · '
            'area: ${result['player'] ?? "-"}'
          : 'Skrip fokus tidak memberikan hasil: ${result.runtimeType}';
      if (mounted && (_focusAvailable != focus || _playerDiagnostic != diagnostic)) {
        setState(() { _focusAvailable = focus; _playerDiagnostic = diagnostic; });
      }
      final raw = await _controller.executeScript(_serverScript);
      dynamic data = raw;
      if (data is String) data = jsonDecode(data);
      if (data is String) data = jsonDecode(data);
      if (data is! List || !mounted) return;
      final names = <String>[];
      var active = '';
      for (final item in data) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString();
        if (name.isEmpty || names.contains(name)) continue;
        names.add(name);
        if (item['selected'] == true) active = name;
      }
      if (names.join('|') != _servers.join('|') ||
          (active.isNotEmpty && active != _selectedServer)) {
        setState(() {
          _servers = names;
          if (active.isNotEmpty) _selectedServer = active;
          else if (!names.contains(_selectedServer)) {
            _selectedServer = names.isEmpty ? '' : names.first;
          }
        });
      }
    } catch (_) {
      // Source navigation may be in progress; let the next poll retry.
    }
  }

  Future<void> _switchServer(String name) async {
    if (!_ready || _switching || !_servers.contains(name)) return;
    setState(() => _switching = true);
    try {
      const js = r'''(() => {
        const name=TARGET;
        const norm=v=>(v||'').trim().toUpperCase();
        const select=document.querySelector('#player-select');
        const option=select && [...select.options].find(o=>norm(o.textContent)===name);
        if (option) {
          select.value=option.value;
          select.dispatchEvent(new Event('input',{bubbles:true}));
          select.dispatchEvent(new Event('change',{bubbles:true}));
          return true;
        }
        const link=[...document.querySelectorAll(
          '#player-list a[data-server],.player-options a[data-server]'
        )].find(a=>norm(a.getAttribute('data-server')||a.textContent)===name);
        if (link) { link.click(); return true; }
        return false;
      })()''';
      final result = await _controller.executeScript(
        js.replaceAll('TARGET', jsonEncode(name)));
      if (mounted && (result == true || result.toString() == 'true')) {
        setState(() => _selectedServer = name);
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await _updateFocusAndServers();
    } catch (_) {
      // Keep the current player if the provider refuses to switch.
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  void didUpdateWidget(covariant WindowsSourcePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready && oldWidget.url != widget.url) {
      _servers = const [];
      _selectedServer = '';
      _lk21Genres = const [];
      _lk21Synopsis = '';
      _controller.loadUrl(widget.url.toString()).then((_) =>
        _updateFocusAndServers());
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    _nativeFullscreenSubscription?.cancel();
    if (_nativeFullscreen) _fullscreenPortal.hide();
    _controller.dispose();
    super.dispose();
  }

  void _onNativeFullscreen(bool requested) {
    if (!mounted || _nativeFullscreen == requested) return;
    if (requested) {
      setState(() => _nativeFullscreen = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _nativeFullscreen) _fullscreenPortal.show();
      });
    } else {
      _fullscreenPortal.hide();
      setState(() => _nativeFullscreen = false);
    }
  }

  Widget _serverButtons() {
    if (_servers.isEmpty || _showFullPage) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: const Color(0xff17171c),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final name in _servers)
          ChoiceChip(
            label: Text(name),
            selected: name == _selectedServer,
            onSelected: _switching ? null : (_) => _switchServer(name),
          ),
      ]),
    );
  }

  Widget _playerArea() {
    if (_error != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text('Pemutar Windows gagal dimuat.\n$_error',
          textAlign: TextAlign.center),
      ));
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    // The provider's fullscreen button is never covered by Flutter. When
    // WebView2 reports HTML fullscreen, render the SAME controller at the
    // overlay's full size; the video and its seek position stay mounted.
    return OverlayPortal(
      controller: _fullscreenPortal,
      overlayChildBuilder: (_) => Positioned.fill(
        child: ColoredBox(color: Colors.black, child: Webview(_controller)),
      ),
      child: _nativeFullscreen
        ? const ColoredBox(color: Colors.black)
        : Webview(_controller),
    );
  }

  Widget _informationPanel() {
    final synopsis = _lk21Synopsis.isNotEmpty
        ? _lk21Synopsis : widget.catalogSynopsis.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
      decoration: const BoxDecoration(
        color: Color(0xff191c24),
        border: Border(top: BorderSide(color: Color(0xff30343d))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title, style: const TextStyle(
          fontWeight: FontWeight.w800, fontSize: 21)),
        const SizedBox(height: 9),
        if (widget.year.isNotEmpty || _displayGenres.isNotEmpty)
          Wrap(spacing: 7, runSpacing: 7, crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (widget.year.isNotEmpty)
                Chip(label: Text(widget.year), visualDensity: VisualDensity.compact),
              for (final genre in _displayGenres)
                Chip(label: Text(genre), visualDensity: VisualDensity.compact),
            ]),
        const SizedBox(height: 15),
        const Text('Sinopsis', style: TextStyle(
          fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xffe5aa55))),
        const SizedBox(height: 7),
        Text(synopsis.isNotEmpty ? synopsis : 'Sinopsis belum tersedia untuk judul ini.',
          style: const TextStyle(fontSize: 14, height: 1.55, color: Colors.white70)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerBody = Column(children: [
      Expanded(child: ColoredBox(color: Colors.black, child: _playerArea())),
      _serverButtons(),
    ]);
    if (widget.embedded) {
      // Windows window width can make a 16:9 player taller than the screen.
      // Leave room for the scrollable title/genre/synopsis below in DetailPage.
      final viewport = MediaQuery.sizeOf(context);
      // Fill the left desktop column vertically; only the metadata scrolls
      // on the right. A single-column window keeps a smaller player.
      final isWide = viewport.width >= 960;
      final availableHeight = isWide
          ? (viewport.height - 146).clamp(330.0, 800.0)
          : (viewport.height * 0.46).clamp(235.0, 440.0);
      return SizedBox(
        width: double.infinity,
        height: availableHeight,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(color: Colors.black, child: playerBody),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _ready ? () => _controller.loadUrl(widget.url.toString()) : null,
            icon: const Icon(FilmStreamIcons.reload),
          ),

        ],
      ),
      body: Column(children: [
        Expanded(child: playerBody),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 265),
          child: SingleChildScrollView(child: _informationPanel()),
        ),
      ]),
    );
  }
}
