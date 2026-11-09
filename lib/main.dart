import 'filmstream_catalog.dart';
import 'catalog_query.dart';
import 'search_suggestions.dart';
import 'startup_catalog_check.dart';
import 'catalog_sync_diagnostics.dart';
import 'filmstream_icons.dart';
import 'windows_source_player.dart';
import 'source_domain_config.dart';
import 'source_manager.dart';
import 'source_season_picker.dart';
import 'windows_season_picker.dart';
import 'web_source_page.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PointerDeviceKind;
import 'dart:convert';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tmdbToken = String.fromEnvironment('TMDB_TOKEN');
const imageRoot = 'https://image.tmdb.org/t/p/w500';
String filmstreamImageUrl(String path) => path.startsWith('https://') ? path : '$imageRoot$path';
String filmstreamHeroImageUrl(String path) {
  if (path.isEmpty) return '';
  // Backdrops are wide images. 500px sources blur when stretched to desktop.
  if (path.startsWith('/')) return 'https://image.tmdb.org/t/p/w1280$path';
  if (path.startsWith('https://image.tmdb.org/t/p/')) {
    return path.replaceFirst(RegExp(r'/t/p/[^/]+/'), '/t/p/w1280/');
  }
  return path; // Do not modify source-hosted image URLs.
}
// Enable dragging the Home banner/genre rails with a desktop mouse.
class FilmstreamDesktopDragBehavior extends MaterialScrollBehavior {
  const FilmstreamDesktopDragBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
  };
}
SliverGridDelegate filmstreamGridDelegate(BuildContext context) =>
    Platform.isWindows
        ? const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 230,
            childAspectRatio: .59,
            mainAxisSpacing: 14,
            crossAxisSpacing: 12)
        : const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: .58,
            mainAxisSpacing: 14,
            crossAxisSpacing: 12);

void main() {WidgetsFlutterBinding.ensureInitialized();PaintingBinding.instance.imageCache.maximumSize = 160; PaintingBinding.instance.imageCache.maximumSizeBytes = 80 << 20;runApp(const FilmStream());}
class StartupGate extends StatefulWidget {const StartupGate({super.key});@override State<StartupGate> createState()=>_StartupGateState();}
class _StartupGateState extends State<StartupGate> {
 late Future<void> loading;
 @override void initState(){super.initState();loading=WatchStore.init().timeout(const Duration(seconds:10));}
 void retry(){setState((){loading=WatchStore.init().timeout(const Duration(seconds:10));});}
 @override Widget build(BuildContext context)=>FutureBuilder<void>(future:loading,builder:(context,s){
  if(s.connectionState!=ConnectionState.done)return const Scaffold(body:Center(child:Column(mainAxisSize:MainAxisSize.min,children:[CircularProgressIndicator(),SizedBox(height:18),Text('Menyiapkan riwayat tontonan...')])));
  if(s.hasError)return Scaffold(body:Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.error_outline,size:46),const SizedBox(height:12),const Text('Gagal memuat riwayat lokal',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:8),Text('${s.error}',textAlign:TextAlign.center),const SizedBox(height:16),FilledButton(onPressed:retry,child:const Text('Coba lagi')),TextButton(onPressed:()=>Navigator.of(context).pushReplacement(MaterialPageRoute(builder:(_)=>const HomePage())),child:const Text('Buka katalog tanpa riwayat'))]))));
  return const HomePage();
 });
}
class FilmStream extends StatelessWidget {
  const FilmStream({super.key});
  @override Widget build(BuildContext context) => MaterialApp(title:'FilmStream Personal',debugShowCheckedModeBanner:false,
    theme:ThemeData.dark(useMaterial3:true).copyWith(scaffoldBackgroundColor:const Color(0xff101218),cardColor:const Color(0xff20252e),appBarTheme:const AppBarTheme(backgroundColor:Color(0xff101218),surfaceTintColor:Colors.transparent),colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xffe5aa55),brightness:Brightness.dark),navigationBarTheme:NavigationBarThemeData(backgroundColor:const Color(0xff191c23),indicatorColor:const Color(0xff62492e),height:76)),home:const StartupGate());
}
class Movie {
 final int id; final String title,overview,poster,backdrop,release,type,sourceUrl,originalLanguage; final double rating,popularity; final List<int> genres; final List<String> genreNames;
 Movie.fromJson(Map<String,dynamic> j,{String fallback='movie'}):sourceUrl=(j['source_url']??'').toString(),originalLanguage=(j['original_language']??'').toString(),popularity=((j['popularity']??0) as num).toDouble(),id=(j['id'] as num?)?.toInt() ?? 0,title=(j['title']??j['name']??'Tanpa judul').toString(),overview=(j['overview']??'').toString(),poster=(j['poster_path']??'').toString(),backdrop=(j['backdrop_path']??'').toString(),release=(j['release_date']??j['first_air_date']??'').toString(),rating=((j['vote_average']??0) as num).toDouble(),type=(j['media_type']=='tv'||j['media_type']=='movie')?j['media_type'] as String:fallback,genres=(j['genre_ids'] as List? ?? []).whereType<num>().map((e)=>e.toInt()).toList(),genreNames=(j['genre_names'] as List? ?? []).whereType<String>().toList(growable:false);
 String get year => release.length>=4?release.substring(0,4):'—';
}

