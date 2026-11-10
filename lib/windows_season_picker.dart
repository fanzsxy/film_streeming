import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'filmstream_icons.dart';
import 'windows_episode_selector.dart';

/// Windows-only episode list: reads actual source links through WebView2.
class WindowsSeasonPicker extends StatefulWidget {
  final Uri source;
  final String title;
  final String year;
  final void Function(int season, int episode, Uri url) onEpisodeSelected;
  final ValueChanged<String>? onSynopsisFound;
  const WindowsSeasonPicker({
    super.key, required this.source, required this.title,
    required this.year, required this.onEpisodeSelected, this.onSynopsisFound,
  });
  @override
  State<WindowsSeasonPicker> createState() => _WindowsSeasonPickerState();
}

class _WindowsSeasonPickerState extends State<WindowsSeasonPicker> {
  final WebviewController _web = WebviewController();
  Timer? _poll;
  bool _ready = false, _busy = false, _showPage = false, _searched = false;
  bool _changingSeason = false, _initialSeasonSynced = false;
  bool _initialSearchFinished = false;
  bool _episodeSearchFinished = false;
  Timer? _initialTimeout;
  Timer? _episodeTimeout;
  int? _pendingSeason;
  final Set<String> _openedEpisodes = <String>{};
  String get _viewedKey => 'opened_source_episodes_v1:${Uri.encodeComponent(widget.title.trim().toLowerCase())}:${widget.year}';
  String? _error;
  int? _selected;
  final Map<int, Map<int, Uri>> _episodes = {};
  final Set<int> _seasons = {};

  static const _scanScript = r'''
    (() => {
      const selects=[...document.querySelectorAll('select')];
      const seasons=[];
      selects.forEach((s,i)=>[...s.options].forEach(o=>{
        const m=((o.textContent||'')+' '+o.value).match(/(?:season|musim)\s*(\d+)/i);
        if(m)seasons.push({number:Number(m[1]),index:i,value:o.value});
      }));
      const seasonSelect=selects.find(s=>[...s.options].some(
        o=>/(?:season|musim)\s*\d+/i.test(o.textContent||'')));
      const panel=seasonSelect?.closest('section,.row,.box,.content,.entry-content');
      const current=(seasonSelect?.selectedOptions?.[0]?.textContent||'')
        .match(/(?:season|musim)\s*(\d+)/i);
      const active=Number(current?.[1]||
        (location.pathname.match(/(?:season|musim)[-_ ]*(\d+)/i)||[])[1]||
        seasons.find(x=>x.value===seasonSelect?.value)?.number||0);
      const episodes=[];
      document.querySelectorAll('a[href],a[data-url],a[data-href]').forEach(a=>{
        const raw=a.getAttribute('href')||a.dataset.url||a.dataset.href;
        if(!raw||raw==='#'||raw.startsWith('javascript:'))return;
        let u;try{u=new URL(raw,location.href);}catch(_){return;}
        if(u.protocol!=='https:'||u.host!==location.host)return;
        const explicit=u.pathname.match(/(?:season|musim)[-_ ]*(\d+).*?(?:episode|eps?|ep)[-_ ]*0*(\d+)/i);
        const numbered=(a.textContent||'').trim().match(/^(?:episode|eps?|ep)?\s*0*(\d+)$/i);
        const group=a.closest('.episode,.episodes,.episode-list,.episode-grid,.ep-list,.series-episode,.server-episode,.episode-items,.episodelist,.episode-container,[class*="episode"],[id*="episode"]');
        const season=explicit?Number(explicit[1]):active;
        const episode=explicit?Number(explicit[2]):numbered&&(group||panel?.contains(a))?Number(numbered[1]):0;
        if(season>0&&episode>0&&episode<1000&&(explicit||group||panel?.contains(a)))
          episodes.push({season,episode,url:u.href});
      });
      const description=document.querySelector(
        '[itemprop="description"],.sinopsis,.synopsis,.entry-content .desc,.film-synopsis,.summary,.description');
      const synopsis=(description?.textContent||'').trim().replace(/\s+/g,' ');
      return JSON.stringify({seasons,episodes,active,synopsis});
    })();
  ''';

  @override
  void initState() { super.initState(); _initialize(); }

