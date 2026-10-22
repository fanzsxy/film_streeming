import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Opens an intact HTTPS source page. Does not extract media, alter headers,
/// spoof referrers, inject scripts, or claim third-party playback rights.
class WebSourcePage extends StatefulWidget {
  final String title;
  final Uri url;
  const WebSourcePage({super.key, required this.title, required this.url});

  @override
  State<WebSourcePage> createState() => _WebSourcePageState();
}

class _WebSourcePageState extends State<WebSourcePage> {
  late final WebViewController _controller;
  int _progress = 0;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF101014))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
        onPageStarted: (_) {
          if (mounted) setState(() { _loading = true; _error = null; });
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted) {
            setState(() { _loading = false; _error = error.description; });
          }
        },
        onNavigationRequest: (request) {
          final target = Uri.tryParse(request.url);
          if (target == null || target.scheme != 'https') {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(widget.url);
  }

  Future<void> _back() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) { if (!didPop) _back(); },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: IconButton(tooltip: 'Kembali', icon: const Icon(Icons.arrow_back), onPressed: _back),
        actions: [
          IconButton(tooltip: 'Muat ulang', icon: const Icon(Icons.refresh), onPressed: () => _controller.reload()),
          IconButton(tooltip: 'Buka di browser', icon: const Icon(Icons.open_in_browser),
            onPressed: () async {
              final current = await _controller.currentUrl();
              final url = Uri.tryParse(current ?? '') ?? widget.url;
              if (url.scheme == 'https') await launchUrl(url, mode: LaunchMode.externalApplication);
            }),
        ],
        bottom: _loading ? PreferredSize(preferredSize: const Size.fromHeight(3), child: LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100)) : null,
      ),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text('Halaman eksternal. Pemutaran, subtitle, dan fullscreen mengikuti dukungan serta izin situs sumber. Posisi video web tidak disimpan oleh FilmStream.', style: TextStyle(fontSize: 11, color: Colors.white60)),
        ),
        Expanded(child: Stack(children: [
          WebViewWidget(controller: _controller),
          if (_error != null) ColoredBox(color: const Color(0xFF101014), child: Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Gagal membuka halaman: $_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => _controller.reload(), child: const Text('Coba lagi')),
            TextButton(onPressed: () => launchUrl(widget.url, mode: LaunchMode.externalApplication), child: const Text('Buka di browser')),
          ])))),
        ])),
      ]),
    ),
  );
}
