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

  static const _focusScript = r'''
    (() => {
      const styleId = 'filmstream-desktop-focus';
      if (document.getElementById(styleId)) return;
      const style = document.createElement('style');
      style.id = styleId;
      style.textContent = `
        body.filmstream-desktop-focus { background: #101218 !important; }
        body.filmstream-desktop-focus > header,
        body.filmstream-desktop-focus > nav,
        body.filmstream-desktop-focus > footer,
        body.filmstream-desktop-focus aside,
        body.filmstream-desktop-focus .sidebar,
        body.filmstream-desktop-focus #sidebar,
        body.filmstream-desktop-focus .related-movies,
        body.filmstream-desktop-focus .movie-related,
        body.filmstream-desktop-focus .navbar,
        body.filmstream-desktop-focus #navbar,
        body.filmstream-desktop-focus .breadcrumb,
        body.filmstream-desktop-focus .breadcrumbs,
        body.filmstream-desktop-focus .search-form { display: none !important; }
        body.filmstream-desktop-focus main,
        body.filmstream-desktop-focus .container,
        body.filmstream-desktop-focus .content,
        body.filmstream-desktop-focus .main-content { max-width: none !important; width: 100% !important; margin: 0 auto !important; }
      `;
      (document.head || document.documentElement).appendChild(style);
    })();
  ''';

  Future<void> _applyFocus() async {
    if (!_ready) return;
    try {
      await _controller.executeScript(_focusScript);
      await _controller.executeScript(
        "document.body && document.body.classList.toggle('filmstream-desktop-focus', ${!_showFullPage})");
    } catch (_) { /* The source page may have navigated. */ }
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
      await _controller.addScriptToExecuteOnDocumentCreated(r'''
        document.addEventListener('DOMContentLoaded', () => {
          if (!document.body || !location.hostname.endsWith('lk21official.cc')) return;
          document.body.classList.add('filmstream-desktop-focus');
        });
      ''');
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
