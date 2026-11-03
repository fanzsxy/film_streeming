import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

/// Windows-only source player. Embeds WebView2 inside the Film Streaming window.
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
  String? _error;
  bool _ready = false;
  bool _showFullPage = false;

  // Inject before page parsing; keep video/iframe and its own server controls.
  static const _focusScript = r'''
    (() => {
      if (window.__filmstreamSetFocus) return;
      const attr = 'data-filmstream-hidden';
      const controls = '#player-select,#player-list,.player-options,.server-list,.servers,.list-server,.episodes,.episode-list,.season-list,.ganti-player';
      const selectors = '#player,#movie-player,#video-player,.player-container,.player-wrapper,.player-area,.video-container,.video-player,.watch-player,.embed-responsive,video,iframe';
      let focused = true, currentPlayer = null, scheduled = false;

      function ensureStyle() {
        if (!document.documentElement || document.getElementById('filmstream-style')) return;
        const style = document.createElement('style');
        style.id = 'filmstream-style';
        style.textContent = [
          'html.filmstream-focus, html.filmstream-focus body {background:#101218!important;}',
          'html.filmstream-focus [data-filmstream-hidden] {display:none!important;}',
          'html.filmstream-focus header, html.filmstream-focus nav,',
          'html.filmstream-focus footer, html.filmstream-focus aside,',
          'html.filmstream-focus #header, html.filmstream-focus #footer,',
          'html.filmstream-focus .site-header, html.filmstream-focus .navbar,',
          'html.filmstream-focus .sidebar, html.filmstream-focus #sidebar,',
          'html.filmstream-focus .related-movies, html.filmstream-focus .movie-related,',
          'html.filmstream-focus .related-film, html.filmstream-focus .search-form',
          '{display:none!important;}',
          'html.filmstream-focus main, html.filmstream-focus .container',
          '{max-width:100%!important;width:100%!important;}'
        ].join(' ');
        (document.head || document.documentElement).appendChild(style);
      }

      function findPlayer() {
        for (const el of document.querySelectorAll(selectors)) {
          if (!el.isConnected || el.closest('header,nav,aside,footer')) continue;
          const box = el.getBoundingClientRect();
          if (box.width < 260 || box.height < 140) continue;
          if (el.matches('video,iframe')) {
            return el.closest('#player,.player-container,.player-wrapper,.video-container,.player-area') || el;
          }
          return el;
        }
        return null;
      }
      function hasControls(el) {
        return el.matches(controls) || !!el.querySelector(controls);
      }
      function apply() {
        ensureStyle();
        if (!document.documentElement || !document.body) return;
        document.documentElement.classList.toggle('filmstream-focus',focused);
        if (!focused) return;
        const player = findPlayer();
        if (!player) return;
        if (currentPlayer !== player) {
          document.querySelectorAll('['+attr+']').forEach(el=>el.removeAttribute(attr));
          currentPlayer=player;
        }
        let node=player;
        while (node && node!==document.body && node.parentElement) {
          for (const sibling of node.parentElement.children) {
            if (sibling===node || ['STYLE','SCRIPT','LINK'].includes(sibling.tagName) ||
                sibling.hasAttribute(attr) || hasControls(sibling)) continue;
            sibling.setAttribute(attr,'');
          }
          node=node.parentElement;
        }
      }
      function schedule() {
        if (scheduled) return;
        scheduled=true;
        requestAnimationFrame(()=>{scheduled=false;apply();});
      }
      window.__filmstreamSetFocus=(enable)=>{
        focused=!!enable;
        if (!focused) document.documentElement?.classList.remove('filmstream-focus');
        schedule();
      };
      ensureStyle();
      document.addEventListener('DOMContentLoaded',schedule,{once:true});
      const observe=()=>{
        if (!document.documentElement) return;
        new MutationObserver(schedule).observe(document.documentElement,{childList:true,subtree:true});
        schedule();
      };
      if (document.documentElement) observe();
      else document.addEventListener('DOMContentLoaded',observe,{once:true});
    })();
  ''';

  Future<void> _applyFocus() async {
    if (!_ready) return;
    try {
      await _controller.executeScript(_focusScript);
      await _controller.executeScript(
        'window.__filmstreamSetFocus && window.__filmstreamSetFocus(' +
        (!_showFullPage).toString() + ')');
    } catch (_) { /* Retain the source player when injection is restricted. */ }
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.addScriptToExecuteOnDocumentCreated(_focusScript);
      await _controller.loadUrl(widget.url.toString());
      if (mounted) setState(() => _ready = true);
      await _applyFocus();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void didUpdateWidget(covariant WindowsSourcePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready && oldWidget.url != widget.url) {
      _controller.loadUrl(widget.url.toString()).then((_) => _applyFocus());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _error != null
        ? Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Pemutar Windows gagal dibuka. Periksa Microsoft Edge WebView2 Runtime.\n$_error',
              textAlign: TextAlign.center,
            )))
        : !_ready
            ? const Center(child: CircularProgressIndicator())
            : Webview(_controller);
    if (widget.embedded) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(color: Colors.black, child: player),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Muat ulang halaman',
            icon: const Icon(Icons.refresh),
            onPressed: _ready ? () => _controller.loadUrl(widget.url.toString()) : null,
          ),
        ],
      ),
      body: Column(children: [
        Container(
          color: const Color(0xff171b22),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(children: [
            const Icon(Icons.smart_display_outlined, color: Color(0xffe5aa55)),
            const SizedBox(width: 10),
            const Expanded(child: Text('FILM STREAMING  •  Pemutar desktop',
              style: TextStyle(fontWeight: FontWeight.bold))),
            TextButton.icon(
              onPressed: _ready ? () {
                setState(() => _showFullPage = !_showFullPage);
                _applyFocus();
              } : null,
              icon: Icon(_showFullPage ? Icons.fullscreen : Icons.article_outlined),
              label: Text(_showFullPage ? 'Mode fokus' : 'Halaman sumber'),
            ),
          ]),
        ),
        Expanded(child: ColoredBox(color: Colors.black, child: player)),
        const Padding(
          padding: EdgeInsets.all(7),
          child: Text('Video disediakan situs sumber; ketersediaan pemutaran mengikuti situs tersebut.',
            style: TextStyle(fontSize: 11, color: Colors.white54)),
        ),
      ]),
    );
  }
}
