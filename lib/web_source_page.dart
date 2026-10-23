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
        onPageStarted: (_) { if (mounted) setState(() { _loading=true; _error=null; _progress=0; }); },
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
  // Persistent visual focus: keep the source page and original iframe intact.
  // Re-applies when the site's JavaScript changes layout or inserts a player.
  Future<void> _applyFocus() async {
    try {
      await _controller.runJavaScript(r'''
        (() => {
          const css = `
            html.fs-focus, html.fs-focus body { margin:0!important; padding:0!important;
              background:#101014!important; overflow-x:hidden!important; }
            html.fs-focus body > header, html.fs-focus body > nav,
            html.fs-focus body > footer, html.fs-focus body > aside,
            html.fs-focus .mobile-nav, html.fs-focus .main-header,
            html.fs-focus .sub-header, html.fs-focus .main-section,
            html.fs-focus .player-right, html.fs-focus .related-content,
            html.fs-focus .mob-related-video, html.fs-focus .player-action,
            html.fs-focus #nativeAds, html.fs-focus .bottom-nav,
            html.fs-focus .mobile-bottom-nav, html.fs-focus .sticky-bottom,
            html.fs-focus .floating-ads, html.fs-focus .ads-container,
            html.fs-focus .site-footer, html.fs-focus .footer,
            html.fs-focus .player-section-wrapper ~ * { display:none!important; }
            html.fs-focus main.site-content, html.fs-focus .player-section-wrapper,
            html.fs-focus .player-section-wrapper .container,
            html.fs-focus .player-area, html.fs-focus .player-wrapper,
            html.fs-focus .player-left { display:block!important; position:relative!important;
              box-sizing:border-box!important; width:100%!important; max-width:100%!important;
              min-width:0!important; margin:0!important; padding:0!important;
              height:auto!important; min-height:0!important; overflow:visible!important;
              background:#101014!important; float:none!important; }
            html.fs-focus .main-player { display:block!important; width:100%!important;
              max-width:100%!important; margin:0!important; padding:0!important;
              background:#000!important; position:relative!important; }
            html.fs-focus iframe#main-player { display:block!important; width:100%!important;
              max-width:100%!important; height:56.25vw!important; min-height:210px!important;
              max-height:65vh!important; border:0!important; margin:0!important; }
            html.fs-focus .player-options { display:block!important; width:100%!important;
              padding:12px 10px!important; box-sizing:border-box!important;
              background:#211a1a!important; color:#fff!important; }
            html.fs-focus .player-options select { display:block!important; width:100%!important;
              min-height:45px!important; color:#fff!important; background:#302626!important; }
          `;
          const ensure = () => {
            const hasPlayer = !!document.querySelector('.player-section-wrapper .main-player');
            document.documentElement.classList.toggle('fs-focus', hasPlayer && window.__filmstreamFocus === true);
            let node = document.getElementById('filmstream-focus-style');
            if (!node) { node = document.createElement('style'); node.id='filmstream-focus-style'; document.head.appendChild(node); }
            if (node.textContent !== css) node.textContent = css;
            if (hasPlayer && window.__filmstreamFocus) {
              const shell = document.querySelector('.player-section-wrapper');
              if (shell && !shell.dataset.fsFocused) { shell.dataset.fsFocused='1'; window.scrollTo(0,0); }
            }
          };
          window.__filmstreamFocus = true;
          ensure();
          if (!window.__filmstreamFocusObserver) {
            window.__filmstreamFocusObserver = new MutationObserver(() => {
              if (window.__filmstreamFocusQueued) return;
              window.__filmstreamFocusQueued = true;
              requestAnimationFrame(() => { window.__filmstreamFocusQueued = false; ensure(); });
            });
            window.__filmstreamFocusObserver.observe(document.documentElement,{childList:true,subtree:true});
          }
        })();
      ''');
    } catch (_) { /* Keep the actual page accessible if visual focus fails. */ }
  }
  Future<void> _setFocused(bool next) async {
    setState(() => _focused=next);
    if (next) { await _applyFocus(); }
    else {
      try { await _controller.runJavaScript("window.__filmstreamFocus=false; document.documentElement.classList.remove('fs-focus');"); } catch (_) {}
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