// Riwayat tersimpan secara lokal, dikunci oleh jenis dan TMDB ID + episode.
class WatchEntry {
 final String key,title,poster,type,url,subtitle; final int tmdbId,season,episode,positionMs,durationMs,updatedAt; final bool completed;
 const WatchEntry({required this.key,required this.title,required this.poster,required this.type,required this.url,required this.subtitle,required this.tmdbId,required this.season,required this.episode,required this.positionMs,required this.durationMs,required this.updatedAt,required this.completed});
 factory WatchEntry.fromJson(Map<String,dynamic> j)=>WatchEntry(key:j['key'] as String,title:j['title'] as String,poster:j['poster'] as String? ?? '',type:j['type'] as String? ?? 'movie',url:j['url'] as String,subtitle:j['subtitle'] as String? ?? '',tmdbId:j['tmdbId'] as int? ?? 0,season:j['season'] as int? ?? 0,episode:j['episode'] as int? ?? 0,positionMs:j['positionMs'] as int? ?? 0,durationMs:j['durationMs'] as int? ?? 0,updatedAt:j['updatedAt'] as int? ?? 0,completed:j['completed'] as bool? ?? false);
 Map<String,dynamic> toJson()=>{'key':key,'title':title,'poster':poster,'type':type,'url':url,'subtitle':subtitle,'tmdbId':tmdbId,'season':season,'episode':episode,'positionMs':positionMs,'durationMs':durationMs,'updatedAt':updatedAt,'completed':completed};
 double get progress=>durationMs<=0?0:(positionMs/durationMs).clamp(0.0,1.0).toDouble();
 String get label=>type=='tv'?'$title • S${season.toString().padLeft(2,'0')}E${episode.toString().padLeft(2,'0')}':title;
}
class WatchStore {
 static final ValueNotifier<List<WatchEntry>> entries=ValueNotifier([]);
 static SharedPreferences? _prefs;
 static Future<void> init() async { _prefs=await SharedPreferences.getInstance();try {final raw=_prefs!.getString('watch_history_v1');if(raw!=null){entries.value=(jsonDecode(raw) as List).map((e)=>WatchEntry.fromJson(Map<String,dynamic>.from(e as Map))).toList()..sort((a,b)=>b.updatedAt.compareTo(a.updatedAt));}}catch(_){entries.value=[];} }
 static WatchEntry? find(String key){for(final e in entries.value){if(e.key==key)return e;}return null;}
 static Future<void> save(WatchEntry entry) async {final list=[entry,...entries.value.where((e)=>e.key!=entry.key)]..sort((a,b)=>b.updatedAt.compareTo(a.updatedAt));entries.value=list;await _prefs?.setString('watch_history_v1',jsonEncode(list.map((e)=>e.toJson()).toList()));}
 static Future<void> remove(String key) async {entries.value=entries.value.where((e)=>e.key!=key).toList();await _prefs?.setString('watch_history_v1',jsonEncode(entries.value.map((e)=>e.toJson()).toList()));}
}
String clock(int ms){final d=Duration(milliseconds:ms);final h=d.inHours;final m=d.inMinutes.remainder(60).toString().padLeft(2,'0');final sec=d.inSeconds.remainder(60).toString().padLeft(2,'0');return h>0?'$h:$m:$sec':'${d.inMinutes}:$sec';}
// Riwayat selalu kembali ke halaman detail Flutter, bukan WebView layar penuh.
Future<void> openWatchDetail(BuildContext context, WatchEntry e) async {
  if (e.tmdbId <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Data katalog untuk riwayat ini tidak tersedia.')));
    return;
  }
  try {
    final data = await Tmdb.get('${e.type == 'tv' ? 'tv' : 'movie'}/${e.tmdbId}');
    if (!context.mounted) return;
    final movie = Movie.fromJson({...data, 'id': e.tmdbId},fallback:e.type);
    Navigator.push(context,MaterialPageRoute(builder:(_)=>DetailPage(
      movie:movie,isFavorite:false,onFavorite:(){},
      initialSeason:e.type=='tv'&&e.season>0?e.season:null,
      initialEpisode:e.type=='tv'&&e.episode>0?e.episode:null,
      initialPage:e.subtitle=='__webview__' ? Uri.tryParse(e.url) : null,
    )));
  } catch (_) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Gagal memuat rincian dari TMDB. Periksa koneksi internet.')));
  }
}
class HistoryPage extends StatelessWidget {const HistoryPage({super.key});
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Riwayat Tontonan')),body:ValueListenableBuilder<List<WatchEntry>>(valueListenable:WatchStore.entries,builder:(context,items,_)=>items.isEmpty?const Center(child:Text('Belum ada riwayat. Putar video di FilmStream untuk mulai menyimpan progres.',textAlign:TextAlign.center)):ListView.builder(itemCount:items.length,itemBuilder:(context,i){final e=items[i];return ListTile(leading:e.poster.isEmpty?const SizedBox(width:50,child:Icon(Icons.movie)):Image.network(filmstreamImageUrl(e.poster),width:50,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.movie)),title:Text(e.label,maxLines:2),subtitle:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(e.completed?'Pernah menekan player':e.subtitle=='__webview__'?(e.durationMs>0?'Terakhir ${clock(e.positionMs)} / ${clock(e.durationMs)}':'Episode/film pernah dibuka'):'Terakhir ${clock(e.positionMs)} / ${clock(e.durationMs)}'),LinearProgressIndicator(value:e.progress),const SizedBox(height:4),Text(e.completed?'Putar ulang':e.subtitle=='__webview__'?(e.durationMs>0?'Buka kembali (progres tercatat)':'Buka kembali player'):'Lanjutkan menonton',style:const TextStyle(fontSize:12))]),onTap:()=>openWatchDetail(context,e),trailing:IconButton(tooltip:'Hapus riwayat',icon:const Icon(Icons.delete_outline),onPressed:()=>WatchStore.remove(e.key)));})));
}
class LocalCatalogMetadata {
  static final Map<String, Future<Movie?>> _results = {};
  static final Map<String, String> _sourceByTmdb = {};
  static String _key(String type, int id) => '$type:$id';
  static Uri? sourceFor(Movie movie) {
    final raw = movie.sourceUrl.isNotEmpty ? movie.sourceUrl : _sourceByTmdb[_key(movie.type, movie.id)];
    final uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https') return null;
    if (movie.type == 'tv' && uri.host != 'tv9.nontondrama.my' && uri.host != 'tv.nontondrama.vip' && uri.host != 'tv.lk21online.de') return null;
    if (movie.type == 'movie' && uri.host != 'tv12.lk21official.cc') return null;
    return uri;
  }
  static int _stableId(String source) {var hash = 0;for(final unit in source.codeUnits){hash=(hash*31+unit)&0x7fffffff;}return hash==0?1:hash;}
  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\([^)]*\)'), ' ').replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  static double _similarity(String a,String b){
    final x=_norm(a),y=_norm(b);
    if(x.isEmpty||y.isEmpty)return 0;
    if(x==y)return 1;
    final xs=x.split(' ').toSet(),ys=y.split(' ').toSet();
    return 2*xs.intersection(ys).length/(xs.length+ys.length);
  }
  static bool _matches(CatalogEntry e,Map<String,dynamic> d){
    final date=(d['release_date']??d['first_air_date']??'').toString();
    final year=date.length>=4?int.tryParse(date.substring(0,4)):null;
    // Catalog contains a release year, not a verified month/day. Never
    // invent a precise date or accept a different year for artwork matching.
    if(year==null||year!=e.year)return false;
    return _similarity(e.title,(d['title']??d['name']??'').toString())>=.86 ||
      _similarity(e.title,(d['original_title']??d['original_name']??'').toString())>=.86;
  }
  static Movie _withCollectedMetadata(CatalogEntry entry, Map<String,dynamic> base) {
    final data=Map<String,dynamic>.from(base);
    data['poster_path']=preferredCatalogPoster(
      entry,tmdbPoster:(data['poster_path']??'').toString());
    // Genres collected from LK21 are usable even without TMDB genre IDs.
    data['genre_ids']=entry.genreIds;
    data['genre_names']=entry.genres;
    if(entry.originalLanguage.isNotEmpty) {
      data['original_language']=entry.originalLanguage;
    }
    if((data['backdrop_path']??'').toString().isEmpty) {
      // When a real TMDB backdrop is unavailable, use the same
      // TMDB-first poster as the card instead of unrelated source artwork.
      data['backdrop_path']=data['poster_path'];
    }
    if(entry.synopsis.isNotEmpty && (data['overview']??'').toString().isEmpty) {
      data['overview']=entry.synopsis;
    }
    if(data['vote_average'] is! num && entry.rating!=null) {
      data['vote_average']=entry.rating;
    }
    // Prefer a real TMDB poster from metadata; fall back to catalog artwork.
    data['title']=entry.title;
    data['name']=entry.title;
    data['release_date']='${entry.year}-01-01';
    data['first_air_date']='${entry.year}-01-01';
    data['media_type']=entry.type;
    final active = Uri.tryParse(entry.activeSourceUrl);
    final original = Uri.tryParse(entry.url);
    data['source_url'] = entry.type == 'tv' && active?.scheme == 'https' &&
        active?.host == 'tv.nontondrama.vip' && active?.path == original?.path
        ? entry.activeSourceUrl : entry.url;
    return Movie.fromJson(data,fallback:entry.type);
  }
  // Keep the catalog index for currently rendered tiles only.
  // Every screen uses this same verified TMDB poster fallback path.
  static final Map<String,CatalogEntry> _pagePosterEntries={};
  static final Map<String,Future<Movie?>> _posterUpgrades={};
  static int _activePosterRequests=0;
  static final List<Completer<void>> _posterQueue=[];

  static Future<Movie?> catalogPosterUpgrade(Movie movie) {
    // Already a TMDB image from the catalog or TMDB's ranked response.
    if (movie.poster.startsWith('/') ||
        movie.poster.startsWith('https://image.tmdb.org/')) {
      return Future<Movie?>.value(movie);
    }
    final entry=_pagePosterEntries[movie.sourceUrl];
    if(entry==null || entry.tmdbId==null) return Future<Movie?>.value(movie);
    if(_posterUpgrades.length>240 && !_posterUpgrades.containsKey(entry.url)){
      _posterUpgrades.remove(_posterUpgrades.keys.first);
    }
    return _posterUpgrades.putIfAbsent(entry.url,()=>_lookupPoster(entry));
  }

  static Future<Movie?> _lookupPoster(CatalogEntry entry) async {
    // Resolve at most three known TMDB IDs concurrently. Do not search
    // TMDB by title for every film on the visible grid.
    if(_activePosterRequests>=3) {
      final slot=Completer<void>();
      _posterQueue.add(slot);
      await slot.future;
    }
    _activePosterRequests++;
    try {
      return await enrich(entry);
    } finally {
      _activePosterRequests--;
      if(_posterQueue.isNotEmpty) _posterQueue.removeAt(0).complete();
    }
  }

  static Future<Movie?> enrich(CatalogEntry entry) {
    // Bound the in-memory TMDB resolver cache; do not retain thousands of
    // futures indefinitely after prolonged browsing/searching.
    if (_results.length >= 500 && !_results.containsKey(entry.url)) {
      _results.remove(_results.keys.first);
    }
    return _results.putIfAbsent(entry.url, () async {
        // Offline verified mapping: avoid search request for every catalog item.
        if (entry.tmdbId != null) {
          // A catalog TMDB ID alone has no artwork. Fetch its real poster first
          // instead of displaying the catalog fallback unconditionally.
          try {
            final detail = await Tmdb.get(
              '${entry.type == 'tv' ? 'tv' : 'movie'}/${entry.tmdbId}');
            if (detail['id'] == entry.tmdbId && _matches(entry, detail)) {
              final movie = _withCollectedMetadata(entry, detail);
              _sourceByTmdb[_key(movie.type, movie.id)] = movie.sourceUrl;
              return movie;
            }
          } catch (_) {
            // Offline/API failure: retained catalog poster is safe fallback.
          }
          final movie = _withCollectedMetadata(entry, {'id': entry.tmdbId});
          _sourceByTmdb[_key(movie.type, movie.id)] = movie.sourceUrl;
          return movie;
        }
        if (entry.year <= 0) return null;
        try {
          final response = await Tmdb.get(entry.type == 'tv' ? 'search/tv' : 'search/movie',
              {'query': entry.title, 'include_adult': 'false'});
          final matches = <Map<String, dynamic>>[];
          for (final item in (response['results'] as List? ?? const [])) {
            if (item is! Map) continue;
            final data = Map<String, dynamic>.from(item);
            final title = (data['title'] ?? data['name'] ?? '').toString();
            final original = (data['original_title'] ?? data['original_name'] ?? '').toString();
            final date = (data['release_date'] ?? data['first_air_date'] ?? '').toString();
            if (!_matches(entry,data)) continue;
            if (data['id'] is num) matches.add(data);
          }
          if (matches.length != 1) {
            return _withCollectedMetadata(entry, {'id': -_stableId(entry.url)});
          }
          final data = matches.single;
          // The crawler owns title, type, release year, and source URL.
          data['title'] = entry.title;
          data['name'] = entry.title;
          data['media_type'] = entry.type;
          data['source_url'] = entry.url;
          final movie = _withCollectedMetadata(entry,data);
          _sourceByTmdb[_key(movie.type, movie.id)] = movie.sourceUrl;
          return movie;
        } catch (_) {
          return _withCollectedMetadata(entry, {'id': -_stableId(entry.url)});
        }
      });
  }
  // Compact persistent index. Cache only filter metadata, never huge TMDB detail responses.
  static const _filterIndexKey='tmdb_filter_index_v2';
  static final Map<String,Future<Map<String,dynamic>?>> _filterDetails={};
  static Map<String,dynamic> _filterIndex={};
  static Future<void>? _indexLoading;
  static Future<void> _loadFilterIndex() => _indexLoading ??= _readFilterIndex();
  static Future<void> _readFilterIndex() async {
    try {
      final prefs=await SharedPreferences.getInstance();
      final saved=prefs.getString(_filterIndexKey);
      if(saved!=null) _filterIndex=Map<String,dynamic>.from(jsonDecode(saved) as Map);
    } catch (_) {_filterIndex={};}
  }
  static Future<void> _saveFilterIndex() async {
    try {
      // Keep disk storage bounded; stale entries can be refreshed on demand.
      if(_filterIndex.length>6000){
        final keys=_filterIndex.keys.take(_filterIndex.length-6000).toList();
        for(final key in keys)_filterIndex.remove(key);
      }
      final prefs=await SharedPreferences.getInstance();
      await prefs.setString(_filterIndexKey,jsonEncode(_filterIndex));
    } catch (_) { /* Metadata can always be fetched again. */ }
  }
  static bool _filterIndexDirty=false;
  static Future<void> _flushFilterIndex() async {
    if(!_filterIndexDirty)return;
    _filterIndexDirty=false;
    await _saveFilterIndex();
  }
  static Future<Map<String,dynamic>?> _filterMetadataFor(CatalogEntry entry) async {
    await _loadFilterIndex();
    final key='${entry.type}:${entry.tmdbId}';
    final stored=_filterIndex[key];
    if(stored is Map) {
      final value=Map<String,dynamic>.from(stored);
      final updated=(value['_cachedAt'] as num?)?.toInt()??0;
      if(DateTime.now().millisecondsSinceEpoch-updated < const Duration(days:30).inMilliseconds) {
        return value;
      }
    }
    if(_filterDetails.length>240)_filterDetails.remove(_filterDetails.keys.first);
    return _filterDetails.putIfAbsent(key,() async {
      try {
        final details=await Tmdb.get('${entry.type}/${entry.tmdbId}');
        final compact=<String,dynamic>{
          'id':entry.tmdbId,
          'genre_ids':(details['genres'] as List? ?? const [])
              .whereType<Map>().map((e)=>e['id']).whereType<num>().map((e)=>e.toInt()).toList(),
          'original_language':details['original_language']??'',
          'poster_path':details['poster_path']??'',
          'vote_average':details['vote_average']??0,
          'popularity':details['popularity']??0,
          '_cachedAt':DateTime.now().millisecondsSinceEpoch,
        };
        _filterIndex[key]=compact;
        _filterIndexDirty=true;
        return compact;
      } catch (_) {return null;}
      finally {_filterDetails.remove(key);}
    });
  }
  // Sorting 29k+ titles for every keystroke is expensive. Keep a sorted
  // snapshot of the current catalog and invalidate it when the catalog list
  // instance changes after FilmStreamCatalog.refresh().
  static List<CatalogEntry>? _sortedCatalog;
  static List<CatalogEntry>? _sortedSource;
  static List<CatalogEntry> _catalogByYear(List<CatalogEntry> source) {
    if (identical(source, _sortedSource) && _sortedCatalog != null) {
      return _sortedCatalog!;
    }
    final futureLimit=DateTime.now().year+2;
    final sorted=List<CatalogEntry>.of(source)..sort((a,b){
      final af=a.year>futureLimit;
      final bf=b.year>futureLimit;
      if(af!=bf)return af?1:-1;
      final byYear=b.year.compareTo(a.year);
      if(byYear!=0)return byYear;
      final byTitle=a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return byTitle!=0?byTitle:a.url.compareTo(b.url);
    });
    _sortedSource=source;
    _sortedCatalog=sorted;
    return sorted;
  }
  // A numbered page may need multiple TMDB ranking/discovery pages because
  // the source catalog is the allow-list. Fetch a fixed, non-overlapping
  // window so page N and page N+1 never reuse the same TMDB candidates.
  // Cache the catalog identity index across filter/discovery pages.
  static List<CatalogEntry>? _discoveryIndexedSource;
  static Map<String,List<CatalogEntry>> _discoveryById={};
  static Map<String,List<CatalogEntry>> _discoveryByTitle={};
  static void _ensureDiscoveryIndex(List<CatalogEntry> source){
    if(identical(source,_discoveryIndexedSource))return;
    final byId=<String,List<CatalogEntry>>{};
    final byTitle=<String,List<CatalogEntry>>{};
    for(final e in source){
      if(e.tmdbId!=null)byId.putIfAbsent('${e.type}:${e.tmdbId}',()=>[]).add(e);
      byTitle.putIfAbsent('${e.type}:${e.year}:${_norm(e.title)}',()=>[]).add(e);
    }
    _discoveryById=byId;
    _discoveryByTitle=byTitle;
    _discoveryIndexedSource=source;
  }

  static Future<List<Movie>> _filledDiscoveryPage(
    List<CatalogEntry> source,String endpoint,int page,
    Map<String,String> params,String type) async {
    const window=3;
    final start=(page-1)*window+1;
    if(start>500)return [];
    final pages=await Future.wait([
      for(var p=start;p<start+window&&p<=500;p++)
        Tmdb.get(endpoint,{'page':'$p',...params}),
    ]);
    final media=endpoint.endsWith('/tv')?'tv':endpoint.endsWith('/movie')?'movie':null;
    _ensureDiscoveryIndex(source);
    final byId=_discoveryById;
    final byTitle=_discoveryByTitle;
    final found=<Movie>[];
    final seen=<String>{};
    for(final batch in pages){
      for(final raw in (batch['results'] as List? ?? const [])){
        if(raw is! Map || raw['id'] is! num)continue;
        final data=Map<String,dynamic>.from(raw);
        final kind=(data['media_type']??media??type).toString();
        if(kind!='movie'&&kind!='tv')continue;
        final date=(data['release_date']??data['first_air_date']??'').toString();
        final year=date.length>=4?int.tryParse(date.substring(0,4)):null;
        if(year==null)continue;
        final id=(data['id'] as num).toInt();
        final ids=byId['$kind:$id']??const <CatalogEntry>[];
        CatalogEntry? selected;
        if(ids.length==1 && ids.single.year==year){
          selected=ids.single;
        }else if(ids.isEmpty){
          final candidates=<CatalogEntry>{};
          for(final name in [
            (data['title']??data['name']??'').toString(),
            (data['original_title']??data['original_name']??'').toString()
          ]){
            candidates.addAll(byTitle['$kind:$year:${_norm(name)}']??const []);
          }
          if(candidates.length==1)selected=candidates.single;
        }
        if(selected==null || (media!=null && selected.type!=media) ||
           !seen.add(selected.url))continue;
        data['media_type']=selected.type;
        final movie=_withCollectedMetadata(selected,data);
        _sourceByTmdb[_key(movie.type,movie.id)]=movie.sourceUrl;
        _pagePosterEntries[movie.sourceUrl]=selected;
        if(_pagePosterEntries.length>320)
          _pagePosterEntries.remove(_pagePosterEntries.keys.first);
        found.add(movie);
        if(found.length>=20)return found;
      }
    }
    return found;
  }

  static Future<List<Movie>> list(String endpoint,{int page=1,Map<String,String> params=const {},String type='movie'}) async {
    // Only local Film/Series/Filter/Search use the catalog query index.
    // Home ranking/collections use TMDB, matched to catalog entries below.
    if (CatalogQueryIndex.handles(endpoint)) {
      final index=await CatalogQueryIndex.load();
      final slice=index.select(endpoint,page:page,type:type,params:params);
      return slice.items.map((entry) {
        final movie=_withCollectedMetadata(entry,{
          'id':entry.tmdbId ?? -_stableId(entry.url),
        });
        _sourceByTmdb[_key(movie.type,movie.id)]=movie.sourceUrl;
        _pagePosterEntries[movie.sourceUrl]=entry;
        if(_pagePosterEntries.length>320)
          _pagePosterEntries.remove(_pagePosterEntries.keys.first);
        return movie;
      }).toList(growable:false);
    }
    final source=await FilmStreamCatalog.load();
    // New home collections are filtered lists of actual catalog entries.
    if (endpoint == 'home/latest') {
      // Newest actual TMDB releases, never an invented catalog popularity sort.
      return list('discover/movie', page:page, type:'movie', params:{
        'sort_by':'primary_release_date.desc',
        'primary_release_date.lte':
            DateTime.now().toIso8601String().substring(0,10),
        'include_adult':'false',
      });
    }
    if (endpoint == 'home/family') {
      // Unknown age classifications are excluded. Family genre PLUS an
      // available G/PG certification are required from TMDB discovery.
      return list('discover/movie', page:page, type:'movie', params:{
        'with_genres':'10751',
        'certification_country':'US',
        'certification.lte':'PG',
        'include_adult':'false',
        'sort_by':'popularity.desc',
        if(params['fill_page']=='true') 'fill_page':'true',
      });
    }
    if (endpoint == 'home/recommended') {
      // Choose a genre from the most recent watch history. If there is no
      // useful history, use current trending rather than fabricated taste.
      for (final watched in WatchStore.entries.value.take(3)) {
        if (watched.tmdbId <= 0) continue;
        final media = watched.type == 'tv' ? 'tv' : 'movie';
        try {
          final detail = await Tmdb.get('$media/${watched.tmdbId}');
          final genres = (detail['genres'] as List? ?? const [])
              .whereType<Map>()
              .map((g) => g['id'])
              .whereType<num>()
              .map((id) => id.toInt())
              .where((id) => id > 0)
              .toList();
          if (genres.isEmpty) continue;
          final picked = await list('discover/$media', page:page, type:media,
            params:{'with_genres':'${genres.first}',
              'include_adult':'false','sort_by':'popularity.desc',
              if(params['fill_page']=='true') 'fill_page':'true'});
          if (picked.isNotEmpty) return picked;
        } catch (_) { /* Use the next recent item or trending fallback. */ }
      }
      return list('trending/all/week',page:page,type:'movie',params:params);
    }
    // Home rails and their "Lihat Lainnya" pages share the same TMDB-ranked
    // source windows. The metadata already contains TMDB poster/backdrop.
    if(endpoint.startsWith('discover/') ||
       endpoint.startsWith('trending/') ||
       endpoint.endsWith('/popular') ||
       endpoint.endsWith('/top_rated')){
      final clean=Map<String,String>.from(params)..remove('fill_page');
      return _filledDiscoveryPage(source,endpoint,page,clean,type);
    }
    // TMDB discovers movies by genre/language first. Only show titles that
    // can be matched safely with entries from the owner's catalog.
    if(endpoint.startsWith('discover/')) {
      final media=endpoint.endsWith('/tv')?'tv':'movie';
      final response=await Tmdb.get(endpoint,{'page':'$page',...params});
      final catalog=source.where((e)=>e.type==media).toList();
      final byId=<int,List<CatalogEntry>>{};
      final byTitleYear=<String,List<CatalogEntry>>{};
      for(final entry in catalog) {
        if(entry.tmdbId!=null)byId.putIfAbsent(entry.tmdbId!,()=>[]).add(entry);
        byTitleYear.putIfAbsent('${entry.year}:${_norm(entry.title)}',()=>[]).add(entry);
      }
      final matches=<Movie>[];
      for(final raw in (response['results'] as List? ?? const [])) {
        if(raw is! Map || raw['id'] is! num)continue;
        final item=Map<String,dynamic>.from(raw);
        final id=(item['id'] as num).toInt();
        CatalogEntry? entry;
        final exactId=byId[id]??const <CatalogEntry>[];
        if(exactId.length==1) {
          entry=exactId.single;
        } else if(exactId.isEmpty) {
          final date=(item['release_date']??item['first_air_date']??'').toString();
          final year=date.length>=4?int.tryParse(date.substring(0,4)):null;
          if(year==null)continue;
          final candidates=<CatalogEntry>{};
          for(final title in <String>[
            (item['title']??item['name']??'').toString(),
            (item['original_title']??item['original_name']??'').toString()
          ]) {
            if(title.trim().isEmpty)continue;
            candidates.addAll(byTitleYear['${year}:${_norm(title)}']??const []);
          }
          if(candidates.length==1)entry=candidates.single;
        }
        if(entry==null)continue;
        item['media_type']=entry.type;
        final movie=_withCollectedMetadata(entry,item);
        _sourceByTmdb[_key(movie.type,movie.id)]=movie.sourceUrl;
        matches.add(movie);
      }
      return matches;
    }
    // TMDB supplies ranking only; crawler catalog remains the allow-list.
    if (endpoint.startsWith('trending/') || endpoint.endsWith('/popular') || endpoint.endsWith('/top_rated')) {
      final data=await Tmdb.get(endpoint, {'page':'$page'});
      final typeFilter=endpoint.startsWith('trending/movie/')||endpoint.startsWith('movie/')?'movie':
          endpoint.startsWith('trending/tv/')||endpoint.startsWith('tv/')?'tv':null;
      final byIdentity=<String, List<CatalogEntry>>{};
      for(final e in source){
        if(typeFilter!=null && e.type!=typeFilter)continue;
        byIdentity.putIfAbsent('${e.type}:${e.year}:${_norm(e.title)}',()=>[]).add(e);
      }
      final chosen=<CatalogEntry>[];
      for(final raw in (data['results'] as List? ?? const [])){
        if(raw is! Map)continue;
        final item=Map<String,dynamic>.from(raw);
        final media=(item['media_type']??(typeFilter=='tv'?'tv':'movie')).toString();
        if(media!='tv'&&media!='movie')continue;
        final date=(item['release_date']??item['first_air_date']??'').toString();
        if(date.length<4)continue;
        final year=int.tryParse(date.substring(0,4));
        if(year==null)continue;
        final titles=[(item['title']??item['name']??'').toString(),
          (item['original_title']??item['original_name']??'').toString()];
        final candidates=<CatalogEntry>{};
        for(final title in titles){
          candidates.addAll(byIdentity['${media}:${year}:${_norm(title)}']??const []);
        }
        if(candidates.isEmpty){
          candidates.addAll(source.where((e)=>e.type==media&&(e.year-year).abs()<=1 &&
            titles.any((t)=>_similarity(e.title,t)>=.90)).take(2));
        }
        if(candidates.length!=1)continue;
        final entry=candidates.single;
        if(item['id'] is! num)continue;
        item['title']=entry.title;
        item['name']=entry.title;
        item['media_type']=entry.type;
        item['source_url']=entry.url;
        // Use the same catalog-keyed metadata resolver as search results.
        // Popular and search must not select different TMDB posters for
        // the same LK21 entry merely because they came from different APIs.
        chosen.add(entry);
      }
      final ranked=<Movie>[];
      for(var i=0;i<chosen.length;i+=4){
        ranked.addAll((await Future.wait(chosen.skip(i).take(4).map(enrich)))
          .whereType<Movie>());
      }
      return ranked;
    }
    final query=(params['query']??'').trim().toLowerCase();
    final category=endpoint=='catalog/sorted'?(type=='all'?null:type):
      endpoint.startsWith('search/')||endpoint=='trending/all/week'?null:
       endpoint=='catalog/tv'||endpoint.startsWith('tv/')||endpoint.contains('/tv/')?'tv':
       endpoint=='catalog/movie'||endpoint.startsWith('movie/')||endpoint.contains('/movie/')?'movie':
       type=='tv'?'tv':type=='movie'?'movie':null;
    final queryMatch=query.isEmpty?null:query;
    final filtered=_catalogByYear(source).where((e)=>
      (category==null||e.type==category) &&
      (queryMatch==null||e.title.toLowerCase().contains(queryMatch))).toList();
    final start=(page-1)*20;
    if(start>=filtered.length)return [];
    final selected=filtered.skip(start).take(20).toList();
    // Film, Series, and Latest are paged views of the already downloaded
    // catalog. Enriching 20 titles via TMDB (in five network batches)
    // before showing a page made every numbered-page change feel slow.
    // Use the catalog's reviewed title/year/source/poster/TMDB ID directly.
    // The detail page can fetch extra TMDB fields when the user opens it.
    if (endpoint == 'catalog/movie' || endpoint == 'catalog/tv' ||
        endpoint == 'catalog/sorted' || endpoint == 'search/multi') {
      return selected.map((entry) {
        final movie=_withCollectedMetadata(entry,{
          'id':entry.tmdbId ?? -_stableId(entry.url),
        });
        _sourceByTmdb[_key(movie.type,movie.id)]=movie.sourceUrl;
        _pagePosterEntries[movie.sourceUrl]=entry;
        // Bound the mapping just like the existing metadata cache.
        if(_pagePosterEntries.length>200){
          _pagePosterEntries.remove(_pagePosterEntries.keys.first);
        }
        return movie;
      }).toList();
    }
    final found=<Movie>[];
    for(var i=0;i<selected.length;i+=4){
      found.addAll((await Future.wait(selected.skip(i).take(4).map(enrich))).whereType<Movie>());
    }
    return found;
  }
}
class Tmdb {
 static final Map<String,Future<String>> _translationCache = {};
 // MyMemory public translation endpoint: 500 UTF-8 bytes per request.
 static Future<String> translateOverview(String source) => _translationCache.putIfAbsent(source, () async {
   if (source.trim().isEmpty) return source;
   final chunks = <String>[];
   var chunk = '';
   for (final word in source.split(RegExp(r'\s+'))) {
     if (word.isEmpty) continue;
     final proposed = chunk.isEmpty ? word : '$chunk $word';
     if (utf8.encode(proposed).length > 380 && chunk.isNotEmpty) {
       chunks.add(chunk); chunk = word;
     } else { chunk = proposed; }
   }
   if (chunk.isNotEmpty) chunks.add(chunk);
   if (chunks.isEmpty || chunks.any((c) => utf8.encode(c).length > 500)) return source;
   final output = <String>[];
   for (final part in chunks) {
     try {
       final uri = Uri.https('api.mymemory.translated.net', '/get', {
         'q':part, 'langpair':'en|id',
       });
       final r = await http.get(uri).timeout(const Duration(seconds:8));
       if (r.statusCode != 200) return source;
       final data = jsonDecode(r.body) as Map<String,dynamic>;
       if ((data['responseStatus'] as num?)?.toInt() != 200) return source;
       var result = (data['responseData']?['translatedText'] ?? '').toString().trim();
       if (result.isEmpty || result.toUpperCase().contains('MYMEMORY WARNING')) return source;
       result = result.replaceAll('&quot;', '"').replaceAll('&#39;', "'")
         .replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>');
       output.add(result);
     } catch (_) { return source; }
   }
   return output.join(' ');
 });
 static Future<List<Map<String,dynamic>>>? _languagesCache;
 static Future<List<Map<String,dynamic>>> languages() => _languagesCache ??= _loadLanguages();
 static Future<List<Map<String,dynamic>>> _loadLanguages() async {
  if(tmdbToken.isEmpty)throw Exception('TMDB_TOKEN belum diatur.');
  final r=await http.get(Uri.https('api.themoviedb.org','/3/configuration/languages'),
    headers:{'Authorization':'Bearer $tmdbToken','accept':'application/json'})
    .timeout(const Duration(seconds:20));
  if(r.statusCode!=200)throw Exception('TMDB languages HTTP ${r.statusCode}');
  return (jsonDecode(r.body) as List).whereType<Map>()
    .map((e)=>Map<String,dynamic>.from(e)).toList(growable:false);
 }
 static final Map<String,Future<List<Movie>>> _railCache = {};
 // Reuse recent TMDB discovery/ranking responses across page revisits.
 static final Map<String,Future<Map<String,dynamic>>> _listRequestCache={};
 static void clearCatalogRails() => _railCache.clear();
  static Future<List<Movie>> rail(String endpoint, String type) =>
     endpoint == 'home/recommended'
         ? list(endpoint, type:type)
         : _railCache.putIfAbsent("$endpoint|$type",
             () => list(endpoint,type:type));
 static Future<Map<String,dynamic>> get(String endpoint,[Map<String,String> params=const {}]) async {
  if(tmdbToken.isEmpty)throw Exception('TMDB_TOKEN belum diatur.');
  final uri=Uri.https('api.themoviedb.org','/3/$endpoint',{'language':'en-US',...params});
  Future<Map<String,dynamic>> request() async {
    final r=await http.get(uri,headers:{
      'Authorization':'Bearer $tmdbToken','accept':'application/json',
    }).timeout(const Duration(seconds:20));
    if(r.statusCode!=200)throw Exception('TMDB HTTP ${r.statusCode}');
    return jsonDecode(r.body) as Map<String,dynamic>;
  }
  final isListing=(endpoint.startsWith('discover/') ||
      endpoint.startsWith('trending/') ||
      endpoint.endsWith('/popular') || endpoint.endsWith('/top_rated')) &&
      params.containsKey('page');
  if(!isListing)return request();
  final key=uri.toString();
  if(_listRequestCache.length>140 &&
      !_listRequestCache.containsKey(key)){
    _listRequestCache.remove(_listRequestCache.keys.first);
  }
  return _listRequestCache.putIfAbsent(key,()=>request().catchError((Object e){
    _listRequestCache.remove(key);
    throw e;
  }));
 }
 // Keep titles, season names, and matching metadata in English; replace only
 // descriptions with Indonesian when TMDB supplies a non-empty translation.
 static Future<Map<String,dynamic>> bilingualDetail(String endpoint) async {
  final english = await get(endpoint);
  try {
   final indonesian = await get(endpoint, {'language':'id-ID'});
   final description = (indonesian['overview'] ?? '').toString().trim();
   if (description.isNotEmpty) { english['overview'] = description; } else { english['overview'] = await translateOverview((english['overview'] ?? '').toString()); }
   // Episode descriptions can also be localized without changing episode identity.
   final englishEpisodes = english['episodes'];
   final indonesianEpisodes = indonesian['episodes'];
   if (englishEpisodes is List && indonesianEpisodes is List) {
    final translatedByNumber = <int,String>{};
    for (final item in indonesianEpisodes) {
     if (item is Map && item['episode_number'] is num) {
      final description = (item['overview'] ?? '').toString().trim();
      if (description.isNotEmpty) translatedByNumber[(item['episode_number'] as num).toInt()] = description;
     }
    }
    for (final item in englishEpisodes) {
     if (item is Map<String,dynamic> && item['episode_number'] is num) {
      final localized = translatedByNumber[(item['episode_number'] as num).toInt()];
      if (localized != null) item['overview'] = localized;
     }
    }
   }
  } catch (_) { english['overview'] = await translateOverview((english['overview'] ?? '').toString()); }
  return english;
 }
 static Future<List<Movie>> list(String endpoint,{int page=1,Map<String,String> params=const {},String type='movie'}) =>
   LocalCatalogMetadata.list(endpoint,page:page,params:params,type:type);
}
class HomePage extends StatefulWidget {const HomePage({super.key});@override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage> {
 int tab=0;String genre='';String query='';String suggestionText='';
 Timer? debounce;
 Timer? suggestionDebounce;final search=TextEditingController();final searchFocus=FocusNode();
 final homeScroll=ScrollController();
 final favorites=<String,Movie>{};
 int catalogRefresh=0;
 static const labels=['Beranda','Film','Series','Filter','Favorit'];
 static const genreNames={28:'Action',12:'Adventure',16:'Animasi',35:'Komedi',80:'Kriminal',99:'Dokumenter',18:'Drama',10751:'Keluarga',14:'Fantasi',36:'Sejarah',27:'Horor',10402:'Musik',9648:'Misteri',10749:'Romantis',878:'Sci-Fi',53:'Thriller',10752:'Perang',37:'Western'};
 @override void dispose(){debounce?.cancel();suggestionDebounce?.cancel();searchFocus.dispose();search.dispose();homeScroll.dispose();super.dispose();}
 void open(Movie m) => Navigator.push(context,MaterialPageRoute(builder:(_)=>DetailPage(movie:m,isFavorite:favorites.containsKey('${m.type}:${m.id}'),onFavorite:(){setState((){final k='${m.type}:${m.id}';if(favorites.containsKey(k)){favorites.remove(k);}else{favorites[k]=m;}});})));
 void changeTab(int n) {
   final returningHome = n == 0 && tab != 0;
   debounce?.cancel();
   suggestionDebounce?.cancel();
   search.clear();
   setState(() { tab = n; genre = ''; query = ''; suggestionText=''; });
   // PageStorage may restore an old scroll offset when the Home tab is rebuilt.
   // Always show the hero first when coming back from Film/Series/Filter.
   if (returningHome) {
     WidgetsBinding.instance.addPostFrameCallback((_) {
       if (!mounted || tab != 0 || !homeScroll.hasClients) return;
       homeScroll.jumpTo(0);
     });
   }
 }
 void selectSearchSuggestion(String title){debounce?.cancel();suggestionDebounce?.cancel();FocusScope.of(context).unfocus();search.value=TextEditingValue(text:title,selection:TextSelection.collapsed(offset:title.length));setState((){query=title;suggestionText='';});}
 void openCollection(String title,String endpoint,String type) => Navigator.push(context,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:Text(title)),body:PagedGrid(title:title,endpoint:endpoint,type:type,onTap:open))));
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Row(mainAxisSize:MainAxisSize.min,children:[Icon(FilmStreamIcons.brand,color:Color(0xffe5aa55),size:27),SizedBox(width:9),Text('FILM STREAMING',style:TextStyle(fontWeight:FontWeight.w900,letterSpacing:0.8,fontSize:19))]),actions:[IconButton(tooltip:'Riwayat tontonan',icon:const Icon(FilmStreamIcons.history,size:26),onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const HistoryPage()))),IconButton(tooltip:'Status scanner dan GitHub',icon:const Icon(FilmStreamIcons.info,size:26),onPressed:()=>CatalogSyncDiagnostics.show(context))]),bottomNavigationBar:Platform.isWindows?null:NavigationBar(selectedIndex:tab,onDestinationSelected:changeTab,destinations:const [
  NavigationDestination(icon:Icon(FilmStreamIcons.home,size:27),selectedIcon:Icon(FilmStreamIcons.homeSelected,size:27),label:'Beranda'),
  NavigationDestination(icon:Icon(FilmStreamIcons.film,size:27),selectedIcon:Icon(FilmStreamIcons.filmSelected,size:27),label:'Film'),
  NavigationDestination(icon:Icon(FilmStreamIcons.series,size:27),selectedIcon:Icon(FilmStreamIcons.seriesSelected,size:27),label:'Series'),
  NavigationDestination(icon:Icon(FilmStreamIcons.filter,size:27),selectedIcon:Icon(FilmStreamIcons.filterSelected,size:27),label:'Filter'),
  NavigationDestination(icon:Icon(FilmStreamIcons.favorites,size:27),selectedIcon:Icon(FilmStreamIcons.favoritesSelected,size:27),label:'Favorit'),
]),body:DesktopShell(selectedIndex:tab,onSelected:changeTab,child:Column(children:[StartupCatalogCheck(onCatalogUpdated:(){if(mounted){
    CatalogQueryIndex.invalidate();
    CatalogSuggestionIndex.invalidate();
    _CinemaGenresState.invalidate();
    Tmdb.clearCatalogRails();
    setState(()=>catalogRefresh++);
  }}),if(tab!=4)Padding(padding:const EdgeInsets.fromLTRB(14,8,14,8),child:TextField(controller:search,focusNode:searchFocus,decoration:InputDecoration(prefixIcon:const Icon(Icons.search_rounded),hintText:'Cari film atau series...',suffixIcon:ValueListenableBuilder<TextEditingValue>(valueListenable:search,builder:(context,value,_)=>value.text.isEmpty?const SizedBox.shrink():IconButton(icon:const Icon(Icons.close_rounded),onPressed:(){debounce?.cancel();suggestionDebounce?.cancel();search.clear();setState((){query='';suggestionText='';});})),filled:true,fillColor:const Color(0xff20252e),enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none),focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:const BorderSide(color:Color(0xffe5aa55),width:1.4))),onChanged:(v){debounce?.cancel();suggestionDebounce?.cancel();
 suggestionDebounce=Timer(const Duration(milliseconds:180),(){if(mounted)setState(()=>suggestionText=v.trim());});
 debounce=Timer(const Duration(milliseconds:350),(){if(mounted)setState(()=>query=v.trim());});})),if(tab!=4)AnimatedBuilder(animation:Listenable.merge([search,searchFocus]),builder:(context,_)=>!searchFocus.hasFocus || suggestionText.isEmpty || suggestionText!=search.text.trim()?const SizedBox.shrink():FilmSearchSuggestions(key:ValueKey('suggestions:$catalogRefresh'),text:suggestionText,onSelected:selectSearchSuggestion)),Expanded(child:query.isNotEmpty?PagedGrid(key:ValueKey('search:$query:$catalogRefresh'),title:'Hasil pencarian: $query',endpoint:'search/multi',params:{'query':query,'include_adult':'false'},type:'movie',onTap:open):switch(tab){0=>ListView(key:const PageStorageKey('home-feed'),controller:homeScroll,children:[CinemaHero(key:ValueKey('hero:$catalogRefresh'),onTap:open),CinemaGenres(key:ValueKey('cinema-genres:$catalogRefresh'),onSelect:(id){setState((){tab=3;genre='$id';query='';search.clear();});}),const LastWatchedRail(),const Padding(padding:EdgeInsets.fromLTRB(16,24,16,2),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('JELAJAHI KOLEKSI',style:TextStyle(fontSize:11,letterSpacing:2,color:Color(0xffe5aa55),fontWeight:FontWeight.w800)),SizedBox(height:7),Text('Pilihan untuk kamu',style:TextStyle(fontSize:25,fontWeight:FontWeight.w800))])),MovieRail(key:ValueKey('rail-trending:$catalogRefresh'),title:'Sedang Trending',endpoint:'trending/all/week',type:'movie',onTap:open,onSeeAll:()=>openCollection('Sedang Trending','trending/all/week','movie')),MovieRail(key:ValueKey('rail-film-pop:$catalogRefresh'),title:'Film Populer',endpoint:'movie/popular',type:'movie',onTap:open,onSeeAll:()=>openCollection('Film Populer','movie/popular','movie')),MovieRail(key:ValueKey('rail-series-pop:$catalogRefresh'),title:'Series Populer',endpoint:'tv/popular',type:'tv',onTap:open,onSeeAll:()=>openCollection('Series Populer','tv/popular','tv')),MovieRail(key:ValueKey('rail-film-top:$catalogRefresh'),title:'Film Rating Tinggi',endpoint:'movie/top_rated',type:'movie',onTap:open,onSeeAll:()=>openCollection('Film Rating Tinggi','movie/top_rated','movie')),MovieRail(key:ValueKey('rail-series-top:$catalogRefresh'),title:'Series Rating Tinggi',endpoint:'tv/top_rated',type:'tv',onTap:open,onSeeAll:()=>openCollection('Series Rating Tinggi','tv/top_rated','tv')),ValueListenableBuilder<List<WatchEntry>>(valueListenable:WatchStore.entries,builder:(context,history,_)=>MovieRail(key:ValueKey('rail-home-recommend:$catalogRefresh'),title:'Rekomendasi Untukmu',endpoint:'home/recommended',type:'movie',onTap:open,onSeeAll:()=>openCollection('Rekomendasi Untukmu','home/recommended','movie'))),MovieRail(key:ValueKey('rail-home-latest:$catalogRefresh'),title:'Film Terbaru',endpoint:'home/latest',type:'movie',onTap:open,onSeeAll:()=>openCollection('Film Terbaru','home/latest','movie')),MovieRail(key:ValueKey('rail-home-family:$catalogRefresh'),title:'Nobar Sekeluarga',endpoint:'home/family',type:'movie',onTap:open,onSeeAll:()=>openCollection('Nobar Sekeluarga','home/family','movie')),MovieRail(key:ValueKey('rail-movie-week:$catalogRefresh'),title:'Film Trending Minggu Ini',endpoint:'trending/movie/week',type:'movie',onTap:open,onSeeAll:()=>openCollection('Film Trending Minggu Ini','trending/movie/week','movie')),MovieRail(key:ValueKey('rail-tv-week:$catalogRefresh'),title:'Series Trending Minggu Ini',endpoint:'trending/tv/week',type:'tv',onTap:open,onSeeAll:()=>openCollection('Series Trending Minggu Ini','trending/tv/week','tv')),const SizedBox(height:16)]),1=>PagedGrid(key:ValueKey('film:$catalogRefresh'),title:'Semua Film',endpoint:'catalog/movie',type:'movie',onTap:open),2=>PagedGrid(key:ValueKey('tv:$catalogRefresh'),title:'Semua Series',endpoint:'catalog/tv',type:'tv',onTap:open),3=>FilmstreamFilter(key:ValueKey('filter:$catalogRefresh'),initialGenre:genre,onTap:open),_=>favorites.isEmpty?const Center(child:Text('Belum ada favorit. Simpan dari halaman detail.')):GridView.builder(padding:const EdgeInsets.all(12),gridDelegate:filmstreamGridDelegate(context),itemCount:favorites.length,itemBuilder:(context,i)=>MovieTile(movie:favorites.values.elementAt(i),onTap:open))})])));
}
// Cinema Booking-inspired layout using FilmStream's own TMDB data and widgets.

