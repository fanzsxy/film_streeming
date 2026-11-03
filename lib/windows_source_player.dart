import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

/// Windows WebView2 version of the Android focused source player.
/// Keep the provider-owned iframe and its JS in the original document.
class WindowsSourcePlayer extends StatefulWidget {
  final String title;
  final Uri url;
  final bool embedded;
  const WindowsSourcePlayer({
    super.key, required this.title, required this.url, this.embedded = false,
  });

  @override
  State<WindowsSourcePlayer> createState() => _WindowsSourcePlayerState();
}

class _WindowsSourcePlayerState extends State<WindowsSourcePlayer> {
  final WebviewController _controller = WebviewController();
  Timer? _poller;
  bool _ready = false;
  bool _showFullPage = false;
  bool _focusAvailable = false;
  bool _switching = false;
  String? _error;
  List<String> _servers = const [];
  String _selectedServer = '';

  // Match Android WebSourcePage's tested player selectors.
  // Do not promote the iframe to a new URL or modify playback requests.
  static const _playerScript = r'''
    (() => {
      if (window.__filmstreamWindowsFocus) return true;
      let focused = true;
      let scheduled = false;
      function locate() {
        const shell = document.querySelector(
          '.player-section-wrapper, .player-area, .main-player'
        ) || document.querySelector('iframe#main-player')?.parentElement;
        const iframe = shell?.querySelector('iframe#main-player, iframe[src]');
        const player = document.querySelector('.main-player') ||
          iframe?.closest('.player-wrapper, .player-area');
        return shell && iframe && player ? {shell,iframe,player} : null;
      }
      function style() {
        let el = document.getElementById('fs-windows-player-style');
        if (el) return;
        el = document.createElement('style');
        el.id = 'fs-windows-player-style';
        el.textContent = [
          'html.fs-windows-player,html.fs-windows-player body {',
          'margin:0!important;padding:0!important;background:#101014!important;',
          'overflow:hidden!important;overscroll-behavior:none!important;}',
          'html.fs-windows-player .player-section-wrapper {top:0!important;transform:none!important;}',
          'html.fs-windows-player body > nav,html.fs-windows-player body > header,',
          'html.fs-windows-player body > footer,html.fs-windows-player .sub-header,',
          'html.fs-windows-player .main-header,html.fs-windows-player .main-section,',
          'html.fs-windows-player .player-right,html.fs-windows-player .mobile-nav,',
          'html.fs-windows-player .site-footer,html.fs-windows-player .bottom-nav,',
          'html.fs-windows-player .mobile-bottom-nav,',
          'html.fs-windows-player .player-section-wrapper ~ * {display:none!important;}',
          'html.fs-windows-player .player-section-wrapper,',
          'html.fs-windows-player .player-section-wrapper .container,',
          'html.fs-windows-player .player-area,',
          'html.fs-windows-player .player-wrapper,',
          'html.fs-windows-player .player-left {width:100%!important;',
          'max-width:100%!important;margin:0!important;padding:0!important;',
          'box-sizing:border-box!important;}',
          'html.fs-windows-player .player-section-wrapper .player-action {display:none!important;}',
          'html.fs-windows-player .player-options,',
          'html.fs-windows-player #player-list {position:absolute!important;',
          'left:-20000px!important;top:0!important;width:1px!important;',
          'height:1px!important;overflow:hidden!important;opacity:0!important;',
          'pointer-events:none!important;}',
          'html.fs-windows-player .main-player {width:100vw!important;',
          'max-width:100vw!important;height:100vh!important;min-height:0!important;',
          'margin:0!important;padding:0!important;overflow:hidden!important;',
          'position:fixed!important;top:0!important;left:0!important;',
          'z-index:2147483640!important;background:#000!important;}',
          'html.fs-windows-player .main-player > iframe,',
          'html.fs-windows-player .main-player > #main-player {',
          'display:block!important;position:absolute!important;inset:0!important;',
          'width:100%!important;height:100%!important;min-height:0!important;',
          'max-height:100%!important;border:0!important;margin:0!important;}'
        ].join(' ');
        (document.head || document.documentElement).appendChild(el);
      }
      function apply() {
        if (!document.documentElement || !document.body) return;
        const player = locate();
        document.documentElement.classList.toggle('fs-windows-player',
          focused && !!player);
        if (focused && player) {
          window.scrollTo(0, 0);
          document.documentElement.scrollTop = 0;
          document.body.scrollTop = 0;
        }
      }
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; apply(); });
      }
      window.__filmstreamWindowsFocus = (value) => {
        focused = !!value;
        schedule();
        return !!locate();
      };
      style();
      document.addEventListener('DOMContentLoaded', schedule);
      const observe = () => {
        if (!document.documentElement) return;
        new MutationObserver(schedule).observe(document.documentElement,
          {childList:true, subtree:true});
        schedule();
      };
      if (document.documentElement) observe();
      else document.addEventListener('DOMContentLoaded',observe,{once:true});
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

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
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
    try {
      final result = await _controller.executeScript(
        "window.__filmstreamWindowsFocus ? "
        "window.__filmstreamWindowsFocus(" + (!_showFullPage).toString() +
        ") : false");
      final focus = result == true || result.toString() == 'true';
      if (mounted && _focusAvailable != focus) setState(() => _focusAvailable = focus);
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
      _controller.loadUrl(widget.url.toString()).then((_) =>
        _updateFocusAndServers());
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _toggleSourcePage() {
    setState(() => _showFullPage = !_showFullPage);
    _updateFocusAndServers();
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
        child: Text('Pemutar Windows gagal dimuat.\n$_error',textAlign:TextAlign.center),
      ));
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return Stack(children: [
      Positioned.fill(child: Webview(_controller)),
      if (!_focusAvailable && !_showFullPage)
        Positioned(left: 12, right: 12, bottom: 8, child: Align(
          alignment: Alignment.bottomCenter,
          child: TextButton.icon(
            onPressed: _toggleSourcePage,
            icon: const Icon(Icons.article_outlined),
            label: const Text('Player belum ditemukan · Tampilkan halaman sumber'),
          ),
        )),
      Positioned(right: 10, top: 10, child: Material(
        color: const Color(0xdd171b22),
        borderRadius: BorderRadius.circular(9),
        child: IconButton(
          tooltip: _showFullPage ? 'Kembali ke player' : 'Halaman sumber',
          onPressed: _toggleSourcePage,
          icon: Icon(_showFullPage ? Icons.smart_display_outlined : Icons.article_outlined),
        ),
      )),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(children: [
      Expanded(child: ColoredBox(color: Colors.black, child: _playerArea())),
      _serverButtons(),
    ]);
    if (widget.embedded) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(color: Colors.black, child: body),
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
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: _showFullPage ? 'Mode player' : 'Halaman sumber',
            onPressed: _ready ? _toggleSourcePage : null,
            icon: Icon(_showFullPage ? Icons.smart_display_outlined : Icons.crop_free),
          ),
        ],
      ),
      body: body,
    );
  }
}
