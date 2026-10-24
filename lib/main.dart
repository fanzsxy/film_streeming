import 'source_manager.dart';
import 'web_source_page.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tmdbToken = String.fromEnvironment('TMDB_TOKEN');
const imageRoot = 'https://image.tmdb.org/t/p/w500';
void main() {WidgetsFlutterBinding.ensureInitialized();PaintingBinding.instance.imageCache.maximumSize = 500; PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20;runApp(const FilmStream());}
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
    theme:ThemeData.dark(useMaterial3:true).copyWith(scaffoldBackgroundColor:const Color(0xff101014),colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xffed625a),brightness:Brightness.dark)),home:const StartupGate());
}
class Movie {
 final int id; final String title,overview,poster,backdrop,release,type; final double rating; final List<int> genres;
 Movie.fromJson(Map<String,dynamic> j,{String fallback='movie'}):id=(j['id'] as num).toInt(),title=(j['title']??j['name']??'Tanpa judul').toString(),overview=(j['overview']??'').toString(),poster=(j['poster_path']??'').toString(),backdrop=(j['backdrop_path']??'').toString(),release=(j['release_date']??j['first_air_date']??'').toString(),rating=((j['vote_average']??0) as num).toDouble(),type=(j['media_type']=='tv'||j['media_type']=='movie')?j['media_type'] as String:fallback,genres=(j['genre_ids'] as List? ?? []).whereType<num>().map((e)=>e.toInt()).toList();
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
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Riwayat Tontonan')),body:ValueListenableBuilder<List<WatchEntry>>(valueListenable:WatchStore.entries,builder:(context,items,_)=>items.isEmpty?const Center(child:Text('Belum ada riwayat. Putar video di FilmStream untuk mulai menyimpan progres.',textAlign:TextAlign.center)):ListView.builder(itemCount:items.length,itemBuilder:(context,i){final e=items[i];return ListTile(leading:e.poster.isEmpty?const SizedBox(width:50,child:Icon(Icons.movie)):Image.network('$imageRoot${e.poster}',width:50,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.movie)),title:Text(e.label,maxLines:2),subtitle:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(e.completed?'Selesai ditonton':e.subtitle=='__webview__'?(e.durationMs>0?'Terakhir ${clock(e.positionMs)} / ${clock(e.durationMs)}':'Episode/film pernah dibuka'):'Terakhir ${clock(e.positionMs)} / ${clock(e.durationMs)}'),LinearProgressIndicator(value:e.progress),const SizedBox(height:4),Text(e.completed?'Putar ulang':e.subtitle=='__webview__'?(e.durationMs>0?'Buka kembali (progres tercatat)':'Buka kembali player'):'Lanjutkan menonton',style:const TextStyle(fontSize:12))]),onTap:()=>openWatchDetail(context,e),trailing:IconButton(tooltip:'Hapus riwayat',icon:const Icon(Icons.delete_outline),onPressed:()=>WatchStore.remove(e.key)));})));
}
class Tmdb {
 static final Map<String,Future<List<Movie>>> _railCache = {};
 static Future<List<Movie>> rail(String endpoint, String type) => _railCache.putIfAbsent("$endpoint|$type", () => list(endpoint,type:type));
 static Future<Map<String,dynamic>> get(String endpoint,[Map<String,String> params=const {}]) async {
  if(tmdbToken.isEmpty)throw Exception('TMDB_TOKEN belum diatur.');
  final uri=Uri.https('api.themoviedb.org','/3/$endpoint',{'language':'id-ID',...params});
  final r=await http.get(uri,headers:{'Authorization':'Bearer $tmdbToken','accept':'application/json'}).timeout(const Duration(seconds:20));
  if(r.statusCode!=200)throw Exception('TMDB HTTP ${r.statusCode}');return jsonDecode(r.body) as Map<String,dynamic>;
 }
 static Future<List<Movie>> list(String endpoint,{int page=1,Map<String,String> params=const {},String type='movie'}) async {
  final d=await get(endpoint,{'page':'$page',...params});return (d['results'] as List? ?? []).whereType<Map<String,dynamic>>().where((e)=>e['media_type']!='person').map((e)=>Movie.fromJson(e,fallback:type)).toList();
 }
}
class HomePage extends StatefulWidget {const HomePage({super.key});@override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage> {
 int tab=0;String genre='';String query='';Timer? debounce;final search=TextEditingController();
 final homeScroll=ScrollController();
 final favorites=<String,Movie>{};
 static const labels=['Beranda','Film','Series','Genre','Favorit'];
 static const genreNames={28:'Action',12:'Adventure',16:'Animasi',35:'Komedi',80:'Kriminal',99:'Dokumenter',18:'Drama',10751:'Keluarga',14:'Fantasi',36:'Sejarah',27:'Horor',10402:'Musik',9648:'Misteri',10749:'Romantis',878:'Sci-Fi',53:'Thriller',10752:'Perang',37:'Western'};
 @override void dispose(){debounce?.cancel();search.dispose();homeScroll.dispose();super.dispose();}
 void open(Movie m) => Navigator.push(context,MaterialPageRoute(builder:(_)=>DetailPage(movie:m,isFavorite:favorites.containsKey('${m.type}:${m.id}'),onFavorite:(){setState((){final k='${m.type}:${m.id}';if(favorites.containsKey(k)){favorites.remove(k);}else{favorites[k]=m;}});})));
 void changeTab(int n){setState((){tab=n;genre='';query='';search.clear();});}
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('FILMSTREAM',style:TextStyle(fontWeight:FontWeight.w900,letterSpacing:1.5)),actions:[IconButton(tooltip:'Riwayat tontonan',icon:const Icon(Icons.history),onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const HistoryPage()))),IconButton(icon:const Icon(Icons.info_outline),onPressed:()=>showAboutDialog(context:context,applicationName:'FilmStream Personal',children:[const Text('Metadata menggunakan TMDB; bukan didukung atau disertifikasi oleh TMDB. Pemutaran video memerlukan sumber yang dapat digunakan secara sah.')]))]),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:changeTab,destinations:const [NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home),label:'Beranda'),NavigationDestination(icon:Icon(Icons.movie_outlined),label:'Film'),NavigationDestination(icon:Icon(Icons.tv_outlined),label:'Series'),NavigationDestination(icon:Icon(Icons.category_outlined),label:'Genre'),NavigationDestination(icon:Icon(Icons.favorite_border),selectedIcon:Icon(Icons.favorite),label:'Favorit')]),body:Column(children:[if(tab!=4)Padding(padding:const EdgeInsets.fromLTRB(14,8,14,8),child:TextField(controller:search,decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Cari film atau series...',suffixIcon:query.isEmpty?null:IconButton(icon:const Icon(Icons.close),onPressed:(){search.clear();setState(()=>query='');}),border:OutlineInputBorder(borderRadius:BorderRadius.circular(16))),onChanged:(v){debounce?.cancel();debounce=Timer(const Duration(milliseconds:400),(){if(mounted)setState(()=>query=v.trim());});})),Expanded(child:query.isNotEmpty?PagedGrid(key:ValueKey('search:$query'),title:'Hasil pencarian: $query',endpoint:'search/multi',params:{'query':query,'include_adult':'false'},type:'movie',onTap:open):switch(tab){0=>ListView(key:const PageStorageKey('home-feed'),controller:homeScroll,children:[const LastWatchedRail(),const Padding(padding:EdgeInsets.fromLTRB(16,14,16,0),child:Text('Pilihan untuk kamu',style:TextStyle(fontSize:23,fontWeight:FontWeight.bold))),MovieRail(key:const ValueKey('rail-trending'),title:'Sedang Trending',endpoint:'trending/all/week',type:'movie',onTap:open),MovieRail(key:const ValueKey('rail-film-pop'),title:'Film Populer',endpoint:'movie/popular',type:'movie',onTap:open),MovieRail(key:const ValueKey('rail-series-pop'),title:'Series Populer',endpoint:'tv/popular',type:'tv',onTap:open),MovieRail(key:const ValueKey('rail-film-top'),title:'Film Rating Tinggi',endpoint:'movie/top_rated',type:'movie',onTap:open),MovieRail(key:const ValueKey('rail-series-top'),title:'Series Rating Tinggi',endpoint:'tv/top_rated',type:'tv',onTap:open),const SizedBox(height:16)]),1=>PagedGrid(key:const ValueKey('film'),title:'Semua Film Populer',endpoint:'movie/popular',type:'movie',onTap:open),2=>PagedGrid(key:const ValueKey('tv'),title:'Series Populer',endpoint:'tv/popular',type:'tv',onTap:open),3=>Column(children:[SizedBox(height:58,child:ListView(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:12),children:genreNames.entries.map((e)=>Padding(padding:const EdgeInsets.only(right:7),child:ChoiceChip(label:Text(e.value),selected:genre=='${e.key}',onSelected:(_)=>setState(()=>genre='${e.key}')))).toList())),Expanded(child:genre.isEmpty?const Center(child:Text('Pilih genre di bagian atas')):PagedGrid(key:ValueKey('genre:$genre'),title:'Genre ${genreNames[int.tryParse(genre)]}',endpoint:'discover/movie',params:{'with_genres':genre,'sort_by':'popularity.desc','include_adult':'false'},type:'movie',onTap:open))]),_=>favorites.isEmpty?const Center(child:Text('Belum ada favorit. Simpan dari halaman detail.')):GridView.builder(padding:const EdgeInsets.all(12),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2,childAspectRatio:.58,mainAxisSpacing:14,crossAxisSpacing:12),itemCount:favorites.length,itemBuilder:(context,i)=>MovieTile(movie:favorites.values.elementAt(i),onTap:open))})]));
}
class MovieTile extends StatelessWidget {final Movie movie;final ValueChanged<Movie> onTap;const MovieTile({super.key,required this.movie,required this.onTap});
 @override Widget build(BuildContext context)=>InkWell(onTap:()=>onTap(movie),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(12),child:movie.poster.isEmpty?Container(color:Colors.white12,child:const Center(child:Icon(Icons.movie,size:44))):Image.network('$imageRoot${movie.poster}',width:double.infinity,fit:BoxFit.cover,gaplessPlayback:true,errorBuilder:(_,__,___)=>const Center(child:Icon(Icons.broken_image))))),const SizedBox(height:6),Text(movie.title,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700)),Text('${movie.type=='tv'?'Series':'Film'} • ${movie.year}  ★ ${movie.rating.toStringAsFixed(1)}',style:const TextStyle(color:Colors.white60,fontSize:11))]));}