class DesktopShell extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget child;
  const DesktopShell({super.key, required this.selectedIndex, required this.onSelected, required this.child});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  bool _sidebarVisible = true;
  static const _titles = ['Beranda', 'Film', 'Series', 'Filter', 'Favorit'];
  static const _icons = [Icons.home_outlined, Icons.movie_outlined, Icons.tv_outlined, Icons.tune, Icons.favorite_outline];

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return widget.child;
    return ScrollConfiguration(
      behavior: const FilmstreamDesktopDragBehavior(),
      child: LayoutBuilder(builder: (context, constraints) {
        final fullWidth = constraints.maxWidth < 950 ? 76.0 : 232.0;
        return Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            width: _sidebarVisible ? fullWidth : 52,
            decoration: const BoxDecoration(
              color: Color(0xff171b22),
              border: Border(right: BorderSide(color: Color(0xff30343d))),
            ),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 14),
                child: IconButton(
                  tooltip: _sidebarVisible ? 'Sembunyikan menu' : 'Tampilkan menu',
                  icon: Icon(_sidebarVisible ? Icons.menu_open_rounded : Icons.menu_rounded),
                  color: const Color(0xffe5aa55),
                  onPressed: () => setState(() => _sidebarVisible = !_sidebarVisible),
                ),
              ),
              if (_sidebarVisible) ...[
                if (constraints.maxWidth >= 950)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 26, top: 10),
                    child: Text('FILM STREAMING', style: TextStyle(
                      color: Color(0xffe5aa55), fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                for (var i = 0; i < _titles.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(left: 10, right: 10, bottom: 7),
                    child: Material(
                      color: widget.selectedIndex == i ? const Color(0xff493724) : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: ListTile(
                        leading: Icon(_icons[i], color: widget.selectedIndex == i
                            ? const Color(0xffe5aa55) : Colors.white70),
                        title: constraints.maxWidth >= 950 ? Text(_titles[i]) : null,
                        selected: widget.selectedIndex == i,
                        onTap: () => widget.onSelected(i),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                const Spacer(),
                if (constraints.maxWidth >= 950)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('Windows Desktop', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ),
              ],
            ]),
          ),
          Expanded(child: widget.child),
        ]);
      }),
    );
  }
}

