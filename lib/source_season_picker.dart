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
  bool triedSearch=false;
  String? error;
  @override void initState(){
    super.initState();
    controller=WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished:(_)=>_scan(),
        onWebResourceError:(e){
          if(e.isForMainFrame==true && mounted)setState((){loading=false;error='Halaman sumber gagal dibuka.';});
        },
      ))
      ..loadRequest(widget.source);
  }
  Future<void> _scan() async {
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
        if(target!=null && target.scheme=='https' && target.host==widget.source.host){
          await controller.loadRequest(target);
          return;
        }
      }
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
        const active=Number(current?.[1]||fallback?.[1]||0);
        const episodes=[];
        document.querySelectorAll('a[href]').forEach(a=>{
          const parent=a.closest('.episode,.episodes,.episode-list,.episode-grid,.ep-list,.series-episode,.server-episode');
          let uri;try{uri=new URL(a.getAttribute('href'),location.href);}catch(_){return;}
          if(uri.protocol!=='https:' || uri.host!==location.host)return;
          const explicit=uri.pathname.match(/(?:season|musim)[-_ ]*(\d+).*?(?:episode|eps?|ep)[-_ ]*0*(\d+)/i);
          const numberText=(a.textContent||'').trim().match(/^(?:episode|eps?|ep)?\s*0*(\d+)$/i);
          const sn=explicit?Number(explicit[1]):active;
          const ep=explicit?Number(explicit[2]):parent&&numberText?Number(numberText[1]):0;
          if(sn>0&&ep>0&&ep<1000&&(explicit||parent))episodes.push({season:sn,episode:ep,url:uri.href});
        });
        return JSON.stringify({opts,episodes});
      })()''');
      dynamic decoded=result;
      if(decoded is String){try{decoded=jsonDecode(decoded);}catch(_){}}
      if(decoded is String){try{decoded=jsonDecode(decoded);}catch(_){}}
      if(decoded is! Map || !mounted)return;
      final found=<int,List<({int episode,Uri uri})>>{};
      final seasonNums=<int>{};
      for(final raw in (decoded['opts'] as List? ?? const [])){
        if(raw is Map && raw['number'] is num)seasonNums.add((raw['number'] as num).toInt());
      }
      for(final raw in (decoded['episodes'] as List? ?? const [])){
        if(raw is! Map)continue;
        final sn=(raw['season'] as num?)?.toInt()??0,ep=(raw['episode'] as num?)?.toInt()??0;
        final uri=Uri.tryParse((raw['url']??'').toString());
        if(sn<1||ep<1||uri==null||uri.scheme!='https' || uri.host!=widget.source.host)continue;
        seasonNums.add(sn);
        final list=found.putIfAbsent(sn,()=>[]);
        if(!list.any((e)=>e.episode==ep))list.add((episode:ep,uri:uri));
      }
      for(final list in found.values)list.sort((a,b)=>a.episode.compareTo(b.episode));
      final ordered=seasonNums.toList()..sort();
      setState((){
        seasons=ordered;episodes.addAll(found);selected=ordered.contains(selected)?selected:(ordered.isEmpty?null:ordered.first);
        loading=false;error=null;
      });
    }catch(_){if(mounted)setState((){loading=false;error='Pilihan episode belum dapat dibaca.';});}
  }
  Future<void> _changeSeason(int season) async {
    setState((){selected=season;loading=true;});
    try {
      final js=r'''(() => {
        const n=SEASON;
        for(const s of document.querySelectorAll('select')){
          const option=[...s.options].find(o=>new RegExp('(?:season|musim)\s*'+n+'(?!\d)','i').test((o.textContent||'')+' '+o.value));
          if(option){s.value=option.value;s.dispatchEvent(new Event('change',{bubbles:true}));return true;}
        }
        return false;
      })()'''.replaceAll('SEASON','$season');
      await controller.runJavaScript(js);
      await Future<void>.delayed(const Duration(milliseconds:450));
      await _scan();
    }catch(_){if(mounted)setState(()=>loading=false);}
  }
  @override Widget build(BuildContext context){
    final active=selected,visible=episodes[active]??const <({int episode,Uri uri})>[];
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      // Keep the source document mounted to read its real selectors, but do
      // not display its player until an episode is picked.
      SizedBox(height:1,width:1,child:Opacity(opacity:0.01,child:WebViewWidget(controller:controller))),
      const Text('Pilih Season',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      if(loading)const LinearProgressIndicator(),
      if(error!=null)Text(error!,style:const TextStyle(color:Colors.orangeAccent)),
      if(seasons.isNotEmpty)SizedBox(height:58,child:ListView.separated(
        scrollDirection:Axis.horizontal,itemCount:seasons.length,
        separatorBuilder:(_,__)=>const SizedBox(width:8),
        itemBuilder:(context,i)=>ChoiceChip(label:Text('Season ${seasons[i]}'),
          selected:selected==seasons[i],onSelected:(_)=>_changeSeason(seasons[i]))),
      if(active!=null)...[
        const SizedBox(height:12),
        Text('Episode • Season $active',style:const TextStyle(fontSize:17,fontWeight:FontWeight.bold)),
        if(visible.isEmpty)const Padding(padding:EdgeInsets.symmetric(vertical:12),
          child:Text('Episode belum ditemukan di halaman sumber.')),
        Wrap(spacing:8,runSpacing:8,children:visible.map((e)=>OutlinedButton(
          onPressed:()=>widget.onEpisodeSelected(active,e.episode,e.uri),
          child:Text('Episode ${e.episode}'))).toList()),
      ],
      if(seasons.isEmpty && !loading)TextButton.icon(
        onPressed:(){setState(()=>loading=true);controller.reload();},
        icon:const Icon(Icons.refresh),label:const Text('Coba baca ulang episode')),
    ]);
  }
}