// Simpan request katalog saat widget direbuild, bukan mengambil ulang pada setiap scroll.
class MovieRail extends StatefulWidget {
 final String title,endpoint,type; final ValueChanged<Movie> onTap;
 const MovieRail({super.key,required this.title,required this.endpoint,required this.type,required this.onTap});
 @override State<MovieRail> createState()=>_MovieRailState();
}
class _MovieRailState extends State<MovieRail> {
 late Future<List<Movie>> request;
 @override void initState(){super.initState();request=Tmdb.rail(widget.endpoint,widget.type);}
 @override void didUpdateWidget(covariant MovieRail old){super.didUpdateWidget(old);if(old.endpoint!=widget.endpoint||old.type!=widget.type){request=Tmdb.rail(widget.endpoint,widget.type);}}
 @override Widget build(BuildContext context)=>FutureBuilder<List<Movie>>(future:request,builder:(context,s)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Padding(padding:const EdgeInsets.fromLTRB(16,22,16,12),child:Text(widget.title,style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))),if(s.hasError)Padding(padding:const EdgeInsets.all(16),child:Text('${s.error}')) else SizedBox(height:267,child:!s.hasData?const Center(child:CircularProgressIndicator()):ListView.builder(key:PageStorageKey('rail:${widget.endpoint}'),scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:12),itemCount:s.data!.length,itemBuilder:(context,i)=>SizedBox(width:145,child:Padding(padding:const EdgeInsets.symmetric(horizontal:4),child:MovieTile(movie:s.data![i],onTap:widget.onTap)))))]));
}
class LastWatchedRail extends StatelessWidget {
 const LastWatchedRail({super.key});
 void _open(BuildContext context, WatchEntry e) => openWatchDetail(context,e);
 @override Widget build(BuildContext context)=>ValueListenableBuilder<List<WatchEntry>>(valueListenable:WatchStore.entries,builder:(context,history,_) {
   final recent=history.where((e)=>e.url.isNotEmpty).take(12).toList();
   if(recent.isEmpty)return const SizedBox.shrink();
   return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
     Padding(padding:const EdgeInsets.fromLTRB(16,18,12,10),child:Row(children:[const Expanded(child:Text('Terakhir Ditonton',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold))),TextButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const HistoryPage())),child:const Text('Lihat Lainnya  ›'))])),
     SizedBox(height:187,child:ListView.separated(key:const PageStorageKey('last-watched-rail'),scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:16),itemCount:recent.length,separatorBuilder:(_,__)=>const SizedBox(width:12),itemBuilder:(context,i){
       final e=recent[i];return SizedBox(width:176,child:InkWell(borderRadius:BorderRadius.circular(12),onTap:()=>_open(context,e),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
         ClipRRect(borderRadius:BorderRadius.circular(10),child:Stack(children:[
           SizedBox(height:106,width:176,child:e.poster.isEmpty?const ColoredBox(color:Color(0xff303038),child:Icon(Icons.play_circle_outline)):Image.network('$imageRoot${e.poster}',fit:BoxFit.cover,gaplessPlayback:true,errorBuilder:(_,__,___)=>const ColoredBox(color:Color(0xff303038),child:Icon(Icons.movie)))),
           Positioned(left:7,bottom:9,child:Container(padding:const EdgeInsets.symmetric(horizontal:5,vertical:3),color:Colors.black54,child:Text(e.type=='tv'?'S${e.season} · Eps ${e.episode}':'Film',style:const TextStyle(fontWeight:FontWeight.bold,fontSize:12)))),
           Positioned(left:0,right:0,bottom:0,child:LinearProgressIndicator(minHeight:4,value:e.progress,backgroundColor:Colors.white24,color:const Color(0xffe64653))),
         ])),const SizedBox(height:7),Text(e.title,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:13,fontWeight:FontWeight.w600))
       ])));
     }))
   ]);
 });
}
class PagedGrid extends StatefulWidget {final String title,endpoint,type;final Map<String,String> params;final ValueChanged<Movie> onTap;const PagedGrid({super.key,required this.title,required this.endpoint,required this.type,required this.onTap,this.params=const {}});@override State<PagedGrid> createState()=>_PagedGridState();}
class _PagedGridState extends State<PagedGrid> {final items=<Movie>[];int page=0;bool busy=false,more=true;String error='';final scroll=ScrollController();
 @override void initState(){super.initState();fetch();scroll.addListener((){if(scroll.hasClients&&scroll.position.pixels>scroll.position.maxScrollExtent-550)fetch();});}
 @override void dispose(){scroll.dispose();super.dispose();}
 Future<void> fetch() async {if(busy||!more)return;setState(()=>busy=true);try{final next=await Tmdb.list(widget.endpoint,page:page+1,params:widget.params,type:widget.type);if(!mounted)return;setState((){page++;items.addAll(next.where((m)=>!items.any((x)=>x.id==m.id&&x.type==m.type)));more=next.isNotEmpty&&page<50;error='';});}catch(e){if(mounted)setState(()=>error='$e');}finally{if(mounted)setState(()=>busy=false);}}
 @override Widget build(BuildContext context)=>Column(children:[Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:10),child:Align(alignment:Alignment.centerLeft,child:Text(widget.title,style:const TextStyle(fontSize:21,fontWeight:FontWeight.bold)))),Expanded(child:items.isEmpty&&busy?const Center(child:CircularProgressIndicator()):items.isEmpty&&error.isNotEmpty?Center(child:FilledButton(onPressed:fetch,child:Text('Gagal memuat — coba lagi ($error)'))):items.isEmpty?const Center(child:Text('Tidak ditemukan')):GridView.builder(controller:scroll,padding:const EdgeInsets.all(12),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2,childAspectRatio:.58,mainAxisSpacing:14,crossAxisSpacing:12),itemCount:items.length+(busy||error.isNotEmpty?1:0),itemBuilder:(context,i){if(i==items.length)return Center(child:error.isNotEmpty?TextButton(onPressed:fetch,child:const Text('Coba lagi')):const CircularProgressIndicator());return MovieTile(movie:items[i],onTap:widget.onTap);}))]);}

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
  page ??= Uri.https('tv12.lk21official.cc', '/search', {'s': movie.title});
  return page;
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

