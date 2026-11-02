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

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.loadUrl(widget.url.toString());
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void didUpdateWidget(covariant WindowsSourcePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready && oldWidget.url != widget.url) {
      _controller.loadUrl(widget.url.toString());
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
      body: ColoredBox(color: Colors.black, child: player),
    );
  }
}