class FilmstreamFilter extends StatefulWidget {
 final String initialGenre;
 final ValueChanged<Movie> onTap;
 const FilmstreamFilter({super.key,required this.initialGenre,required this.onTap});
 @override State<FilmstreamFilter> createState()=>_FilmstreamFilterState();
}
class _FilmstreamFilterState extends State<FilmstreamFilter> {
 static const genres=<int,String>{0:'Semua genre',28:'Action',12:'Petualangan',16:'Animasi',35:'Komedi',80:'Kriminal',99:'Dokumenter',18:'Drama',10751:'Keluarga',14:'Fantasi',36:'Sejarah',27:'Horor',10402:'Musik',9648:'Misteri',10749:'Romantis',878:'Sci-Fi',53:'Thriller',10752:'Perang',37:'Western'};
 String sort='title',type='all',country='';
 late final Future<void> _filterOptions;
 List<DropdownMenuItem<int>> _genreOptions = const [DropdownMenuItem(value:0,child:Text('Semua genre'))];
 List<DropdownMenuItem<String>> _languageOptions = const [DropdownMenuItem(value:'',child:Text('Semua bahasa'))];
 bool _optionsLoaded = false;
 int genre1=0,genre2=0,page=0,epoch=0;
 int visiblePage=1;
 // A partly collected page is not yet a valid navigation destination.
 // Only the terminal page may contain fewer than 20 titles.
 int get loadedPages => completedFilterPages(results.length, more);
 bool fillingPage=false;
 bool busy=false,more=true;
 String error='';
 final results=<Movie>[];
 final Set<String> seenResults=<String>{};
 final ScrollController scroll=ScrollController();
 @override void initState(){
   super.initState();
   genre1=int.tryParse(widget.initialGenre)??0;
   _filterOptions=_loadOptions();
   _fillThrough(1);
 }
 @override void didUpdateWidget(covariant FilmstreamFilter old){super.didUpdateWidget(old);if(old.initialGenre!=widget.initialGenre){genre1=int.tryParse(widget.initialGenre)??0;_reset();}}
 @override void dispose(){scroll.dispose();super.dispose();}
 void _reset(){
   epoch++;results.clear();seenResults.clear();page=0;visiblePage=1;
   more=true;error='';busy=false;fillingPage=false;
   if(scroll.hasClients)scroll.jumpTo(0);
   setState((){});
   _fillThrough(1);
 }
 // Source batches often have only 2–4 matching titles; do not mistake
 // those for finished user-facing numbered pages.
 Future<void> _fillThrough(int target) async {
   if(fillingPage||target<1||target>loadedPages+(more?1:0))return;
   if(target<=loadedPages){
     setState(()=>visiblePage=target);
     if(scroll.hasClients)scroll.jumpTo(0);
     return; // Revisit an already completed page without loading.
   }
   final token=epoch;
   setState((){fillingPage=true;error='';});
   try {
     while(mounted&&epoch==token&&loadedPages<target&&more&&error.isEmpty){
       final previousPage=page;
       await _fetch();
       if(!mounted||epoch!=token)return;
       if(page==previousPage)break; // Network failed; retry explicitly.
     }
     if(!mounted||epoch!=token||loadedPages<target)return;
     setState(()=>visiblePage=target);
     if(scroll.hasClients)scroll.jumpTo(0);
   } finally {
     if(mounted&&epoch==token)setState(()=>fillingPage=false);
   }
 }
 Future<void> _goFilterPage(int target)=>_fillThrough(target);
 Future<void> _loadOptions() async {
  try {
   final index=await CatalogQueryIndex.load();
   if(!mounted)return;
   final available=index.availableGenres;
   final languages=index.availableLanguageOptions;
   setState((){
    _genreOptions=[
     const DropdownMenuItem<int>(value:0,child:Text('Semua genre')),
     ...available.map((entry)=>DropdownMenuItem<int>(
       value:entry.key,child:Text(entry.value))),
    ];
    if(genre1>0 && !available.any((entry)=>entry.key==genre1)) {
     _genreOptions.add(DropdownMenuItem<int>(
       value:genre1,child:Text('Genre $genre1')));
    }
    _languageOptions=[
     const DropdownMenuItem<String>(value:'',child:Text('Semua bahasa')),
     ...languages.map((entry)=>DropdownMenuItem<String>(
       value:entry.key,child:Text(entry.value))),
    ];
    _optionsLoaded=true;
   });
  } catch (_) {
   if(mounted)setState(()=>_optionsLoaded=true);
  }
 }
 Future<void> _fetch() async {
  if(busy||!more)return;
  final token=epoch;
  setState(()=>busy=true);
  try {
   // All filtering and pagination happens locally on catalog records.
   // Never request 3-5 TMDB discovery pages just to fill one UI page.
   final nextPage=page+1;
   final incoming=await Tmdb.list('catalog/filter',page:nextPage,
      type:type,params:{
       'sort':sort,
       'genre1':'$genre1',
       'genre2':'$genre2',
       'language':country,
      });
   if(!mounted||token!=epoch)return;
   setState((){
    page=nextPage;
    results.addAll(incoming);
    more=incoming.length==catalogPageSize;
    error='';
   });
  } catch (_) {
   if(mounted&&token==epoch)setState(
     ()=>error='Gagal membaca filter katalog. Coba lagi.');
  } finally {
   if(mounted&&token==epoch)setState(()=>busy=false);
  }
 }
 Widget _pick<T>(String caption,T value,List<DropdownMenuItem<T>> options,ValueChanged<T?> update)=>DropdownButtonFormField<T>(
  menuMaxHeight:380,
  value:value,
  isExpanded:true,
  dropdownColor:const Color(0xff252931),
  icon:const Icon(Icons.keyboard_arrow_down_rounded,size:20,color:Colors.white70),
  style:const TextStyle(fontSize:14,color:Colors.white,fontWeight:FontWeight.w600),
  decoration:InputDecoration(
    labelText:caption,
    labelStyle:const TextStyle(fontSize:13,color:Colors.white60),
    floatingLabelStyle:const TextStyle(fontSize:13,color:Color(0xffE5B677)),
    isDense:true,
    contentPadding:const EdgeInsets.symmetric(horizontal:12,vertical:12),
    filled:true,
    fillColor:const Color(0xff252931),
    enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:Color(0xff454B56))),
    focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:Color(0xffD8A260),width:1.5)),
    border:OutlineInputBorder(borderRadius:BorderRadius.circular(12)),
  ),
  items:options,
  onChanged:(v){update(v);_reset();});
 @override Widget build(BuildContext context){
  final startIndex=(visiblePage-1)*catalogPageSize;
  final visible=visiblePage<=loadedPages&&startIndex<results.length
    ? results.skip(startIndex).take(catalogPageSize).toList()
    : <Movie>[];
  return CustomScrollView(controller:scroll,slivers:[
  SliverToBoxAdapter(child:Column(children:[
  Padding(
    padding:const EdgeInsets.fromLTRB(12,8,12,8),
    child:Container(
      padding:const EdgeInsets.fromLTRB(14,14,14,16),
      decoration:BoxDecoration(
        color:const Color(0xff1B1E25),
        borderRadius:BorderRadius.circular(18),
        border:Border.all(color:const Color(0xff343944)),
      ),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Row(children:[
          Icon(Icons.tune_rounded,size:20,color:Color(0xffD8A260)),
          SizedBox(width:9),
          Text('Sesuaikan Katalog',style:TextStyle(fontSize:17,fontWeight:FontWeight.w700)),
        ]),
        const SizedBox(height:4),
        const Text('Temukan film dan series sesuai pilihanmu',
          style:TextStyle(fontSize:12,color:Colors.white60)),
        const SizedBox(height:16),
        Row(children:[
          Expanded(child:_pick<String>('Urutkan',sort,const [
            DropdownMenuItem(value:'title',child:Text('Abjad A–Z')),
            DropdownMenuItem(value:'popular',child:Text('Rating tertinggi')),
            DropdownMenuItem(value:'latest',child:Text('Terbaru'))],(v){if(v!=null)sort=v;})),
          const SizedBox(width:10),
          Expanded(child:_pick<String>('Tipe',type,const [
            DropdownMenuItem(value:'all',child:Text('Film & Series')),
            DropdownMenuItem(value:'movie',child:Text('Film')),
            DropdownMenuItem(value:'tv',child:Text('Series'))],(v){if(v!=null)type=v;})),
        ]),
        const SizedBox(height:12),
        Row(children:[
          Expanded(child:_pick<int>('Genre utama',genre1,_genreOptions,(v){genre1=v??0;})),
          const SizedBox(width:10),
          Expanded(child:_pick<int>('Genre tambahan',genre2,_genreOptions,(v){genre2=v??0;})),
        ]),
        const SizedBox(height:12),
        _pick<String>('Bahasa asli',country,_languageOptions,(v){country=v??'';}),
      ]),
    ),
  ),
  if(!_optionsLoaded) const Padding(padding:EdgeInsets.all(8),child:LinearProgressIndicator()),
  Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:6),child:Align(alignment:Alignment.centerLeft,child:Text('Katalog ${type=='all'?'Film & Series':type=='tv'?'Series':'Film'}',style:const TextStyle(fontSize:19,fontWeight:FontWeight.w800)))),
  ])),
  if(visible.isEmpty) SliverFillRemaining(hasScrollBody:false,
    child:Center(child:error.isNotEmpty
      ?TextButton(onPressed:()=>_fillThrough(1),child:Text(error))
      :(busy||fillingPage)?const CircularProgressIndicator()
      :more?TextButton(onPressed:()=>_fillThrough(1),
        child:const Text('Cari halaman katalog berikutnya'))
      :const Text('Tidak ada hasil sesuai filter'))),
  if(visible.isNotEmpty) SliverPadding(
    padding:const EdgeInsets.all(12),
    sliver:SliverGrid(delegate:SliverChildBuilderDelegate((context,i)=>
      CatalogPosterTile(key:ValueKey(
          '${visible[i].type}:${visible[i].sourceUrl}'),
        movie:visible[i],onTap:widget.onTap),
      childCount:visible.length),gridDelegate:filmstreamGridDelegate(context))),
  if(results.isNotEmpty) SliverToBoxAdapter(child:Column(children:[
    if(error.isNotEmpty)TextButton(
      onPressed:()=>_fillThrough(visiblePage+1),child:Text(error)),
    if(busy||fillingPage)const Padding(padding:EdgeInsets.all(8),
      child:CircularProgressIndicator()),
    CatalogPageControls(page:visiblePage,
      maxPage:loadedPages+(more?1:0),
      // Keep numbered navigation consistent with the enabled next arrow:
      // the next candidate page is shown only while more data may exist.
      displayedMaxPage:loadedPages+(more?1:0),
      hasNext:visiblePage<loadedPages||more,
      busy:busy||fillingPage,onSelect:_goFilterPage),
  ])),
 ]);
}
}
class CinemaHero extends StatefulWidget {
 final ValueChanged<Movie> onTap;
 const CinemaHero({super.key,required this.onTap});
 @override State<CinemaHero> createState()=>_CinemaHeroState();
}
class _CinemaHeroState extends State<CinemaHero> with AutomaticKeepAliveClientMixin<CinemaHero> {
 @override bool get wantKeepAlive => true;
 late Future<List<Movie>> items;
 final PageController pager=PageController();
 Timer? rotation,refresh;
 int selected=0;
 @override void initState(){super.initState();items=Tmdb.rail('trending/movie/week','movie');rotation=Timer.periodic(const Duration(seconds:6),(_){if(!mounted||!pager.hasClients)return;final count=_heroCount;if(count>1)pager.animateToPage((selected+1)%count,duration:const Duration(milliseconds:450),curve:Curves.easeInOut);});refresh=Timer.periodic(const Duration(hours:1),(_){if(mounted)setState((){selected=0;items=Tmdb.list('trending/movie/week',type:'movie');if(pager.hasClients)pager.jumpToPage(0);});});}
 int _heroCount=0;
 @override void dispose(){rotation?.cancel();refresh?.cancel();pager.dispose();super.dispose();}
 @override Widget build(BuildContext context){super.build(context);return FutureBuilder<List<Movie>>(future:items,builder:(context,s){
  final entries=(s.data??const <Movie>[]).where((m)=>m.backdrop.isNotEmpty).take(6).toList();
  _heroCount=entries.length;
  if(entries.isEmpty) {
    // Keep banner height stable while loading; don't let lower rails jump.
    if(s.connectionState!=ConnectionState.done) {
      return SizedBox(height:Platform.isWindows?340:226,
        child:const Center(child:CircularProgressIndicator()));
    }
    return const SizedBox(height:14);
  }
  return Column(children:[
   ScrollConfiguration(behavior:const FilmstreamDesktopDragBehavior(),child:SizedBox(height:Platform.isWindows ? 316 : 202,child:PageView.builder(controller:pager,itemCount:entries.length,onPageChanged:(i)=>setState(()=>selected=i),
    itemBuilder:(context,i){final m=entries[i];return Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:7),child:InkWell(onTap:()=>widget.onTap(m),borderRadius:BorderRadius.circular(16),child:ClipRRect(borderRadius:BorderRadius.circular(16),child:Stack(fit:StackFit.expand,children:[
      Image.network(filmstreamHeroImageUrl(m.backdrop),fit:BoxFit.cover,gaplessPlayback:true,errorBuilder:(_,__,___)=>const ColoredBox(color:Color(0xff252a34))),
      const DecoratedBox(decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topCenter,end:Alignment.bottomCenter,colors:[Colors.transparent,Color(0xdd000000)]))),
      Positioned(bottom:13,left:15,right:15,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(m.title,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w800,fontSize:21)),Text('Film · ${m.year}  ★ ${m.rating.toStringAsFixed(1)}',style:const TextStyle(fontSize:12,color:Colors.white70))]))
    ]))));}))),
   const SizedBox(height:5),
   Row(mainAxisAlignment:MainAxisAlignment.center,children:[
     if(Platform.isWindows) IconButton(
       tooltip:'Banner sebelumnya',
       icon:const Icon(Icons.chevron_left),
       onPressed:entries.length<2?null:(){
         if(pager.hasClients)pager.animateToPage((selected-1+entries.length)%entries.length,
           duration:const Duration(milliseconds:280),curve:Curves.easeOut);
       }),
     ...List.generate(entries.length,(i)=>AnimatedContainer(duration:const Duration(milliseconds:180),margin:const EdgeInsets.symmetric(horizontal:3),width:i==selected?16:5,height:5,decoration:BoxDecoration(color:i==selected?const Color(0xffe5aa55):Colors.white30,borderRadius:BorderRadius.circular(4)))),
     if(Platform.isWindows) IconButton(
       tooltip:'Banner berikutnya',
       icon:const Icon(Icons.chevron_right),
       onPressed:entries.length<2?null:(){
         if(pager.hasClients)pager.animateToPage((selected+1)%entries.length,
           duration:const Duration(milliseconds:280),curve:Curves.easeOut);
       }),
   ]),
  ]);
 });}
}
class CinemaGenres extends StatefulWidget {
 final ValueChanged<int> onSelect;
 const CinemaGenres({super.key,required this.onSelect});
 @override State<CinemaGenres> createState()=>_CinemaGenresState();
}
class _CinemaGenresState extends State<CinemaGenres> {
 final ScrollController _genreScroll=ScrollController();
 @override void dispose(){_genreScroll.dispose();super.dispose();}
 void _moveGenre(double amount) {
   if(!_genreScroll.hasClients)return;
   final target=(_genreScroll.offset+amount).clamp(
     0.0,_genreScroll.position.maxScrollExtent);
   _genreScroll.animateTo(target,
     duration:const Duration(milliseconds:280),curve:Curves.easeOut);
 }

