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
  // Only display the existing page's player section. The page and iframe
  // remain on their real HTTPS origins; this is a visual layout change.
  Future<void> _applyFocus() async {
    try {
      await _controller.runJavaScript(r'''
        (() => {
          const player = document.querySelector('.player-section-wrapper .main-player');
          if (!player) return; // Search/listing pages stay fully navigable.
          let style = document.getElementById('filmstream-focus-style');
          if (!style) {
            style = document.createElement('style');
            style.id = 'filmstream-focus-style';
            document.head.appendChild(style);
          }
          style.textContent = `
            html, body { margin:0!important; padding:0!important; width:100%!important;
              overflow-x:hidden!important; background:#101014!important; }
            body > :not(main):not(script):not(style),
            main.site-content > :not(.player-section-wrapper),
            .player-right, .related-content, .mob-related-video,
            .player-action, .iframe-loader + .cinema-toggle,
            .simple-box, #nativeAds, .bottom-nav, .mobile-bottom-nav,
            .sticky-bottom, .floating-ads, .ads-container,
            .player-section-wrapper .player-right { display:none!important; }
            main.site-content, .player-section-wrapper, .player-section-wrapper .container,
            .player-area, .player-wrapper, .player-left, .main-player,
            .main-section, .player-section-wrapper .player-options {
              display:block!important; position:relative!important; float:none!important;
              box-sizing:border-box!important; width:100%!important; max-width:100%!important;
              min-width:0!important; margin:0!important; padding:0!important;
              height:auto!important; min-height:0!important; overflow:visible!important;
              background:#101014!important; color:#fff!important;
            }
            .player-wrapper { display:block!important; }
            .main-player iframe#main-player, .main-player iframe {
              display:block!important; width:100%!important; max-width:100%!important;
              height:56.25vw!important; min-height:210px!important; max-height:65vh!important;
              border:0!important; margin:0!important;
            }
            .player-options { padding:12px 10px!important; background:#211a1a!important; }
            .player-options #player-list, .player-options #player-select { max-width:100%!important; }
            .player-options select { display:block!important; width:100%!important;
              min-height:45px!important; color:#fff!important; background:#302626!important; }
          `;
          document.documentElement.scrollTop=0;
          document.body.scrollTop=0;
          window.scrollTo(0,0);
        })();
      ''');
    } catch (_) { /* If unavailable, preserve original page and full-view toggle. */ }
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
