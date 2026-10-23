import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Shows the actual source page inside FilmStream. Focus mode is visual only:
/// no UA spoofing, no interception of player URLs, and no access-control bypass.
class WebSourcePage extends StatefulWidget {
  final String title;
  final Uri url;
  final bool focused;
  const WebSourcePage({super.key, required this.title, required this.url, this.focused = false});
  @override State<WebSourcePage> createState() => _WebSourcePageState();
}
class _WebSourcePageState extends State<WebSourcePage> {
  late final WebViewController _controller;
  late bool _focused;
  bool _loading = true;
  int _progress = 0;
  String? _error;
  @override void initState() {
    super.initState();
    _focused = widget.focused;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xff101014))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) { if (mounted) setState(() => _progress=p); },
        onPageStarted: (_) { if (mounted) setState(() { _loading=true; _error=null; }); },
        onPageFinished: (_) async {
          if (_focused) await _applyFocus();
          if (mounted) setState(() => _loading=false);
        },
        onWebResourceError: (e) { if (e.isForMainFrame == true && mounted) setState(() { _error=e.description; _loading=false; }); },
        onNavigationRequest: (r) {
          final next = Uri.tryParse(r.url);
          if (next == null || (next.scheme != 'https' && next.scheme != 'about')) return NavigationDecision.prevent;
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(widget.url);
  }
  // Only applies to the known page's own layout. Search results remain intact.
  Future<void> _applyFocus() async {
    try {
      await _controller.runJavaScript(r'''
        (() => {
          if (!document.querySelector('.main-player iframe')) return;
          if (document.getElementById('filmstream-focus-style')) return;
          const css = document.createElement('style');
          css.id='filmstream-focus-style';
          css.textContent = `
            body { background:#101014 !important; }
            header, nav, .mobile-nav, .sub-header, .player-right,
            .related-content, .mob-related-video, footer, .simple-box,
            .player-action, .movie-action, .content-wrapper > .content-right
            { display:none !important; }
            .container, .container2, .player-area, .player-wrapper,
            .player-left, .main-player, .player-section-wrapper
            { max-width:100% !important; width:100% !important; margin:0 !important; padding:0 !important; }
            .main-player iframe { width:100% !important; aspect-ratio:16 / 9; min-height:220px; }
            .player-options { display:block !important; }
          `;
          document.head.appendChild(css);
          document.querySelector('.main-player')?.scrollIntoView({block:'start'});
        })();
      ''');
    } catch (_) { /* Preserve full original page when injection is unavailable. */ }
  }
  Future<void> _setFocused(bool next) async {
    setState(() => _focused=next);
    if (next) { await _applyFocus(); }
    else {
      try { await _controller.runJavaScript("document.getElementById('filmstream-focus-style')?.remove();"); } catch (_) {}
    }
  }
  Future<void> _back() async {
    if (await _controller.canGoBack()) { await _controller.goBack(); }
    else if (mounted) { Navigator.of(context).pop(); }
  }
  Future<void> _external() async {
    final current = Uri.tryParse(await _controller.currentUrl() ?? '') ?? widget.url;
    if (current.scheme == 'https') await launchUrl(current, mode: LaunchMode.externalApplication);
  }
  @override Widget build(BuildContext context) => PopScope(
    canPop:false,
    onPopInvokedWithResult:(didPop,_) { if (!didPop) _back(); },
    child: Scaffold(
      appBar:AppBar(title:Text(widget.title,maxLines:1,overflow:TextOverflow.ellipsis),
        leading:IconButton(tooltip:'Kembali',icon:const Icon(Icons.arrow_back),onPressed:_back),
        actions:[
          IconButton(tooltip:_focused?'Lihat halaman lengkap':'Fokus player',icon:Icon(_focused?Icons.crop_free:Icons.smart_display_outlined),onPressed:()=>_setFocused(!_focused)),
          IconButton(tooltip:'Refresh',icon:const Icon(Icons.refresh),onPressed:()=>_controller.reload()),
          IconButton(tooltip:'Buka browser',icon:const Icon(Icons.open_in_browser),onPressed:_external),
        ],
        bottom:_loading?PreferredSize(preferredSize:const Size.fromHeight(3),child:LinearProgressIndicator(value:_progress==0?null:_progress/100)):null),
      body:Column(children:[
        const Padding(padding:EdgeInsets.symmetric(horizontal:12,vertical:6),child:Text('Player dari halaman sumber asli. Gunakan tombol tampilan lengkap jika pilihan server atau video tidak terlihat.',style:TextStyle(fontSize:11,color:Colors.white60))),
        Expanded(child:Stack(children:[
          WebViewWidget(controller:_controller),
          if(_error!=null) Positioned.fill(child:ColoredBox(color:const Color(0xff101014),child:Center(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,children:[Text('Halaman gagal dimuat: $_error',textAlign:TextAlign.center),const SizedBox(height:12),FilledButton(onPressed:()=>_controller.reload(),child:const Text('Coba lagi')),TextButton(onPressed:_external,child:const Text('Buka di browser'))]))))),
        ])),
      ]),
    ),
  );
}