 static Future<List<MapEntry<int,String>>>? _cachedGenres;
 static void invalidate() { _cachedGenres = null; }
 late final Future<List<MapEntry<int,String>>> genres = _cachedGenres ??= _loadGenres();
 static Future<List<MapEntry<int,String>>> _loadGenres() async =>
     (await CatalogQueryIndex.load()).availableGenres;
 @override Widget build(BuildContext context)=>FutureBuilder<List<MapEntry<int,String>>>(
  future:genres,builder:(context,s) {
   final data=s.data??const <MapEntry<int,String>>[];
   return Padding(padding:const EdgeInsets.only(top:22,bottom:4),child:Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
     Row(children:[
       const Expanded(child:Padding(padding:EdgeInsets.symmetric(horizontal:16),
         child:Text('JELAJAHI GENRE',
           style:TextStyle(letterSpacing:1.6,fontSize:11,color:Colors.white70,fontWeight:FontWeight.w700)))),
       if(Platform.isWindows)...[
         IconButton(tooltip:'Genre sebelumnya',onPressed:()=>_moveGenre(-320),
           icon:const Icon(Icons.chevron_left)),
         IconButton(tooltip:'Genre berikutnya',onPressed:()=>_moveGenre(320),
           icon:const Icon(Icons.chevron_right)),
       ],
     ]),
     const SizedBox(height:12),
     if(s.hasError) const Padding(padding:EdgeInsets.symmetric(horizontal:16),child:Text('Genre katalog belum tersedia.'))
     else if(!s.hasData) const SizedBox(height:77,child:Center(child:CircularProgressIndicator()))
     else SizedBox(height:77,child:ScrollConfiguration(behavior:const FilmstreamDesktopDragBehavior(),child:ListView.separated(
      controller:_genreScroll,
      key:const PageStorageKey('catalog-genre-list'),scrollDirection:Axis.horizontal,
      padding:const EdgeInsets.symmetric(horizontal:16),itemCount:data.length,
      separatorBuilder:(_,__)=>const SizedBox(width:14),
      itemBuilder:(context,i) {
       final g=data[i];
       return InkWell(onTap:()=>widget.onSelect(g.key),borderRadius:BorderRadius.circular(12),
        child:SizedBox(width:88,child:Column(children:[
         Icon(FilmStreamIcons.genre(g.key),size:29,color:const Color(0xffe5aa55)),
         const SizedBox(height:8),
         Text(g.value,maxLines:2,textAlign:TextAlign.center,overflow:TextOverflow.ellipsis,
          style:const TextStyle(fontSize:11,color:Colors.white70)),
        ])));
      })))
    ]));
  });
}
// Fast catalog tiles keep TMDB artwork authoritative where available.
// The initial movie is shown immediately; the optional network lookup only
// upgrades the poster after validating the title/year against the catalog.
class CatalogPosterTile extends StatefulWidget {
  final Movie movie;
  final ValueChanged<Movie> onTap;
  const CatalogPosterTile({super.key,required this.movie,required this.onTap});
  @override State<CatalogPosterTile> createState()=>_CatalogPosterTileState();
}
class _CatalogPosterTileState extends State<CatalogPosterTile> {
  late Future<Movie?> posterFuture;
  @override void initState(){
    super.initState();
    posterFuture=LocalCatalogMetadata.catalogPosterUpgrade(widget.movie);
  }
  @override void didUpdateWidget(covariant CatalogPosterTile old){
    super.didUpdateWidget(old);
    if(old.movie.sourceUrl!=widget.movie.sourceUrl){
      posterFuture=LocalCatalogMetadata.catalogPosterUpgrade(widget.movie);
    }
  }
  @override Widget build(BuildContext context)=>FutureBuilder<Movie?>(
    future:posterFuture,
    builder:(context,snapshot){
      final resolved=snapshot.data;
      final movie=resolved!=null && resolved.poster.isNotEmpty
        ?resolved:widget.movie;
      return MovieTile(
        movie:movie,
        fallbackPoster: movie.poster!=widget.movie.poster
          ?widget.movie.poster:null,
        onTap:widget.onTap,
      );
    });
}

class MovieTile extends StatelessWidget {
 final Movie movie;
 final String? fallbackPoster;
 final ValueChanged<Movie> onTap;
 const MovieTile({super.key,required this.movie,required this.onTap,
   this.fallbackPoster});
 @override Widget build(BuildContext context)=>InkWell(
  borderRadius:BorderRadius.circular(16),onTap:()=>onTap(movie),
  child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
   Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(16),child:Stack(fit:StackFit.expand,children:[
    // Keep the catalog artwork in place until the official TMDB image
    // actually has a decoded frame. Then fade in the new poster smoothly,
    // without a spinner, a blank flash, or an artificial delay.
    if(fallbackPoster!=null && fallbackPoster!.isNotEmpty)
      Image.network(filmstreamImageUrl(fallbackPoster!),
        fit:BoxFit.cover,gaplessPlayback:true,
        errorBuilder:(_,__,___)=>const ColoredBox(
          color:Color(0xff252a34)))
    else const ColoredBox(color:Color(0xff252a34),
      child:Center(child:Icon(Icons.movie_outlined,size:40))),
    if(movie.poster.isNotEmpty)
      Image.network(filmstreamImageUrl(movie.poster),
        fit:BoxFit.cover,gaplessPlayback:true,
        frameBuilder:(context,child,frame,wasSynchronouslyLoaded){
          if(wasSynchronouslyLoaded)return child;
          return AnimatedOpacity(
            opacity:frame==null?0:1,
            duration:const Duration(milliseconds:300),
            curve:Curves.easeInOut,
            child:child,
          );
        },
        // Leave existing catalog artwork visible if TMDB fails.
        errorBuilder:(_,__,___)=>const SizedBox.shrink()),
    Positioned(top:8,right:8,child:DecoratedBox(decoration:BoxDecoration(color:const Color(0xdd16191f),borderRadius:BorderRadius.circular(7)),child:Padding(padding:const EdgeInsets.symmetric(horizontal:6,vertical:4),child:Row(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.star_rounded,color:Color(0xffe5aa55),size:13),const SizedBox(width:3),Text(movie.rating.toStringAsFixed(1),style:const TextStyle(fontSize:11,fontWeight:FontWeight.bold))])))),
   ]))),
   const SizedBox(height:8),
   Text(movie.title,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:14)),
   const SizedBox(height:3),
   Text('${movie.type=='tv'?'Series':'Film'}  ·  ${movie.year}',style:const TextStyle(color:Colors.white60,fontSize:11)),
  ]));
}
// Simpan request katalog saat widget direbuild, bukan mengambil ulang pada setiap scroll.
class MovieRail extends StatefulWidget {
 final String title,endpoint,type; final ValueChanged<Movie> onTap; final VoidCallback onSeeAll;
 const MovieRail({super.key,required this.title,required this.endpoint,required this.type,required this.onTap,required this.onSeeAll});
 @override State<MovieRail> createState()=>_MovieRailState();
}
class _MovieRailState extends State<MovieRail> with AutomaticKeepAliveClientMixin<MovieRail> {
 final ScrollController _railScroll = ScrollController();
 void _scrollRail(double delta) {
   if(!_railScroll.hasClients) return;
   final next = (_railScroll.offset + delta).clamp(
     0.0, _railScroll.position.maxScrollExtent);
   _railScroll.animateTo(next,
     duration:const Duration(milliseconds:300),curve:Curves.easeOut);
 }
 @override void dispose(){_railScroll.dispose();super.dispose();}
 @override bool get wantKeepAlive => true;
 late Future<List<Movie>> request;
 @override void initState(){super.initState();request=Tmdb.rail(widget.endpoint,widget.type);}
 @override void didUpdateWidget(covariant MovieRail old){super.didUpdateWidget(old);if(old.endpoint!=widget.endpoint||old.type!=widget.type){request=Tmdb.rail(widget.endpoint,widget.type);}}
 @override Widget build(BuildContext context){super.build(context);return FutureBuilder<List<Movie>>(future:request,builder:(context,s)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Padding(padding:const EdgeInsets.fromLTRB(16,18,12,12),child:Row(children:[Expanded(child:Text(widget.title,style:const TextStyle(fontSize:19,fontWeight:FontWeight.w700))),if(Platform.isWindows)...[
 IconButton(tooltip:'Geser ${widget.title} ke kiri',
   onPressed:()=>_scrollRail(-500),icon:const Icon(Icons.chevron_left)),
 IconButton(tooltip:'Geser ${widget.title} ke kanan',
   onPressed:()=>_scrollRail(500),icon:const Icon(Icons.chevron_right)),
],
TextButton(onPressed:widget.onSeeAll,child:const Row(mainAxisSize:MainAxisSize.min,children:[Text('Lihat Lainnya',style:TextStyle(fontSize:12,fontWeight:FontWeight.w600)),SizedBox(width:2),Icon(Icons.chevron_right,size:17)]))])),if(s.hasError)Padding(padding:const EdgeInsets.all(16),child:Text('${s.error}')) else if(s.hasData && s.data!.isEmpty)
  const Padding(padding:EdgeInsets.symmetric(horizontal:16,vertical:10),
    child:Text('Belum ada judul yang cocok di katalog.',
      style:TextStyle(color:Colors.white60,fontSize:13)))
 else SizedBox(height:267,child:!s.hasData?const Center(child:CircularProgressIndicator()):ListView.builder(controller:_railScroll,key:PageStorageKey('rail:${widget.endpoint}'),scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:12),itemCount:s.data!.length,itemBuilder:(context,i)=>SizedBox(width:153,child:Padding(padding:const EdgeInsets.symmetric(horizontal:4),child:CatalogPosterTile(key:ValueKey('rail-poster:${s.data![i].sourceUrl}'),movie:s.data![i],onTap:widget.onTap)))))]));}
}
class LastWatchedRail extends StatelessWidget {
 const LastWatchedRail({super.key});
 void _open(BuildContext context, WatchEntry e) => openWatchDetail(context,e);
 @override Widget build(BuildContext context)=>ValueListenableBuilder<List<WatchEntry>>(valueListenable:WatchStore.entries,builder:(context,history,_) {
   // Beranda menampilkan satu kartu per judul (episode terbaru saja).
   // Entri lama dari sekadar membuka detail tanpa progres tidak dihitung tontonan.
   final seen = <String>{};
   final recent = history.where((e) => e.url.isNotEmpty && (e.positionMs > 0 || e.completed || (Platform.isWindows && e.subtitle=='__webview__')))
       .where((e) => seen.add('${e.type}:${e.tmdbId > 0 ? e.tmdbId : e.title}'))
       .take(12).toList();
   if(recent.isEmpty)return const SizedBox.shrink();
   return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
     Padding(padding:const EdgeInsets.fromLTRB(16,18,12,10),child:Row(children:[Expanded(child:Text(Platform.isWindows?'Riwayat Dibuka / Ditonton':'Terakhir Ditonton',style:const TextStyle(fontSize:22,fontWeight:FontWeight.bold))),TextButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const HistoryPage())),child:const Text('Lihat Lainnya  ›'))])),
     SizedBox(height:187,child:ListView.separated(key:const PageStorageKey('last-watched-rail'),scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:16),itemCount:recent.length,separatorBuilder:(_,__)=>const SizedBox(width:12),itemBuilder:(context,i){
       final e=recent[i];return SizedBox(width:176,child:InkWell(borderRadius:BorderRadius.circular(12),onTap:()=>_open(context,e),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
         ClipRRect(borderRadius:BorderRadius.circular(10),child:Stack(children:[
           SizedBox(height:106,width:176,child:e.poster.isEmpty?const ColoredBox(color:Color(0xff303038),child:Icon(Icons.play_circle_outline)):Image.network(filmstreamImageUrl(e.poster),fit:BoxFit.cover,gaplessPlayback:true,errorBuilder:(_,__,___)=>const ColoredBox(color:Color(0xff303038),child:Icon(Icons.movie)))),
           Positioned(left:7,bottom:9,child:Container(padding:const EdgeInsets.symmetric(horizontal:5,vertical:3),color:Colors.black54,child:Text(e.type=='tv'?'S${e.season} · Eps ${e.episode}':'Film',style:const TextStyle(fontWeight:FontWeight.bold,fontSize:12)))),
           Positioned(left:0,right:0,bottom:0,child:LinearProgressIndicator(minHeight:4,value:e.progress,backgroundColor:Colors.white24,color:const Color(0xffe64653))),
         ])),const SizedBox(height:7),Text(e.title,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:13,fontWeight:FontWeight.w600))
       ])));
     }))
   ]);
 });
}

const catalogPageSize = 20;

