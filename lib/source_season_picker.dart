import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Reads season and episode choices from the source website, never from TMDB.
/// The WebView only inspects the show's page; playback is mounted by the parent
/// after the user explicitly chooses an episode link.
class SourceSeasonPicker extends StatefulWidget {
  final Uri source;
  final String title;
  final String year;
  final void Function(int season, int episode, Uri url) onEpisodeSelected;
  const SourceSeasonPicker({super.key, required this.source, required this.title, required this.year, required this.onEpisodeSelected});
  @override State<SourceSeasonPicker> createState()=>_SourceSeasonPickerState();
}
class _SourceSeasonPickerState extends State<SourceSeasonPicker> {
  late final WebViewController controller;
  final Map<int,List<({int episode,Uri uri})>> episodes={};
  List<int> seasons=[];
  int? selected;
  bool loading=true;
  bool changingSeason=false;
  int _scanVersion=0;
  int? _pendingSeason;
  bool _initialSeasonSynced=false;
  bool triedSearch=false;
  bool showSourcePage=false;
  Uri? resolvedPage;
  String? error;
  @override void initState(){
    super.initState();
    controller=WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished:(_){ if(mounted) _scan(expectedSeason:_pendingSeason); },
        onWebResourceError:(e){
          if(e.isForMainFrame==true && mounted)setState((){loading=false;error='Halaman sumber gagal dibuka.';});
        },
      ))
      ..loadRequest(widget.source);
  }
  Future<void> _scan({int? expectedSeason}) async {
    final version=++_scanVersion;
    try {
      if(!triedSearch && widget.source.path.startsWith('/search')){
        triedSearch=true;
        final js=r'''(() => {
          const norm=x=>(x||'').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim();
          const wanted=norm(TITLE),year=YEAR;
          const found=[...document.querySelectorAll('a[href]')].filter(a=>{
            const item=a.closest('article,.item,.result,.movie,.film,.poster');
            return norm(a.textContent||a.getAttribute('title'))===wanted &&
                   (item?.textContent||a.textContent||'').includes(year);
          });
          if(found.length!==1)return '';
          const u=new URL(found[0].href,location.href);
          return u.protocol==='https:'&&u.host===location.host?u.href:'';
        })()'''.replaceAll('TITLE',jsonEncode(widget.title))
          .replaceAll('YEAR',jsonEncode(widget.year));
        final raw=await controller.runJavaScriptReturningResult(js);
        final target=Uri.tryParse(raw.toString().replaceAll('"',''));
        final current=Uri.tryParse(await controller.currentUrl()??'');
        if(target!=null && target.scheme=='https' && current!=null && target.host==current.host){
          await controller.loadRequest(target);
          return;
        }
      }
      final currentPage=Uri.tryParse(await controller.currentUrl()??'');
      if(currentPage!=null && currentPage.scheme=='https')resolvedPage=currentPage;
      final result=await controller.runJavaScriptReturningResult(r'''(() => {
        // Do not start playback while only selecting episodes.
        document.querySelectorAll('video').forEach(v => {try { v.pause(); } catch (_) {}});
        const opts=[];
        document.querySelectorAll('select').forEach((s,index)=>{
          [...s.options].forEach(o=>{
            const m=((o.textContent||'')+' '+o.value).match(/(?:season|musim)\s*([0-9]+)/i);
            if(m)opts.push({number:Number(m[1]),select:index,value:o.value});
          });
        });
        const fallback=location.pathname.match(/(?:season|musim)[-_ ]*(\d+)/i);
        const current=(document.querySelector('select option:checked')?.textContent||'').match(/(?:season|musim)\s*(\d+)/i);
        const active=Number(current?.[1]||fallback?.[1]||opts.find(o=>o.value===document.querySelector('select')?.value)?.number||0);
        const episodes=[];
        // Some source pages render numbered episodes as bare anchors in a
        // season panel, rather than using an "episode" CSS class.
        const selector='a[href],a[data-href],a[data-url]';
        const root=[...document.querySelectorAll('select')].find(s=>
          [...s.options].some(o=>/(?:season|musim)\s*\d+/i.test(o.textContent||'')));
        const seasonPanel=root?.closest('section,.row,.box,.content,.entry-content')||null;
        document.querySelectorAll(selector).forEach(a=>{
          const raw=a.getAttribute('href')||a.dataset.href||a.dataset.url;
          if(!raw||raw==='#'||raw.startsWith('javascript:'))return;
          let uri;try{uri=new URL(raw,location.href);}catch(_){return;}
          if(uri.protocol!=='https:'||uri.host!==location.host)return;
          const explicit=uri.pathname.match(/(?:season|musim)[-_ ]*(\d+).*?(?:episode|eps?|ep)[-_ ]*0*(\d+)/i);
          const numberText=(a.textContent||'').trim().match(/^(?:episode|eps?|ep)?\s*0*(\d+)$/i);
          const panel=a.closest('.episode,.episodes,.episode-list,.episode-grid,.ep-list,.series-episode,.server-episode,.episode-items,.episodelist,.episode-container,[class*="episode"],[id*="episode"]');
          const insidePanel=seasonPanel&&seasonPanel.contains(a);
          const sn=explicit?Number(explicit[1]):active;
          const ep=explicit?Number(explicit[2]):numberText&&(panel||insidePanel)?Number(numberText[1]):0;
          if(sn>0&&ep>0&&ep<1000&&(explicit||panel||insidePanel)){
            episodes.push({season:sn,episode:ep,url:uri.href});
          }
        });
        return JSON.stringify({opts,episodes,active});
      })()''');
      dynamic decoded=result;
      if(decoded is String){try{decoded=jsonDecode(decoded);}catch(_){}}
      if(decoded is String){try{decoded=jsonDecode(decoded);}catch(_){}}
      if(decoded is! Map || !mounted || version!=_scanVersion)return;
      final actualSeason=(decoded['active'] as num?)?.toInt()??0;
      if(expectedSeason!=null && actualSeason!=expectedSeason)return;
      final found=<int,List<({int episode,Uri uri})>>{};
      final seasonNums=<int>{};
      for(final raw in (decoded['opts'] as List? ?? const [])){
        if(raw is Map && raw['number'] is num)seasonNums.add((raw['number'] as num).toInt());
      }
      for(final raw in (decoded['episodes'] as List? ?? const [])){
        if(raw is! Map)continue;
        final sn=(raw['season'] as num?)?.toInt()??0,ep=(raw['episode'] as num?)?.toInt()??0;
        final uri=Uri.tryParse((raw['url']??'').toString());
        if(sn<1||ep<1||uri==null||uri.scheme!='https' || (resolvedPage!=null && uri.host!=resolvedPage!.host))continue;
        seasonNums.add(sn);
        final list=found.putIfAbsent(sn,()=>[]);
        if(!list.any((e)=>e.episode==ep))list.add((episode:ep,uri:uri));
      }
      for(final list in found.values)list.sort((a,b)=>a.episode.compareTo(b.episode));
      final ordered=seasonNums.toList()..sort();
      setState((){
        seasons=ordered;
        // Preserve previously visited seasons; a new page may expose only one season.
        for(final entry in found.entries){
          final existing=episodes[entry.key]??const <({int episode,Uri uri})>[];
          // A delayed or partially rendered DOM must not shrink an indexed season.
          if(entry.value.length>=existing.length && entry.value.isNotEmpty)episodes[entry.key]=entry.value;
        }
        // Show Season 1 (or the first available season) immediately.
        // Its episode buttons stay hidden until the website is synchronized.
        selected=selected??(ordered.isEmpty?null:ordered.first);
        loading=false;
        // A single early episode link may be the only DOM node rendered yet.
        // Keep polling until additional episodes arrive or polling times out.
        final waitingForEpisodes=expectedSeason!=null &&
          (episodes[expectedSeason]?.length??0)<=1;
        if(!waitingForEpisodes){changingSeason=false;_pendingSeason=null;}
        error=null;
      });
      // Only on the first page read, switch the website's real dropdown to
      // season one. This must run after the current site's season is captured.
      if(!_initialSeasonSynced && expectedSeason==null && ordered.isNotEmpty){
        _initialSeasonSynced=true;
        if(actualSeason>0 && actualSeason!=ordered.first){
          // Schedule through the normal selection path; do not reuse last
          // season's links as if they belonged to season one.
          await _changeSeason(ordered.first, force:true);
        }
      }
    }catch(_){if(mounted && version==_scanVersion)setState((){loading=false;changingSeason=false;error='Pilihan episode belum dapat dibaca.';});}
  }
  Future<void> _changeSeason(int season, {bool force=false}) async {
    if(selected==season && !force && !changingSeason)return;
    // Do not use cached episodes as a substitute for changing the source
    // dropdown. The website must follow the season selected in Flutter.
    if(changingSeason) _scanVersion++;
    ++_scanVersion;
    _pendingSeason=season;
    setState((){selected=season;changingSeason=true;error=null;});
    try {
      final js=r'''(() => {
        const n=SEASON;
        for(const s of document.querySelectorAll('select')){
          const option=[...s.options].find(o =>
            new RegExp('(?:season|musim)\\s*'+n+'(?!\\d)','i')
              .test((o.textContent||'')+' '+o.value));
          if(!option)continue;
          s.value=option.value;
          s.dispatchEvent(new Event('input',{bubbles:true}));
          s.dispatchEvent(new Event('change',{bubbles:true}));
          return true;
        }
        return false;
      })()'''.replaceAll('SEASON','$season');
      final applied=await controller.runJavaScriptReturningResult(js);
      if(applied==false || applied.toString()=='false')throw StateError('Season selector missing');
      // The site's dropdown can update episodes asynchronously. Re-read the
      // page after it settles rather than assuming a fixed 900ms is enough.
      for(var attempt=0;attempt<9;attempt++){
        await Future<void>.delayed(const Duration(milliseconds:450));
        if(!mounted || _pendingSeason!=season)return;
        await _scan(expectedSeason:season);
        if(!changingSeason)return;
      }
      if(mounted && _pendingSeason==season){
        setState((){
          changingSeason=false;
          _pendingSeason=null;
          error=(episodes[season]?.length??0)==0
            ? 'Daftar episode season ini belum dapat dibaca dari situs.'
            : null;
        });
      }
    }catch(_){
      if(mounted && _pendingSeason==season){
        setState((){
          changingSeason=false;
          _pendingSeason=null;
          error='Gagal mengganti season dari situs.';
        });
      }
    }
  }
  @override Widget build(BuildContext context){
    final active=selected,visible=changingSeason ? const <({int episode,Uri uri})>[] : (episodes[active]??const <({int episode,Uri uri})>[]);
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      // Keep the source document mounted to read its real selectors, but do
      // not display its player until an episode is picked.
      SizedBox(height:showSourcePage?420:1,width:double.infinity,child:Opacity(opacity:showSourcePage?1:0.01,child:WebViewWidget(controller:controller))),
      const Text('Pilih Season',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      if(loading && seasons.isEmpty)const LinearProgressIndicator(),
      if(error!=null)Text(error!,style:const TextStyle(color:Colors.orangeAccent)),
      if(seasons.isNotEmpty)SizedBox(height:58,child:ListView.separated(
        scrollDirection:Axis.horizontal,itemCount:seasons.length,
        separatorBuilder:(_,__)=>const SizedBox(width:8),
        itemBuilder:(context,i)=>ChoiceChip(label:Text('Season ${seasons[i]}'),
          selected:selected==seasons[i],onSelected:(_)=>_changeSeason(seasons[i])))),
      if(active!=null)...[
        const SizedBox(height:12),
        Text('Episode • Season $active',style:const TextStyle(fontSize:17,fontWeight:FontWeight.bold)),
        if(changingSeason)const Padding(padding:EdgeInsets.symmetric(vertical:12),
          child:Text('Memperbarui daftar episode…',style:TextStyle(color:Colors.white70)))
        else if(visible.isEmpty)const Padding(padding:EdgeInsets.symmetric(vertical:12),
          child:Text('Episode belum ditemukan di halaman sumber.')),
        Wrap(spacing:8,runSpacing:8,children:visible.map((e)=>OutlinedButton(
          onPressed:()=>widget.onEpisodeSelected(active,e.episode,e.uri),
          child:Text('Episode ${e.episode}'))).toList()),
      ],
      if(seasons.isEmpty && !loading)...[
        const Padding(padding:EdgeInsets.symmetric(vertical:8),child:Text('Daftar season belum dapat dibaca otomatis dari halaman sumber.',style:TextStyle(color:Colors.white70))),
        TextButton.icon(onPressed:(){setState(()=>loading=true);controller.reload();},icon:const Icon(Icons.refresh),label:const Text('Coba baca ulang episode')),
        TextButton.icon(onPressed:()=>setState(()=>showSourcePage=!showSourcePage),icon:const Icon(Icons.language),label:Text(showSourcePage?'Sembunyikan halaman sumber':'Tampilkan halaman sumber di aplikasi')),
      ],
    ]);
  }
}