Future<void> recordWebProgress(Movie movie, Uri page, int positionMs, int durationMs, bool ended, {int season = 0, int episode = 0}) async {
  if (page.scheme != 'https' || durationMs <= 0) return;
  final key = movie.type == 'tv' ? 'tv:${movie.id}:$season:$episode' : 'movie:${movie.id}';
  final prior = WatchStore.find(key);
  final completed = (prior?.completed ?? false) || ended || positionMs / durationMs >= .90;
  await WatchStore.save(WatchEntry(key:key,title:movie.title,poster:movie.poster,type:movie.type,
    url:page.toString(),subtitle:'__webview__',tmdbId:movie.id,season:season,episode:episode,
    positionMs:completed ? durationMs : positionMs,durationMs:durationMs,
    updatedAt:DateTime.now().millisecondsSinceEpoch,completed:completed));
}

Widget inlineSource(Movie movie, {int season = 0, int episode = 0, Future<Uri>? resolved, VoidCallback? onFullscreenExit}) =>
  FutureBuilder<Uri>(
    future: resolved ?? resolveSourcePage(movie),
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const SizedBox(height: 340,
        child: ColoredBox(color: Color(0xff101014), child: Center(child: CircularProgressIndicator())));
      return WebSourcePage(
        key: ValueKey('${movie.type}:${movie.id}:$season:$episode'),
        title: movie.title, url: snapshot.data!, focused: true, embedded: true,
        tmdbId: movie.id, mediaType: movie.type, year: movie.year,
        season: season, episode: episode,
        onPlayerReady: (uri) => recordWebOpen(movie, uri, season:season, episode:episode),
        onVideoProgress: (pos, dur, ended) => recordWebProgress(movie, snapshot.data!, pos, dur, ended, season:season, episode:episode),
        onFullscreenExit: onFullscreenExit);
    },
  );