// A partially fetched filter batch cannot be offered as a navigable page.
// Only the final exhausted page is allowed to have fewer than 20 titles.
int completedFilterPages(int count, bool hasMore) {
  if(count<=0)return 0;
  final full=count ~/ catalogPageSize;
  return full+(!hasMore && count % catalogPageSize != 0 ? 1 : 0);
}

// A compact numbered pager shared by Film, Series, Filter, Search and
// "Lihat Lainnya". An unknown total must not be shown as a made-up count.
class CatalogPageControls extends StatelessWidget {
  final int page, maxPage;
  final int? displayedMaxPage;
  final bool busy, hasNext;
  final ValueChanged<int> onSelect;
  const CatalogPageControls({super.key,required this.page,required this.maxPage,
    required this.busy,required this.hasNext,required this.onSelect,
    this.displayedMaxPage});

  Future<void> _jump(BuildContext context) async {
    var typed='$page';
    final jumpLimit=displayedMaxPage??maxPage;
    final chosen=await showDialog<int>(context:context,builder:(dialogContext)=>
      AlertDialog(title:const Text('Lompat ke halaman'),
        content:TextFormField(initialValue:typed,
          onChanged:(value)=>typed=value,
          keyboardType:TextInputType.number,
          autofocus:true,decoration:InputDecoration(
            labelText:'Nomor halaman (1–$jumpLimit)')),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialogContext),
            child:const Text('Batal')),
          FilledButton(onPressed:(){
            final n=int.tryParse(typed.trim());
            if(n==null || n<1 || n>jumpLimit)return;
            Navigator.pop(dialogContext,n);
          },child:const Text('Buka')),
        ]));
    if(chosen!=null && chosen!=page)onSelect(chosen);
  }

  @override Widget build(BuildContext context) {
    final first=page>1 ? page-1 : 1;
    final last=(first+2).clamp(1,displayedMaxPage??maxPage).toInt();
    return Padding(
      padding:const EdgeInsets.fromLTRB(12,16,12,28),
      child:Column(mainAxisSize:MainAxisSize.min,children:[
        Row(mainAxisAlignment:MainAxisAlignment.center,children:[
          IconButton(
            tooltip:'Halaman sebelumnya',
            onPressed:busy||page==1?null:()=>onSelect(page-1),
            icon:const Icon(Icons.chevron_left_rounded)),
          for(var n=first;n<=last;n++)
            Padding(
              padding:const EdgeInsets.symmetric(horizontal:2),
              child:n==page
                ?FilledButton(onPressed:null,
                   style:FilledButton.styleFrom(
                     minimumSize:const Size(42,40),
                     padding:const EdgeInsets.symmetric(horizontal:8)),
                   child:Text('$n'))
                :OutlinedButton(
                   onPressed:busy?null:()=>onSelect(n),
                   style:OutlinedButton.styleFrom(
                     minimumSize:const Size(42,40),
                     padding:const EdgeInsets.symmetric(horizontal:8)),
                   child:Text('$n'))),
          IconButton(
            tooltip:'Halaman berikutnya',
            onPressed:busy||!hasNext||page>=maxPage
              ?null:()=>onSelect(page+1),
            icon:const Icon(Icons.chevron_right_rounded)),
        ]),
        const SizedBox(height:4),
        Row(mainAxisAlignment:MainAxisAlignment.center,children:[
          Text('Halaman $page',style:const TextStyle(
            color:Colors.white70,fontSize:13)),
          const SizedBox(width:12),
          TextButton.icon(onPressed:busy?null:()=>_jump(context),
            icon:const Icon(Icons.low_priority,size:16),
            label:const Text('Lompat',style:TextStyle(fontSize:13))),
        ]),
      ]),
    );
  }
}

class PagedGrid extends StatefulWidget {
  final String title,endpoint,type;
  final Map<String,String> params;
  final ValueChanged<Movie> onTap;
  const PagedGrid({super.key,required this.title,required this.endpoint,
    required this.type,required this.onTap,this.params=const {}});
  @override State<PagedGrid> createState()=>_PagedGridState();
}
class _PagedGridState extends State<PagedGrid> {
  // Remember page numbers across tab switches and detail navigation.
  // Only the page number is remembered; movie widgets stay bounded to 20.
  static final Map<String,int> _lastViewedPages={};
  String get _pageKey {
    final keys=widget.params.keys.toList()..sort();
    return '${widget.endpoint}|${widget.type}|${keys.map((k)=>'$k=${widget.params[k]}').join('&')}';
  }
  final ScrollController scroll=ScrollController();
  List<Movie> items=const [];
  int page=1, requestId=0;
  bool busy=false,hasNext=true;
  String error='';
  // Only show observed/verified bounds, not arbitrary TMDB caps.
  int maxPage=1;
  bool _pageLimitKnown=false;

  bool get _isRankedCollection => widget.endpoint.startsWith('trending/') ||
      widget.endpoint.startsWith('discover/') ||
      widget.endpoint.endsWith('/popular') ||
      widget.endpoint.endsWith('/top_rated') ||
      widget.endpoint=='home/family' ||
      widget.endpoint=='home/recommended';

  Future<int?> _catalogPageCount() async {
    if(CatalogQueryIndex.handles(widget.endpoint)){
     final index=await CatalogQueryIndex.load();
     return index.select(widget.endpoint, page:1,
       type:widget.type,params:widget.params).pages;
   }
   final endpoint=widget.endpoint;
    if(!endpoint.startsWith('catalog/') &&
        endpoint!='search/multi')return null;
    final source=await FilmStreamCatalog.load();
    final media=endpoint=='search/multi'?null:
        endpoint=='home/latest' || endpoint=='catalog/movie'?'movie':
        endpoint=='catalog/tv'?'tv':
        (widget.type=='all'?null:widget.type);
    final term=endpoint=='search/multi'
        ?(widget.params['query']??'').trim().toLowerCase():'';
    final count=source.where((e)=>(media==null||e.type==media) &&
        (term.isEmpty||e.title.toLowerCase().contains(term))).length;
    return (count+catalogPageSize-1)~/catalogPageSize;
  }

  @override void initState(){
    super.initState();
    _fetch(_lastViewedPages[_pageKey] ?? 1);
  }
  @override void didUpdateWidget(covariant PagedGrid old){
    super.didUpdateWidget(old);
    if(old.endpoint!=widget.endpoint||old.type!=widget.type||
       !mapEquals(old.params,widget.params)){
      _pageLimitKnown=false;
      _fetch(1);
    }
  }
  @override void dispose(){requestId++;scroll.dispose();super.dispose();}

  Future<void> _fetch(int target) async {
    if(target<1||(_pageLimitKnown&&target>maxPage))return;
    final token=++requestId;
    setState((){busy=true;error='';});
    try {
      final rankPage=_isRankedCollection;
      final exactPages=await _catalogPageCount();
      if(!mounted||token!=requestId)return;
      if(exactPages!=null && target>exactPages && target>1){
        setState((){busy=false;maxPage=exactPages;_pageLimitKnown=true;hasNext=false;});
        return;
      }
      var next=await Tmdb.list(widget.endpoint,page:target,
        params:{...widget.params,if(rankPage)'fill_page':'true'},
        type:widget.type);
      if(next.isEmpty && target==1 && widget.endpoint=='search/multi'){
        final query=(widget.params['query']??'').toLowerCase();
        final terms=query.split(RegExp(r'[^a-z0-9]+'))
          .where((w)=>w.length>=4).toList();
        if(terms.length>=3){
          final candidates=await Tmdb.list('search/multi',page:1,
            params:{'query':terms.first,'include_adult':'false'},
            type:widget.type);
          next=candidates.where((m)=>
            terms.where((word)=>m.title.toLowerCase().contains(word)).length>=2
          ).toList();
        }
      }
      if(!mounted||token!=requestId)return;
      // An empty page after the first is the end, NOT another visible page.
      if(next.isEmpty && target>1){
        setState((){busy=false;hasNext=false;});
        return;
      }
      final seen=<String>{};
      final distinct=next.where((m)=>
          seen.add(m.sourceUrl.isNotEmpty?m.sourceUrl:'${m.type}:${m.id}'))
        .take(catalogPageSize).toList();
      // Verify the next ranked page before showing its number.
      bool verifiedNext=false;
      if(exactPages==null && target<(_isRankedCollection?100:500) &&
          distinct.isNotEmpty){
        final probe=await Tmdb.list(widget.endpoint,page:target+1,
          params:{...widget.params,if(rankPage)'fill_page':'true'},
          type:widget.type);
        if(!mounted||token!=requestId)return;
        verifiedNext=probe.isNotEmpty;
      }
      setState((){
        maxPage=(exactPages!=null && exactPages>0)
            ?exactPages:(target+(verifiedNext?1:0));
        _pageLimitKnown=true;
        items=distinct;page=target;
        _lastViewedPages[_pageKey]=target;
        if(_lastViewedPages.length>100){
          _lastViewedPages.remove(_lastViewedPages.keys.first);
        }
        hasNext=target<maxPage;
        busy=false;error='';
      });
      if(scroll.hasClients)scroll.jumpTo(0);
    }catch(_){
      if(mounted&&token==requestId)setState((){
        busy=false;error='Gagal memuat halaman. Coba lagi.';
      });
    }
  }
  @override Widget build(BuildContext context)=>CustomScrollView(
    controller:scroll,
    slivers:[
      SliverToBoxAdapter(child:Padding(
        padding:const EdgeInsets.fromLTRB(16,12,16,18),
        child:Text(widget.title,style:const TextStyle(
          fontSize:21,fontWeight:FontWeight.bold)))),
      if(busy)const SliverFillRemaining(
        hasScrollBody:false,
        child:Center(child:CircularProgressIndicator()))
      else if(error.isNotEmpty)SliverFillRemaining(
        hasScrollBody:false,
        child:Center(child:FilledButton(
          onPressed:()=>_fetch(page),child:Text(error))))
      else if(items.isEmpty)const SliverFillRemaining(
        hasScrollBody:false,child:Center(child:Text('Tidak ditemukan')))
      else ...[
        SliverPadding(padding:const EdgeInsets.all(12),
          sliver:SliverGrid(
            gridDelegate:filmstreamGridDelegate(context),
            delegate:SliverChildBuilderDelegate(
              // One smooth poster behavior for Film, Series, Search,
              // and every Beranda "Lihat Lainnya" collection. For TMDB
              // result lists the official poster is already known, so the
              // wrapper performs no extra lookup.
              (context,i)=>CatalogPosterTile(
                key:ValueKey(items[i].sourceUrl.isNotEmpty
                    ?items[i].sourceUrl:'${items[i].type}:${items[i].id}'),
                movie:items[i],onTap:widget.onTap),
              childCount:items.length))),
        SliverToBoxAdapter(child:CatalogPageControls(
          page:page,maxPage:maxPage,
          hasNext:hasNext,busy:busy,onSelect:_fetch)),
      ],
    ]);
}

// Adapter percobaan untuk API metadata LK21 tidak resmi. Tidak mengekstrak stream.
// Endpoint harus berupa server HTTPS yang Anda kelola/diizinkan untuk diakses.

class AutoSourceButton extends StatefulWidget {
 final Movie movie; final int season, episode;
 const AutoSourceButton({super.key,required this.movie,this.season=0,this.episode=0});
 @override State<AutoSourceButton> createState()=>_AutoSourceButtonState();
}
class _AutoSourceButtonState extends State<AutoSourceButton> {
 bool busy=false;
 String status='';
 Future<void> findAndPlay() async {
  if(busy)return;
  setState((){busy=true;status='Mencari sumber pemutaran...';});
  try {
   final result=await PlaybackSourceManager.resolve(tmdbId:widget.movie.id,type:widget.movie.type,season:widget.season,episode:widget.episode);
   if(!mounted)return;
   if(result==null){setState(()=>status='Video untuk judul ini belum tersedia di sumber yang terhubung.');return;}
   setState(()=>status='Sumber ditemukan: ${result.provider}');
   final key=widget.movie.type=='tv'?'tv:${widget.movie.id}:${widget.season}:${widget.episode}':'movie:${widget.movie.id}';
   Navigator.of(context).push(MaterialPageRoute(builder:(_)=>PlayerPage(url:result.url,subtitle:result.subtitleUrl,title:widget.movie.title,historyKey:key,poster:widget.movie.poster,type:widget.movie.type,tmdbId:widget.movie.id,season:widget.season,episode:widget.episode)));
  }catch(e){if(mounted)setState(()=>status='Tidak dapat mencari sumber: $e');}
  finally{if(mounted)setState(()=>busy=false);}
 }
 @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
  FilledButton.icon(onPressed:busy?null:findAndPlay,icon:busy?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.play_circle_fill),label:Text(widget.movie.type=='tv'?'Tonton Episode ${widget.episode} Otomatis':'Tonton Otomatis')),
  if(status.isNotEmpty)Padding(padding:const EdgeInsets.only(top:8,bottom:8),child:Text(status,style:const TextStyle(color:Colors.white70,fontSize:12)))
 ]);
}