  Future<void> _initialize() async {
    try {
      try {
        final prefs = await SharedPreferences.getInstance();
        _openedEpisodes.addAll(prefs.getStringList(_viewedKey) ?? const <String>[]);
      } catch (_) {/* History is optional. */}
      await _web.initialize();
      await _web.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _web.loadUrl(widget.source.toString());
      if(!mounted)return;
      setState(()=>_ready=true);
      await _scan();
      _poll=Timer.periodic(const Duration(seconds:3),(_)=>_scan());
      _initialTimeout=Timer(const Duration(seconds:24),(){
        if(mounted && _seasons.isEmpty) setState(()=>_initialSearchFinished=true);
      });
    } catch (_) {
      if(mounted)setState((){_error='Gagal membuka halaman sumber series.';_initialSearchFinished=true;});
    }
  }

  Future<void> _scan({int? expectedSeason}) async {
    if(!_ready||_busy||!mounted||(_changingSeason && expectedSeason==null))return;
    _busy=true;
    try {
      if(!_searched && widget.source.path.startsWith('/search')) {
        final js=r'''(() => {
          const norm=s=>(s||'').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim();
          const matches=[...document.querySelectorAll('a[href]')].filter(a=>{
            const item=a.closest('article,.item,.result,.movie,.film,.poster');
            return norm(a.textContent||a.getAttribute('title'))===norm(TITLE) &&
              (item?.textContent||a.textContent||'').includes(YEAR);
          });
          if(matches.length!==1)return '';
          const u=new URL(matches[0].href,location.href);
          return u.protocol==='https:'&&u.host===location.host?u.href:'';
        })()'''.replaceAll('TITLE',jsonEncode(widget.title))
               .replaceAll('YEAR',jsonEncode(widget.year));
        final target=await _web.executeScript(js);
        final uri=Uri.tryParse(target?.toString()??'');
        if(uri!=null&&uri.scheme=='https'&&uri.host==widget.source.host) {
          _searched=true;
          await _web.loadUrl(uri.toString());
          return;
        }
      }
      await _web.executeScript(r'''(() => {
        if(window.__fsPickerExpanded)return;
        const text=el=>(el?.textContent||'').trim().toLowerCase();
        const el=[...document.querySelectorAll('button,a,[role="button"],span')]
          .find(node=>{
            if(!/^(lihat selengkapnya|baca selengkapnya|selengkapnya|read more|show more)$/i.test(text(node)))return false;
            if(node.tagName==='A'){
              const href=(node.getAttribute('href')||'').trim();
              if(href && href!=='#' && !href.startsWith('javascript:'))return false;
            }
            return true;
          });
        if(el){window.__fsPickerExpanded=true;el.click();}
      })()''');
      dynamic data=await _web.executeScript(_scanScript);
      for(var i=0;i<2&&data is String;i++) data=jsonDecode(data);
      if(data is! Map||!mounted)return;
      final synopsis=(data['synopsis']??'').toString().trim();
      if(synopsis.isNotEmpty) widget.onSynopsisFound?.call(synopsis);
      final seasons=<int>{};
      final found=<int,Map<int,Uri>>{};
      for(final entry in (data['seasons'] as List? ?? const [])) {
        if(entry is Map && entry['number'] is num) {
          final n=(entry['number'] as num).toInt();
          if(n>0)seasons.add(n);
        }
      }
      for(final entry in (data['episodes'] as List? ?? const [])) {
        if(entry is! Map)continue;
        final season=(entry['season'] as num?)?.toInt()??0;
        final episode=(entry['episode'] as num?)?.toInt()??0;
        final uri=Uri.tryParse((entry['url']??'').toString());
        if(season<1||episode<1||uri==null||uri.scheme!='https'||
           uri.host!=widget.source.host)continue;
        seasons.add(season);
        found.putIfAbsent(season,()=>{})[episode]=uri;
      }
      final active=(data['active'] as num?)?.toInt()??0;
      if(active>0)seasons.add(active);
      if(expectedSeason!=null && active!=expectedSeason) return;
      if(seasons.isNotEmpty)setState(() {
        if(!_initialSearchFinished && _episodeTimeout==null){
          _episodeTimeout=Timer(const Duration(seconds:18),(){
            if(mounted)setState(()=>_episodeSearchFinished=true);
          });
        }
        _initialSearchFinished=true;
        _initialTimeout?.cancel();
        if(found.values.any((list)=>list.isNotEmpty)){
          _episodeSearchFinished=true;
          _episodeTimeout?.cancel();
        }
        _seasons.addAll(seasons);
        for(final entry in found.entries) {
          if(entry.value.length >= (_episodes[entry.key]?.length??0))
            _episodes[entry.key]=entry.value;
        }
        _selected ??= (_seasons.toList()..sort()).first;
        if (expectedSeason != null &&
            (_episodes[expectedSeason]?.isNotEmpty ?? false)) {
          _changingSeason=false;
          _pendingSeason=null;
        }
        _error=null;
      });
      if (!_initialSeasonSynced && expectedSeason == null &&
          _seasons.isNotEmpty) {
        _initialSeasonSynced = true;
        final first = (_seasons.toList()..sort()).first;
        if (active > 0 && active != first) {
          // Android starts on the first season rather than the site's last.
          _selectSeason(first, force:true);
        }
      }
    }catch(_){ /* Source can still be loading. */ }
    finally{_busy=false;}
  }