Future<void> openFocusedFilm(BuildContext context, Movie movie, {int season = 0, int episode = 0}) async {
  final page = await resolveSourcePage(movie);
  if (!context.mounted) return;
  Navigator.push(context, MaterialPageRoute(builder: (_) => WebSourcePage(
    title: movie.title, url: page, focused: true, tmdbId: movie.id,
    mediaType: movie.type, year: movie.year, season: season, episode: episode)));
}

class DetailPage extends StatefulWidget {final Movie movie;final bool isFavorite;final VoidCallback onFavorite; final int? initialSeason,initialEpisode; final Uri? initialPage; const DetailPage({super.key,required this.movie,required this.isFavorite,required this.onFavorite,this.initialSeason,this.initialEpisode,this.initialPage});@override State<DetailPage> createState()=>_DetailPageState();}
class _DetailPageState extends State<DetailPage> {final videoUrl=TextEditingController(),subtitleUrl=TextEditingController(),sourcePage=TextEditingController();late bool favorite;late Future<Map<String,dynamic>> details; late Future<Uri> sourceFuture;
 @override void initState(){super.initState();favorite=widget.isFavorite;details=Tmdb.get('${widget.movie.type}/${widget.movie.id}'); sourceFuture=widget.initialPage != null && widget.movie.type=='movie' ? Future.value(widget.initialPage!) : resolveSourcePage(widget.movie); if(widget.movie.type=='tv' && widget.initialSeason!=null && widget.initialEpisode!=null){selectedSeason=widget.initialSeason;playingSeason=widget.initialSeason;playingEpisode=widget.initialEpisode;episodeSourceFuture=widget.initialPage!=null?Future.value(widget.initialPage!):resolveSourcePage(widget.movie);}}
 @override void dispose(){videoUrl.dispose();subtitleUrl.dispose();sourcePage.dispose();detailScroll.dispose();super.dispose();}
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
           future: episodeFutures.putIfAbsent(active, () => Tmdb.get('tv/${m.id}/season/$active')),
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
     body: Column(children: [
       if (m.type == 'movie')
         inlineSource(m, resolved: sourceFuture, onFullscreenExit: () {
           if (detailScroll.hasClients) detailScroll.jumpTo(0);
         })
       else if (m.type == 'tv' && playingSeason != null && playingEpisode != null)
         inlineSource(m, season: playingSeason!, episode: playingEpisode!,
           resolved: episodeSourceFuture, onFullscreenExit: () {
             if (detailScroll.hasClients) detailScroll.jumpTo(0);
           })
       else if (m.type == 'tv' && m.backdrop.isNotEmpty)
         Image.network('$imageRoot${m.backdrop}', height: 190, width: double.infinity,
           fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
       Expanded(child: ListView(controller: detailScroll, children: [
         Padding(padding: const EdgeInsets.all(16), child: Column(
           crossAxisAlignment: CrossAxisAlignment.start, children: [
             Text(m.title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
             const SizedBox(height: 8),
             Text('${m.type == 'tv' ? 'Series' : 'Film'} • ${m.year} • ★ ${m.rating.toStringAsFixed(1)}',
               style: const TextStyle(color: Colors.white70)),
             const SizedBox(height: 14),
             Text(m.overview.isEmpty ? 'Sinopsis belum tersedia.' : m.overview),
             if (m.type == 'tv') _seasonSection(m),
           ],
         )),
       ])),
     ]),
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
 @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);init();}
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
 @override Widget build(BuildContext context){final c=controller;return PopScope(onPopInvokedWithResult:(didPop,_) {if(didPop)saveProgress(force:true);},child:Scaffold(appBar:AppBar(title:Text(widget.title)),body:Center(child:error.isNotEmpty?Padding(padding:const EdgeInsets.all(18),child:Text(error,textAlign:TextAlign.center)):c==null||!c.value.isInitialized?const CircularProgressIndicator():Column(mainAxisSize:MainAxisSize.min,children:[AspectRatio(aspectRatio:c.value.aspectRatio,child:Stack(alignment:Alignment.bottomCenter,children:[VideoPlayer(c),if(caption.isNotEmpty)Padding(padding:const EdgeInsets.only(bottom:20,left:12,right:12),child:Text(caption,textAlign:TextAlign.center,style:const TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold,backgroundColor:Colors.black87)))])),VideoProgressIndicator(c,allowScrubbing:true,padding:const EdgeInsets.all(10)),Row(mainAxisAlignment:MainAxisAlignment.center,children:[IconButton(icon:Icon(c.value.isPlaying?Icons.pause:Icons.play_arrow),onPressed:() {c.value.isPlaying?c.pause():c.play();saveProgress(force:true);}),IconButton(tooltip:'Subtitle Indonesia',icon:Icon(captions?Icons.closed_caption:Icons.closed_caption_disabled),onPressed:()=>setState(()=>captions=!captions)),Text('${clock(c.value.position.inMilliseconds)} / ${clock(c.value.duration.inMilliseconds)}')]),const Text('Progres disimpan otomatis di perangkat',style:TextStyle(color:Colors.white60,fontSize:12)),if(widget.subtitle.isNotEmpty&&cues.isEmpty)const Text('Subtitle belum tersedia / gagal dimuat',style:TextStyle(color:Colors.white54))]))));}
}