const lk21ApiBase = String.fromEnvironment('LK21_API_BASE');
class SourceCandidate {
 final String title, pageUrl, year;
 const SourceCandidate(this.title,this.pageUrl,this.year);
}
class ExternalMetadataApi {
 static Future<List<SourceCandidate>> search(String title) async {
  if(lk21ApiBase.isEmpty) throw StateError('LK21_API_BASE belum diatur dalam GitHub Actions. Katalog TMDB tetap dapat dipakai.');
  final base=Uri.tryParse(lk21ApiBase);
  if(base==null||base.scheme!='https'||base.host.isEmpty||base.userInfo.isNotEmpty||base.query.isNotEmpty||base.fragment.isNotEmpty) throw StateError('Alamat API wajib berupa basis URL HTTPS yang valid.');
  final uri=base.replace(path:'${base.path.endsWith('/')?base.path.substring(0,base.path.length-1):base.path}/search/${Uri.encodeComponent(title)}');
  final response=await http.get(uri,headers:{'Accept':'application/json'}).timeout(const Duration(seconds:12));
  if(response.statusCode!=200) throw StateError('API sumber mengembalikan HTTP ${response.statusCode}.');
  final decoded=jsonDecode(response.body);
  // API pihak ketiga bisa berubah skemanya; toleransi bentuk array umum.
  final dynamic items=decoded is List?decoded:decoded is Map?(decoded['results']??decoded['data']??decoded['movies']):null;
  if(items is! List) throw const FormatException('Format respons pencarian API tidak dikenali.');
  return items.whereType<Map>().map((item){
   final title=(item['title']??item['name']??'').toString().trim();
   final page=(item['url']??item['link']??item['pageUrl']??'').toString().trim();
   final year=(item['year']??item['release_year']??'').toString().trim();
   final u=Uri.tryParse(page);
   // Hanya tampilkan tautan halaman sumber HTTPS, bukan field streaming/embed.
   if(title.isEmpty||u==null||u.scheme!='https'||u.host.isEmpty||u.userInfo.isNotEmpty)return null;
   return SourceCandidate(title,page,year);
  }).whereType<SourceCandidate>().take(15).toList();
 }
}
// Read-only archive of manually inspected source metadata. Never treats an embed as a video file.
class SourceCatalogApi {
 static Future<Map<String,dynamic>> lookup(Movie movie) async {
  if(lk21ApiBase.isEmpty) throw StateError('LK21_API_BASE belum dikonfigurasi.');
  final base=Uri.tryParse(lk21ApiBase);
  if(base==null||base.scheme!='https'||base.host.isEmpty||base.userInfo.isNotEmpty||base.query.isNotEmpty||base.fragment.isNotEmpty) throw StateError('Basis URL API tidak valid.');
  final prefix=base.path.endsWith('/')?base.path.substring(0,base.path.length-1):base.path;
  final uri=base.replace(path:'$prefix/source-manager/catalog',queryParameters:{'tmdb_id':'${movie.id}','media_type':movie.type});
  final response=await http.get(uri,headers:{'Accept':'application/json'}).timeout(const Duration(seconds:15));
  if(response.statusCode!=200) throw StateError('Katalog sumber HTTP ${response.statusCode}.');
  final decoded=jsonDecode(response.body);
  if(decoded is! Map<String,dynamic>) throw const FormatException('Format katalog sumber tidak dikenali.');
  return decoded;
 }
}
class ExternalSourcePage extends StatefulWidget {
 final Movie movie;
 const ExternalSourcePage({super.key,required this.movie});
 @override State<ExternalSourcePage> createState()=>_ExternalSourcePageState();
}
class _ExternalSourcePageState extends State<ExternalSourcePage> {
 late Future<Map<String,dynamic>> result;
 @override void initState(){super.initState();result=SourceCatalogApi.lookup(widget.movie);}
 void retry(){setState(()=>result=SourceCatalogApi.lookup(widget.movie));}
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Katalog sumber terinspeksi')),body:FutureBuilder<Map<String,dynamic>>(future:result,builder:(context,s){
  if(s.connectionState!=ConnectionState.done)return const Center(child:CircularProgressIndicator());
  if(s.hasError)return Center(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,children:[Text('Gagal membaca katalog sumber: ${s.error}',textAlign:TextAlign.center),const SizedBox(height:12),FilledButton(onPressed:retry,child:const Text('Coba lagi'))])));
  final data=s.data??{};
  if(data['found']!=true)return Center(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.inventory_2_outlined,size:48),const SizedBox(height:14),Text(widget.movie.title,textAlign:TextAlign.center,style:Theme.of(context).textTheme.titleLarge),const SizedBox(height:6),Text('TMDB ID: ${widget.movie.id} • ${widget.movie.type}',style:const TextStyle(color:Colors.white70)),const SizedBox(height:14),const Text('Belum diinspeksi. Katalog sumber untuk judul ini belum memiliki catatan. Ini bukan berarti film tidak ada atau tidak tersedia di layanan lain.',textAlign:TextAlign.center),const SizedBox(height:14),OutlinedButton.icon(onPressed:retry,icon:const Icon(Icons.refresh),label:const Text('Periksa katalog lagi'))])));
  final sources=(data['sources'] is List?(data['sources'] as List):const []).whereType<Map>().toList();
  return ListView(padding:const EdgeInsets.all(16),children:[
   Text((data['title']??widget.movie.title).toString(),style:Theme.of(context).textTheme.titleLarge),
   const SizedBox(height:8),
   Text('Arsip inspeksi • ${sources.length} sumber tercatat',style:const TextStyle(color:Colors.white70)),
   const SizedBox(height:12),
   const Text('Informasi dari HTML yang diperiksa sebelumnya, bukan hasil pengecekan live. Alamat embed belum terverifikasi dan bukan tautan video MP4/HLS.',style:TextStyle(color:Colors.white70)),
   const SizedBox(height:16),
   ...sources.map((source){
    final name=(source['name']??'Sumber').toString();
    final kind=(source['type']??'unknown').toString();
    final status=(source['status']??'unverified').toString();
    return Card(child:ListTile(leading:const Icon(Icons.dns_outlined),title:Text(name),subtitle:Text('$kind • $status • Tidak siap untuk Native Player'),trailing:const Icon(Icons.info_outline)));
   }),
   const SizedBox(height:12),
   const Text('Tonton Otomatis hanya memakai sumber video langsung yang telah dikonfigurasi terpisah melalui /resolve.',style:TextStyle(color:Colors.white70,fontSize:12)),
  ]);
 }));
}
// Opens the known film page, or a catalogued page, or the site's normal search UI.
Future<Uri> resolveSourcePage(Movie movie) async {
  final saved=LocalCatalogMetadata.sourceFor(movie);
  if(saved!=null)return movie.type == 'tv' ? SourceDomainConfig.seriesPage(saved) : saved;
  // Prefer exact series detail permalink from the bundled catalog, even when
  // the selected TMDB movie object did not preserve its sourceUrl.
  if(movie.type=='tv'){
    final candidates=await FilmStreamCatalog.find(movie.title,type:'tv',limit:100);
    final matches=candidates.where((entry)=>
      entry.title.trim().toLowerCase()==movie.title.trim().toLowerCase() &&
      (entry.year.toString()==movie.year || entry.year==0)).toList();
    if(matches.length==1){
      final uri=Uri.tryParse(matches.single.url);
      if(uri!=null && uri.scheme=='https' &&
         const {'tv9.nontondrama.my','tv.nontondrama.vip','tv.lk21online.de'}.contains(uri.host)){
        return SourceDomainConfig.seriesPage(uri);
      }
    }
  }
  Uri? page;
  // A previously inspected, exact title match. No guessed embed URLs.
  if (movie.type == 'movie' && movie.id == 762509) {
    page = Uri.parse('https://tv12.lk21official.cc/mufasa-the-lion-king-2024');
  } else {
    try {
      final record = await SourceCatalogApi.lookup(movie);
      if (record['found'] == true && record['page_url'] is String) {
        final candidate = Uri.tryParse(record['page_url'] as String);
        if (candidate != null && candidate.scheme == 'https' &&
            candidate.host.endsWith('lk21official.cc')) page = candidate;
      }
    } catch (_) { /* Site search is a deliberate fallback, not a playback success. */ }
  }
  // Exact episode URL supplied by the user and checked against their browser screenshot.
  // Other series search the *show title*, not a phrase with season/episode,
  // because the search site indexes a show landing page first.
  if (movie.type == 'tv') {
    page = null;
    // Known show landing URL from the user's browser; resolve any selected
    // season/episode from links on that page instead of hardcoding S1E1.
    if (movie.title.trim().toLowerCase() == 'the mentalist') {
      page = Uri.parse('https://tv9.nontondrama.my/the-mentalist-2008');
    }
  }
  page ??= Uri.https(
    movie.type == 'tv' ? 'tv.nontondrama.vip' : 'tv12.lk21official.cc',
    '/search', {'s': movie.title});
  return movie.type == 'tv' ? SourceDomainConfig.seriesPage(page) : page;
}

Future<void> recordWebOpen(Movie movie, Uri url, {int season = 0, int episode = 0}) async {
  if (url.scheme != 'https') return;
  final key = movie.type == 'tv' ? 'tv:${movie.id}:$season:$episode' : 'movie:${movie.id}';
  final prior = WatchStore.find(key);
  await WatchStore.save(WatchEntry(key:key,title:movie.title,poster:movie.poster,
    type:movie.type,url:url.toString(),subtitle:'__webview__',tmdbId:movie.id,
    season:season,episode:episode,positionMs:prior?.positionMs ?? 0,durationMs:prior?.durationMs ?? 0,
    updatedAt:DateTime.now().millisecondsSinceEpoch,completed:prior?.completed ?? false));
}

// Kebijakan pilihan pengguna: sentuhan pertama pada area player dianggap sudah ditonton.
// Ini adalah status berdasarkan interaksi, BUKAN verifikasi durasi/tamat video.
Future<void> recordPlayerTap(Movie movie, Uri url, {int season = 0, int episode = 0}) async {
  if (url.scheme != 'https') return;
  final key = movie.type == 'tv' ? 'tv:${movie.id}:$season:$episode' : 'movie:${movie.id}';
  final prior = WatchStore.find(key);
  final duration = prior != null && prior.durationMs > 0 ? prior.durationMs : 1000;
  await WatchStore.save(WatchEntry(
    key:key, title:movie.title, poster:movie.poster, type:movie.type,
    url:url.toString(), subtitle:'__webview__', tmdbId:movie.id,
    season:season, episode:episode, positionMs:duration, durationMs:duration,
    updatedAt:DateTime.now().millisecondsSinceEpoch, completed:true,
  ));
}

Future<void> recordWebProgress(Movie movie, Uri page, int positionMs, int durationMs, bool ended, {int season = 0, int episode = 0}) async {
  if (page.scheme != 'https' || durationMs <= 0 || (positionMs < 100 && !ended)) return;
  final key = movie.type == 'tv' ? 'tv:${movie.id}:$season:$episode' : 'movie:${movie.id}';
  final prior = WatchStore.find(key);
  final completed = (prior?.completed ?? false) || ended || positionMs / durationMs >= .90;
  await WatchStore.save(WatchEntry(key:key,title:movie.title,poster:movie.poster,type:movie.type,
    url:page.toString(),subtitle:'__webview__',tmdbId:movie.id,season:season,episode:episode,
    positionMs:completed ? durationMs : positionMs,durationMs:durationMs,
    updatedAt:DateTime.now().millisecondsSinceEpoch,completed:completed));
}

Widget inlineSource(Movie movie, {int season = 0, int episode = 0, Future<Uri>? resolved, VoidCallback? onFullscreenExit, ValueChanged<String>? onSynopsisFound, ValueChanged<List<String>>? onGenresFound}) =>
  FutureBuilder<Uri>(
    future: resolved ?? resolveSourcePage(movie),
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const SizedBox(height: 340,
        child: ColoredBox(color: Color(0xff101014), child: Center(child: CircularProgressIndicator())));
      if (Platform.isWindows) {
        return WindowsSourcePlayer(
          key: ValueKey('windows:${movie.type}:${movie.id}:$season:$episode'),
          title: movie.title,
          url: snapshot.data!,
          embedded: true,
          year: movie.year == '—' ? '' : movie.year,
          genres: movie.genres.map((id) => _FilmstreamFilterState.genres[id]).whereType<String>().toList(),
          tmdbId: movie.id,
          mediaType: movie.type,
          onSynopsisFound: onSynopsisFound,
          onGenresFound: onGenresFound,
        );
      }
      return WebSourcePage(
        key: ValueKey('${movie.type}:${movie.id}:$season:$episode'),
        title: movie.title, url: snapshot.data!, focused: true, embedded: true,
        tmdbId: movie.id, mediaType: movie.type, year: movie.year,
        season: season, episode: episode,
        // Jangan mencatat riwayat hanya karena player/halaman detail dimuat.
        // Riwayat dicatat ketika video mengirim posisi pemutaran yang valid.
        onPlayerReady: null,
        onPlayIntent: (page) => recordPlayerTap(movie, page, season:season, episode:episode),
        onVideoProgress: (pos, dur, ended) => recordWebProgress(movie, snapshot.data!, pos, dur, ended, season:season, episode:episode),
        onFullscreenExit: onFullscreenExit, onSynopsisFound: onSynopsisFound);
    },
  );

Future<void> openFocusedFilm(BuildContext context, Movie movie, {int season = 0, int episode = 0}) async {
  final page = await resolveSourcePage(movie);
  if (!context.mounted) return;
  if (Platform.isWindows) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => WindowsSourcePlayer(
      title: movie.title, url: page,
      year: movie.year == '—' ? '' : movie.year,
      genres: movie.genres.map((id) => _FilmstreamFilterState.genres[id]).whereType<String>().toList(),
      tmdbId: movie.id,
      mediaType: movie.type,
    )));
    return;
  }
  Navigator.push(context, MaterialPageRoute(builder: (_) => WebSourcePage(
    title: movie.title, url: page, focused: true, tmdbId: movie.id,
    mediaType: movie.type, year: movie.year, season: season, episode: episode)));
}

class DetailPage extends StatefulWidget {final Movie movie;final bool isFavorite;final VoidCallback onFavorite; final int? initialSeason,initialEpisode; final Uri? initialPage; const DetailPage({super.key,required this.movie,required this.isFavorite,required this.onFavorite,this.initialSeason,this.initialEpisode,this.initialPage});@override State<DetailPage> createState()=>_DetailPageState();}
class _DetailPageState extends State<DetailPage> {
 Uri? selectedEpisodeUrl;
 int? sourceSeason,sourceEpisode;
 String sourceSynopsis='';
 bool _sourceSynopsisPending=true;
 Timer? _sourceSynopsisTimeout;
 List<String> sourceGenres=const [];
 void _receiveGenres(List<String> names){if(!mounted)return;final clean=names.where((name)=>name.trim().isNotEmpty).toSet().toList();if(clean.join('|')!=sourceGenres.join('|'))setState(()=>sourceGenres=clean);}
 void _receiveSynopsis(String text){final clean=text.trim();if(clean.isEmpty||!mounted)return;_sourceSynopsisTimeout?.cancel();_sourceSynopsisPending=false;final old=sourceSynopsis.trim();if(old.isNotEmpty && old.length>=clean.length && !old.endsWith('...') && !old.endsWith('…'))return;if(clean!=old)setState(()=>sourceSynopsis=clean);}
 final videoUrl=TextEditingController(),subtitleUrl=TextEditingController(),sourcePage=TextEditingController();late bool favorite;late Future<Map<String,dynamic>> details; late Future<Uri> sourceFuture;
 @override void initState(){super.initState();_sourceSynopsisTimeout=Timer(const Duration(seconds:24),(){if(mounted)setState(()=>_sourceSynopsisPending=false);});favorite=widget.isFavorite;details=widget.movie.id>0?Tmdb.bilingualDetail('${widget.movie.type}/${widget.movie.id}'):Future.value(<String,dynamic>{}); sourceFuture=widget.initialPage != null && widget.movie.type=='movie' ? Future.value(widget.initialPage!) : resolveSourcePage(widget.movie); if(widget.movie.type=='tv' && widget.initialSeason!=null && widget.initialEpisode!=null){selectedSeason=widget.initialSeason;playingSeason=widget.initialSeason;playingEpisode=widget.initialEpisode;episodeSourceFuture=widget.initialPage!=null?Future.value(widget.initialPage!):resolveSourcePage(widget.movie);}
   if (Platform.isWindows && widget.movie.type=='movie') {
     sourceFuture.then((url)=>_recordWindowsOpened(url)).catchError((Object _){});
   }
 }
 @override void dispose(){_sourceSynopsisTimeout?.cancel();videoUrl.dispose();subtitleUrl.dispose();sourcePage.dispose();detailScroll.dispose();super.dispose();}
 // Windows WebView2 does not expose reliable cross-origin video progress.
 // Record that a title/episode was opened, without inventing watch position.
 Future<void> _recordWindowsOpened(Uri uri, {int season=0,int episode=0}) async {
   if(!Platform.isWindows || widget.movie.id<=0)return;
   final m=widget.movie;
   final key=m.type=='tv'?'tv:${m.id}:$season:$episode':'movie:${m.id}';
   final old=WatchStore.find(key);
   final entry=WatchEntry(
     key:key, title:m.title, poster:m.poster, type:m.type,
     url:uri.toString(), subtitle:'__webview__', tmdbId:m.id,
     season:season,episode:episode,
     positionMs:old?.positionMs??0,durationMs:old?.durationMs??0,
     updatedAt:DateTime.now().millisecondsSinceEpoch,completed:false,
   );
   await WatchStore.save(entry);
 }
 bool https(String input){final u=Uri.tryParse(input.trim());return u!=null&&u.scheme=='https'&&u.host.isNotEmpty;}