  Future<void> _selectSeason(int n, {bool force = false}) async {
    if (_changingSeason && !force) return;
    if (!force && _episodes[n]?.isNotEmpty == true) {
      setState(() => _selected=n);
      return;
    }
    setState(() {
      _selected=n;
      _changingSeason=true;
      _pendingSeason=n;
      _error=null;
    });
    try {
      final script=r'''(() => {
        const n=NUMBER;
        for(const s of document.querySelectorAll('select')) {
          const o=[...s.options].find(o=>
            new RegExp('(?:season|musim)\\s*'+n+'(?!\\d)','i').test(
              (o.textContent||'')+' '+o.value));
          if(!o)continue;
          s.value=o.value;
          s.dispatchEvent(new Event('input',{bubbles:true}));
          s.dispatchEvent(new Event('change',{bubbles:true}));
          return true;
        }
        return false;
      })()'''.replaceAll('NUMBER',n.toString());
      final result=await _web.executeScript(script);
      if (result != true && result.toString() != 'true') {
        throw StateError('Season selector unavailable');
      }
      for (var attempt=0;attempt<9;attempt++) {
        await Future<void>.delayed(const Duration(milliseconds:450));
        if (!mounted || _pendingSeason!=n) return;
        await _scan(expectedSeason:n);
        if (!_changingSeason) return;
      }
      if (mounted && _pendingSeason==n) {
        setState(() {
          _changingSeason=false;
          _pendingSeason=null;
          _error=(_episodes[n]?.isNotEmpty??false)
              ? 'Sebagian episode ditemukan; periksa halaman sumber jika kurang.'
              : 'Daftar episode season ini belum ditemukan dari sumber.';
        });
      }
    } catch (_) {
      if (mounted && _pendingSeason==n) {
        setState(() {
          _changingSeason=false;
          _pendingSeason=null;
          _error='Tidak dapat mengganti season dari sumber.';
        });
      }
    }
  }

  Future<void> _openEpisode(int season, int episode, Uri uri) async {
    final key='$season:$episode';
    setState(() => _openedEpisodes.add(key));
    widget.onEpisodeSelected(season,episode,uri);
    try {
      final prefs=await SharedPreferences.getInstance();
      await prefs.setStringList(_viewedKey, _openedEpisodes.toList()..sort());
    } catch (_) {/* Playback must work without local storage. */}
  }

  @override
  void dispose() { _initialTimeout?.cancel(); _episodeTimeout?.cancel(); _poll?.cancel(); _web.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final seasons=_seasons.toList()..sort();
    final links=_episodes[_selected]??<int,Uri>{};
    final numbers=_changingSeason ? <int>[] : (links.keys.toList()..sort());
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      // Keep the WebView2 reader mounted; it is never used as a video player.
      SizedBox(height:_showPage?300:2, width:double.infinity,
        child:_ready?Webview(_web):const SizedBox.shrink()),
      const SizedBox(height:12),
      WindowsEpisodeSelector(
        seasons: seasons,
        selectedSeason: _selected,
        episodes: numbers,
        openedEpisodes: _openedEpisodes,
        loadingSeasons: !_ready || (!_initialSearchFinished && seasons.isEmpty),
        loadingEpisodes: numbers.isEmpty &&
            !_changingSeason && !_episodeSearchFinished,
        changingSeason: _changingSeason,
        error: _error,
        onSeasonSelected: (season) => _selectSeason(season),
        onEpisodeSelected: (episode) {
          final season = _selected;
          final url = links[episode];
          if (season != null && url != null && !_changingSeason) {
            _openEpisode(season, episode, url);
          }
        },
      ),
      if(seasons.isEmpty && _ready && _initialSearchFinished)...[
        const SizedBox(height:8),
        TextButton.icon(
          onPressed:()=>_scan(),
          icon:const Icon(FilmStreamIcons.reload),
          label:const Text('Coba baca ulang episode'),
        ),
        TextButton.icon(
          onPressed:()=>setState(()=>_showPage=!_showPage),
          icon:const Icon(FilmStreamIcons.sourcePage),
          label:Text(_showPage?'Sembunyikan halaman sumber':'Lihat halaman sumber'),
        ),
      ],
    ]);
  }
}