 int? selectedSeason;
 int? playingSeason, playingEpisode;
 Future<Uri>? episodeSourceFuture;
 final Map<int, Future<Map<String, dynamic>>> episodeFutures = {};
 final ScrollController detailScroll = ScrollController();
 Widget _seasonSection(Movie m) {
   return FutureBuilder<Map<String, dynamic>>(
     future: details,
     builder: (context, snapshot) {
       if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
       final seasons = (snapshot.data!['seasons'] as List? ?? [])
           .whereType<Map<String, dynamic>>()
           .where((item) => (item['season_number'] as num? ?? 0) >= 1).toList()
         ..sort((a,b) => ((a['season_number'] as num).toInt()).compareTo((b['season_number'] as num).toInt()));
       if (seasons.isEmpty) return const Text('Daftar season belum tersedia.');
       final active = seasons.any((x) => (x['season_number'] as num).toInt() == selectedSeason)
           ? selectedSeason! : (seasons.first['season_number'] as num).toInt();
       return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
         const SizedBox(height: 24),
         const Text('Pilih Season', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
         const SizedBox(height: 12),
         SizedBox(height: 94, child: ListView.separated(
           scrollDirection: Axis.horizontal,
           itemCount: seasons.length,
           separatorBuilder: (_, __) => const SizedBox(width: 10),
           itemBuilder: (context, i) {
             final item = seasons[i];
             final n = (item['season_number'] as num).toInt();
             return SizedBox(width: 142, child: InkWell(
               borderRadius: BorderRadius.circular(14),
               onTap: () => setState(() => selectedSeason = n),
               child: Container(padding: const EdgeInsets.all(12),
                 decoration: BoxDecoration(
                   borderRadius: BorderRadius.circular(14),
                   border: Border.all(color: active == n ? const Color(0xffffb5b0) : Colors.white24, width: active == n ? 2 : 1),
                   color: active == n ? const Color(0xff422c32) : const Color(0xff24242b)),
                 child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                   Row(children: [Expanded(child: Text('Season $n', style: const TextStyle(fontWeight: FontWeight.bold))),
                     Icon(Icons.chevron_right, size: 19, color: active == n ? const Color(0xffffb5b0) : Colors.white70)]),
                   const SizedBox(height: 6),
                   Text('${item['episode_count'] ?? 0} episode', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                 ])),
             ));
           },
         )),
         const SizedBox(height: 22),
         Text('Episode • Season $active', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
         const SizedBox(height: 8),
         FutureBuilder<Map<String,dynamic>>(
           key: ValueKey('season-${m.id}-$active'),
           future: episodeFutures.putIfAbsent(active, () => Tmdb.bilingualDetail('tv/${m.id}/season/$active')),
           builder: (context, episodeSnapshot) {
             if (episodeSnapshot.hasError) return const Text('Daftar episode gagal dimuat. Pilih season kembali.');
             if (!episodeSnapshot.hasData) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
             final episodes = (episodeSnapshot.data!['episodes'] as List? ?? []).whereType<Map<String,dynamic>>().toList();
             return Column(children: episodes.map<Widget>((episode) {
               final number = (episode['episode_number'] as num? ?? 0).toInt();
               if (number < 1) return const SizedBox.shrink();
               return ValueListenableBuilder<List<WatchEntry>>(valueListenable:WatchStore.entries,
                 builder:(context, history, _) {
                 final key = 'tv:${m.id}:$active:$number';
                 WatchEntry? viewed;
                 for (final h in history) { if (h.key == key) { viewed = h; break; } }
                 final isActive = playingSeason == active && playingEpisode == number;
                 final cardColor = viewed?.completed == true ? const Color(0xff20443a)
                     : isActive || (viewed != null && viewed.durationMs > 0 && viewed.positionMs > 0)
                         ? const Color(0xff263d52)
                         : const Color(0xff24242b);
                 return Card(margin: const EdgeInsets.symmetric(vertical: 5), color: cardColor,
                 child: ListTile(
                   leading: SizedBox(width: 42, child: Center(child: Text('$number', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)))),
                   title: Text((episode['name'] ?? 'Episode $number').toString(), maxLines: 2),
                   subtitle: viewed == null && !isActive ? Text((episode['overview'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis) : null,
                   trailing: Row(mainAxisSize:MainAxisSize.min,children:[
                     const Icon(Icons.play_circle_outline),
                   ]),
                   onTap: () { if (playingSeason != active || playingEpisode != number) {
                       setState(() { playingSeason = active; playingEpisode = number; episodeSourceFuture = resolveSourcePage(m); });
                     }
                     if (detailScroll.hasClients) detailScroll.animateTo(0,duration:const Duration(milliseconds:280),curve:Curves.easeOut);
                   },
                 )); });
             }).toList());
           },
         ),
       ]);
     },
   );
 }
 @override Widget build(BuildContext context) {
   final m = widget.movie;
   return Scaffold(
     appBar: AppBar(title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
       actions: [IconButton(icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
         onPressed: () { widget.onFavorite(); setState(() => favorite = !favorite); })]),
     // Keep the Android WebView outside the scrolling episode list. The same
     // platform view stays mounted while the user scrolls or selects a season.
     body: LayoutBuilder(builder: (context, viewport) {
       // Desktop: YouTube-style player on the left, metadata/episodes on the
       // right. Keep the WebView mounted when the side panel scrolls.
       final wideDesktop = Platform.isWindows && viewport.maxWidth >= 960;
       final playerPane = Column(mainAxisSize:MainAxisSize.min, children: [

       if (m.type == 'movie')
         inlineSource(m, resolved: sourceFuture, onSynopsisFound:_receiveSynopsis, onGenresFound:_receiveGenres, onFullscreenExit: () {
           if (detailScroll.hasClients) detailScroll.jumpTo(0);
         })
       else if (m.type == 'tv' && selectedEpisodeUrl != null)
         inlineSource(m, season:sourceSeason ?? 0, episode:sourceEpisode ?? 0,
           resolved:Future.value(selectedEpisodeUrl!),
           onSynopsisFound:_receiveSynopsis, onGenresFound:_receiveGenres,
           onFullscreenExit:(){
             if(detailScroll.hasClients)detailScroll.jumpTo(0);
           })
       else if (m.type == 'tv')
         Platform.isWindows
           ? LayoutBuilder(builder:(context,limits) {
               final screen=MediaQuery.sizeOf(context);
               final height=screen.width>=960
                 ? (screen.height-146).clamp(330.0,800.0)
                 : (screen.height*.46).clamp(235.0,440.0);
               return SizedBox(width:double.infinity,height:height,
                 child:ClipRRect(borderRadius:BorderRadius.circular(12),
                   child:ColoredBox(color:Colors.black,
                     child:Center(child: m.poster.isNotEmpty
                       ? Image.network(filmstreamImageUrl(m.poster),
                           fit:BoxFit.contain,
                           errorBuilder:(_,__,___)=>const Icon(Icons.movie_outlined,size:72))
                       : const Icon(Icons.movie_outlined,size:72)))));
             })
           : SizedBox(height:215,width:double.infinity,
               child:m.poster.isNotEmpty
                 ? Image.network(filmstreamImageUrl(m.poster),fit:BoxFit.contain,
                     errorBuilder:(_,__,___)=>const Center(child:Icon(Icons.movie_outlined,size:72)))
                 : const Center(child:Icon(Icons.movie_outlined,size:72))),
       ]);
       final detailPane = ListView(controller: detailScroll, children: [
         Padding(padding: const EdgeInsets.all(16), child: Column(
           crossAxisAlignment: CrossAxisAlignment.start, children: [
             Text(m.title, style: const TextStyle(fontSize: 29, fontWeight: FontWeight.w800,height:1.12)),
             const SizedBox(height: 8),
             Wrap(spacing:8,runSpacing:6,crossAxisAlignment:WrapCrossAlignment.center,children:[Chip(label:Text(m.type == 'tv' ? 'SERIES' : 'FILM'),visualDensity:VisualDensity.compact,side:BorderSide.none,backgroundColor:const Color(0xff62492e),labelStyle:const TextStyle(fontSize:11,fontWeight:FontWeight.w700)),Text(m.year,style:const TextStyle(color:Colors.white70)),const Icon(Icons.star_rounded,color:Color(0xffe5aa55),size:18),Text(m.rating.toStringAsFixed(1),style:const TextStyle(fontWeight:FontWeight.w700))]),
             const SizedBox(height: 12),
             FutureBuilder<Map<String,dynamic>>(
               future:details,
               builder:(context,snapshot){
                 final tmdbGenres=(snapshot.data?['genres'] as List? ?? const [])
                   .whereType<Map>().map((g)=>(g['name']??'').toString())
                   .where((g)=>g.isNotEmpty).toList();
                 final genres=m.genreNames.isNotEmpty ? m.genreNames :
                    tmdbGenres.isNotEmpty ? tmdbGenres :
                   (Platform.isWindows ? sourceGenres : <String>[]);
                 if(genres.isEmpty)return Platform.isWindows
                   ? const Padding(padding:EdgeInsets.symmetric(vertical:8),
                       child:Text('Genre belum tersedia dari TMDB atau LK21.',
                         style:TextStyle(color:Colors.white70)))
                   : const SizedBox.shrink();
                 return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                   const Text('Genre',style:TextStyle(fontSize:17,fontWeight:FontWeight.bold)),
                   const SizedBox(height:8),
                   Wrap(spacing:7,runSpacing:4,children:genres.map((g)=>
                     Chip(label:Text(g),visualDensity:VisualDensity.compact)).toList()),
                 ]);
               }),
             Builder(builder:(context){
               // Keep the synopsis section hidden until genuine source/catalog
               // text is available instead of flashing a placeholder.
               final fromCrawler=m.overview.trim();
               // On Windows the synopsis must come directly from the source,
               // not the catalog or TMDB; Android retains its prior behavior.
               final description=Platform.isWindows ? sourceSynopsis :
                 (sourceSynopsis.isNotEmpty?sourceSynopsis:fromCrawler);
               if(description.isEmpty && !Platform.isWindows)return const SizedBox.shrink();
               return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                 const SizedBox(height:14),
                 const Text('Sinopsis',style:TextStyle(fontSize:17,fontWeight:FontWeight.bold)),
                 const SizedBox(height:7),
                 if(Platform.isWindows && m.type=='tv' &&
                     description.isEmpty && _sourceSynopsisPending)
                   const Row(children:[
                     SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2)),
                     SizedBox(width:12),
                     Expanded(child:Text('Memuat sinopsis dari halaman sumber...')),
                   ])
                 else Text(description.isEmpty ? 'Sinopsis belum tersedia dari LK21.' : description),
               ]);
             }),
             if(m.type=='tv')...[
               const SizedBox(height:20),
               FutureBuilder<Uri>(future:sourceFuture,builder:(context,snapshot){
                 if(snapshot.hasError)return const Text('Sumber series belum tersedia.');
                 if(!snapshot.hasData)return const LinearProgressIndicator();
                 if(Platform.isWindows) return WindowsSeasonPicker(
                   key:ValueKey('windows-season-${m.id}'),
                   source:snapshot.data!, title:m.title, year:m.year,
                   onSynopsisFound:_receiveSynopsis,
                   onEpisodeSelected:(season,episode,url){
                     setState((){
                       sourceSeason=season;
                       sourceEpisode=episode;
                       selectedEpisodeUrl=url;
                     });
                     if(Platform.isWindows) {
                       _recordWindowsOpened(url,season:season,episode:episode);
                     }
                     if(detailScroll.hasClients)detailScroll.animateTo(0,
                       duration:const Duration(milliseconds:250),curve:Curves.easeOut);
                   },
                 );
                 return SourceSeasonPicker(
                   key:ValueKey('source-season-${m.id}'),
                   source:snapshot.data!, title:m.title, year:m.year,
                   onSynopsisFound:_receiveSynopsis,
                   onEpisodeSelected:(season,episode,url){
                     setState((){
                       sourceSeason=season;
                       sourceEpisode=episode;
                       selectedEpisodeUrl=url;
                     });
                     if(detailScroll.hasClients)detailScroll.animateTo(0,
                       duration:const Duration(milliseconds:250),curve:Curves.easeOut);
                   },
                 );
               }),
             ],
             // No TMDB episode picker: source numbering is authoritative.
           ],
         )),
       ]);
       if (wideDesktop) {
         return Padding(
           padding: const EdgeInsets.symmetric(horizontal:18, vertical:14),
           child: Row(crossAxisAlignment:CrossAxisAlignment.start, children: [
             Expanded(flex:7, child: Align(
               alignment:Alignment.topCenter,
               child: playerPane,
             )),
             const SizedBox(width:20),
             Container(width:1, color:const Color(0xff30343d)),
             const SizedBox(width:20),
             Expanded(flex:4, child: detailPane),
           ]),
         );
       }
       return Column(children: [
         playerPane,
         Expanded(child: detailPane),
       ]);
     }),
   );
 }
}
class Cue {final Duration start,end;final String text;Cue(this.start,this.end,this.text);}
Duration? parseTime(String input){final parts=input.trim().replaceAll(',','.').split(':');if(parts.length!=3)return null;final h=int.tryParse(parts[0]),m=int.tryParse(parts[1]),sec=double.tryParse(parts[2]);if(h==null||m==null||sec==null)return null;return Duration(milliseconds:(((h*3600+m*60)+sec)*1000).round());}
List<Cue> parseSrt(String content){final cues=<Cue>[];for(final block in content.replaceAll('\r','').split(RegExp(r'\n\s*\n'))){final lines=block.trim().split('\n');final idx=lines.indexWhere((s)=>s.contains('-->'));if(idx<0||idx>=lines.length-1)continue;final range=lines[idx].split('-->');if(range.length!=2)continue;final a=parseTime(range[0]),b=parseTime(range[1].trim().split(' ').first);if(a!=null&&b!=null)cues.add(Cue(a,b,lines.skip(idx+1).join('\n').replaceAll(RegExp(r'<[^>]*>'),'')));}return cues;}
class PlayerPage extends StatefulWidget {
 final String url,subtitle,title,historyKey,poster,type;final int tmdbId,season,episode;
 const PlayerPage({super.key,required this.url,required this.subtitle,required this.title,required this.historyKey,this.poster='',this.type='movie',this.tmdbId=0,this.season=0,this.episode=0});
 @override State<PlayerPage> createState()=>_PlayerPageState();
}
class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
 VideoPlayerController? controller;List<Cue> cues=[];String error='';bool captions=true;int _lastSaved=-1;bool _saving=false;
 @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);if (!Platform.isWindows) init();}
 Future<void> init() async {try{
  final c=VideoPlayerController.networkUrl(Uri.parse(widget.url));controller=c;await c.initialize();
  final previous=WatchStore.find(widget.historyKey);
  if(previous!=null&&!previous.completed&&previous.url==widget.url&&previous.positionMs>0&&c.value.duration.inMilliseconds>previous.positionMs+5000){await c.seekTo(Duration(milliseconds:previous.positionMs));}
  if(widget.subtitle.isNotEmpty){try{final r=await http.get(Uri.parse(widget.subtitle)).timeout(const Duration(seconds:15));if(r.statusCode==200)cues=parseSrt(utf8.decode(r.bodyBytes));}catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Subtitle tidak dapat dimuat.')));}}
  c.addListener(refresh);await c.play();await saveProgress(force:true);if(mounted)setState((){});
 }catch(e){if(mounted)setState(()=>error='Tidak dapat memutar video: $e');}}
 Future<void> saveProgress({bool force=false}) async {final c=controller;if(c==null||!c.value.isInitialized||_saving)return;final v=c.value;final pos=v.position.inMilliseconds;final dur=v.duration.inMilliseconds;if(dur<=0)return;final second=pos~/1000;if(!force&&second-_lastSaved<5)return;_lastSaved=second;_saving=true;
  final completed=dur-pos<=10000&&pos>0;
  try{await WatchStore.save(WatchEntry(key:widget.historyKey,title:widget.title,poster:widget.poster,type:widget.type,url:widget.url,subtitle:widget.subtitle,tmdbId:widget.tmdbId,season:widget.season,episode:widget.episode,positionMs:completed?dur:pos,durationMs:dur,updatedAt:DateTime.now().millisecondsSinceEpoch,completed:completed));}finally{_saving=false;}
 }
 void refresh(){saveProgress();if(mounted)setState((){});}
 @override void didChangeAppLifecycleState(AppLifecycleState state){if(state==AppLifecycleState.paused||state==AppLifecycleState.inactive||state==AppLifecycleState.detached){saveProgress(force:true);controller?.pause();}}
 @override void dispose(){WidgetsBinding.instance.removeObserver(this);saveProgress(force:true);controller?.removeListener(refresh);controller?.dispose();super.dispose();}
 String get caption {if(!captions||controller==null)return '';final pos=controller!.value.position;for(final c in cues){if(pos>=c.start&&pos<=c.end)return c.text;}return '';}
 @override Widget build(BuildContext context){
  if (Platform.isWindows) return WindowsSourcePlayer(title: widget.title, url: Uri.parse(widget.url));
  final c=controller;return PopScope(onPopInvokedWithResult:(didPop,_) {if(didPop)saveProgress(force:true);},child:Scaffold(appBar:AppBar(title:Text(widget.title)),body:Center(child:error.isNotEmpty?Padding(padding:const EdgeInsets.all(18),child:Text(error,textAlign:TextAlign.center)):c==null||!c.value.isInitialized?const CircularProgressIndicator():Column(mainAxisSize:MainAxisSize.min,children:[AspectRatio(aspectRatio:c.value.aspectRatio,child:Stack(alignment:Alignment.bottomCenter,children:[VideoPlayer(c),if(caption.isNotEmpty)Padding(padding:const EdgeInsets.only(bottom:20,left:12,right:12),child:Text(caption,textAlign:TextAlign.center,style:const TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold,backgroundColor:Colors.black87)))])),VideoProgressIndicator(c,allowScrubbing:true,padding:const EdgeInsets.all(10)),Row(mainAxisAlignment:MainAxisAlignment.center,children:[IconButton(icon:Icon(c.value.isPlaying?Icons.pause:Icons.play_arrow),onPressed:() {c.value.isPlaying?c.pause():c.play();saveProgress(force:true);}),IconButton(tooltip:'Subtitle Indonesia',icon:Icon(captions?Icons.closed_caption:Icons.closed_caption_disabled),onPressed:()=>setState(()=>captions=!captions)),Text('${clock(c.value.position.inMilliseconds)} / ${clock(c.value.duration.inMilliseconds)}')]),const Text('Progres disimpan otomatis di perangkat',style:TextStyle(color:Colors.white60,fontSize:12)),if(widget.subtitle.isNotEmpty&&cues.isEmpty)const Text('Subtitle belum tersedia / gagal dimuat',style:TextStyle(color:Colors.white54))]))));}
}
