import 'source_manager.dart';
import 'web_source_page.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tmdbToken = String.fromEnvironment('TMDB_TOKEN');
const imageRoot = 'https://image.tmdb.org/t/p/w500';
void main() {WidgetsFlutterBinding.ensureInitialized();runApp(const FilmStream());}
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
class HistoryPage extends StatelessWidget {const HistoryPage({super.key});
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Riwayat Tontonan')),body:ValueListenableBuilder<List<WatchEntry>>(valueListenable:WatchStore.entries,builder:(context,items,_)=>items.isEmpty?const Center(child:Text('Belum ada riwayat. Putar video di FilmStream untuk mulai menyimpan progres.',textAlign:TextAlign.center)):ListView.builder(itemCount:items.length,itemBuilder:(context,i){final e=items[i];return ListTile(leading:e.poster.isEmpty?const SizedBox(width:50,child:Icon(Icons.movie)):Image.network('$imageRoot${e.poster}',width:50,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.movie)),title:Text(e.label,maxLines:2),subtitle:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(e.completed?'Selesai ditonton':'Terakhir ${clock(e.positionMs)} / ${clock(e.durationMs)}'),LinearProgressIndicator(value:e.progress),const SizedBox(height:4),Text(e.completed?'Putar ulang':'Lanjutkan menonton',style:const TextStyle(fontSize:12))]),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>PlayerPage(url:e.url,subtitle:e.subtitle,title:e.label,historyKey:e.key,poster:e.poster,type:e.type,tmdbId:e.tmdbId,season:e.season,episode:e.episode))),trailing:IconButton(tooltip:'Hapus riwayat',icon:const Icon(Icons.delete_outline),onPressed:()=>WatchStore.remove(e.key)));})));
}
class Tmdb {
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
 final favorites=<String,Movie>{};
 static const labels=['Beranda','Film','Series','Genre','Favorit'];
 static const genreNames={28:'Action',12:'Adventure',16:'Animasi',35:'Komedi',80:'Kriminal',99:'Dokumenter',18:'Drama',10751:'Keluarga',14:'Fantasi',36:'Sejarah',27:'Horor',10402:'Musik',9648:'Misteri',10749:'Romantis',878:'Sci-Fi',53:'Thriller',10752:'Perang',37:'Western'};
 @override void dispose(){debounce?.cancel();search.dispose();super.dispose();}
 void open(Movie m) => Navigator.push(context,MaterialPageRoute(builder:(_)=>DetailPage(movie:m,isFavorite:favorites.containsKey('${m.type}:${m.id}'),onFavorite:(){setState((){final k='${m.type}:${m.id}';if(favorites.containsKey(k)){favorites.remove(k);}else{favorites[k]=m;}});})));
 void changeTab(int n){setState((){tab=n;genre='';query='';search.clear();});}
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('FILMSTREAM',style:TextStyle(fontWeight:FontWeight.w900,letterSpacing:1.5)),actions:[IconButton(tooltip:'Riwayat tontonan',icon:const Icon(Icons.history),onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const HistoryPage()))),IconButton(icon:const Icon(Icons.info_outline),onPressed:()=>showAboutDialog(context:context,applicationName:'FilmStream Personal',children:[const Text('Metadata menggunakan TMDB; bukan didukung atau disertifikasi oleh TMDB. Pemutaran video memerlukan sumber yang dapat digunakan secara sah.')]))]),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:changeTab,destinations:const [NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home),label:'Beranda'),NavigationDestination(icon:Icon(Icons.movie_outlined),label:'Film'),NavigationDestination(icon:Icon(Icons.tv_outlined),label:'Series'),NavigationDestination(icon:Icon(Icons.category_outlined),label:'Genre'),NavigationDestination(icon:Icon(Icons.favorite_border),selectedIcon:Icon(Icons.favorite),label:'Favorit')]),body:Column(children:[if(tab!=4)Padding(padding:const EdgeInsets.fromLTRB(14,8,14,8),child:TextField(controller:search,decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Cari film atau series...',suffixIcon:query.isEmpty?null:IconButton(icon:const Icon(Icons.close),onPressed:(){search.clear();setState(()=>query='');}),border:OutlineInputBorder(borderRadius:BorderRadius.circular(16))),onChanged:(v){debounce?.cancel();debounce=Timer(const Duration(milliseconds:400),(){if(mounted)setState(()=>query=v.trim());});})),Expanded(child:query.isNotEmpty?PagedGrid(key:ValueKey('search:$query'),title:'Hasil pencarian: $query',endpoint:'search/multi',params:{'query':query,'include_adult':'false'},type:'movie',onTap:open):switch(tab){0=>ListView(children:[const Padding(padding:EdgeInsets.fromLTRB(16,14,16,0),child:Text('Pilihan untuk kamu',style:TextStyle(fontSize:23,fontWeight:FontWeight.bold))),MovieRail(title:'Sedang Trending',endpoint:'trending/all/week',type:'movie',onTap:open),MovieRail(title:'Film Populer',endpoint:'movie/popular',type:'movie',onTap:open),MovieRail(title:'Series Populer',endpoint:'tv/popular',type:'tv',onTap:open),MovieRail(title:'Film Rating Tinggi',endpoint:'movie/top_rated',type:'movie',onTap:open),MovieRail(title:'Series Rating Tinggi',endpoint:'tv/top_rated',type:'tv',onTap:open),const SizedBox(height:16)]),1=>PagedGrid(key:const ValueKey('film'),title:'Semua Film Populer',endpoint:'movie/popular',type:'movie',onTap:open),2=>PagedGrid(key:const ValueKey('tv'),title:'Series Populer',endpoint:'tv/popular',type:'tv',onTap:open),3=>Column(children:[SizedBox(height:58,child:ListView(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:12),children:genreNames.entries.map((e)=>Padding(padding:const EdgeInsets.only(right:7),child:ChoiceChip(label:Text(e.value),selected:genre=='${e.key}',onSelected:(_)=>setState(()=>genre='${e.key}')))).toList())),Expanded(child:genre.isEmpty?const Center(child:Text('Pilih genre di bagian atas')):PagedGrid(key:ValueKey('genre:$genre'),title:'Genre ${genreNames[int.tryParse(genre)]}',endpoint:'discover/movie',params:{'with_genres':genre,'sort_by':'popularity.desc','include_adult':'false'},type:'movie',onTap:open))]),_=>favorites.isEmpty?const Center(child:Text('Belum ada favorit. Simpan dari halaman detail.')):GridView.builder(padding:const EdgeInsets.all(12),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2,childAspectRatio:.58,mainAxisSpacing:14,crossAxisSpacing:12),itemCount:favorites.length,itemBuilder:(context,i)=>MovieTile(movie:favorites.values.elementAt(i),onTap:open))})]));
}
class MovieTile extends StatelessWidget {final Movie movie;final ValueChanged<Movie> onTap;const MovieTile({super.key,required this.movie,required this.onTap});
 @override Widget build(BuildContext context)=>InkWell(onTap:()=>onTap(movie),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(12),child:movie.poster.isEmpty?Container(color:Colors.white12,child:const Center(child:Icon(Icons.movie,size:44))):Image.network('$imageRoot${movie.poster}',width:double.infinity,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Center(child:Icon(Icons.broken_image))))),const SizedBox(height:6),Text(movie.title,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700)),Text('${movie.type=='tv'?'Series':'Film'} • ${movie.year}  ★ ${movie.rating.toStringAsFixed(1)}',style:const TextStyle(color:Colors.white60,fontSize:11))]));}
class MovieRail extends StatelessWidget {final String title,endpoint,type;final ValueChanged<Movie> onTap;const MovieRail({super.key,required this.title,required this.endpoint,required this.type,required this.onTap});
 @override Widget build(BuildContext context)=>FutureBuilder<List<Movie>>(future:Tmdb.list(endpoint,type:type),builder:(context,s)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Padding(padding:const EdgeInsets.fromLTRB(16,22,16,12),child:Text(title,style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))),if(s.hasError)Padding(padding:const EdgeInsets.all(16),child:Text('${s.error}')) else SizedBox(height:267,child:!s.hasData?const Center(child:CircularProgressIndicator()):ListView.builder(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:12),itemCount:s.data!.length,itemBuilder:(context,i)=>SizedBox(width:145,child:Padding(padding:const EdgeInsets.symmetric(horizontal:4),child:MovieTile(movie:s.data![i],onTap:onTap)))))]));}
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
  if(data['found']!=true)return const Center(child:Padding(padding:EdgeInsets.all(20),child:Text('Judul ini belum memiliki arsip inspeksi sumber. Ini bukan berarti filmnya tidak ada di TMDB atau tidak dapat ditonton di tempat lain.',textAlign:TextAlign.center)));
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
class DetailPage extends StatefulWidget {final Movie movie;final bool isFavorite;final VoidCallback onFavorite;const DetailPage({super.key,required this.movie,required this.isFavorite,required this.onFavorite});@override State<DetailPage> createState()=>_DetailPageState();}
class _DetailPageState extends State<DetailPage> {final videoUrl=TextEditingController(),subtitleUrl=TextEditingController(),sourcePage=TextEditingController();late bool favorite;late Future<Map<String,dynamic>> details;
 @override void initState(){super.initState();favorite=widget.isFavorite;details=Tmdb.get('${widget.movie.type}/${widget.movie.id}');}
 @override void dispose(){videoUrl.dispose();subtitleUrl.dispose();sourcePage.dispose();super.dispose();}
 bool https(String input){final u=Uri.tryParse(input.trim());return u!=null&&u.scheme=='https'&&u.host.isNotEmpty;}

 Widget _seasonSection(Movie m) {
   return FutureBuilder<Map<String, dynamic>>(
     future: details,
     builder: (context, snapshot) {
       if (!snapshot.hasData) {
         return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
       }
       final seasons = (snapshot.data!['seasons'] as List? ?? [])
           .whereType<Map<String, dynamic>>()
           .where((item) => (item['season_number'] as num? ?? 0) >= 1);
       return Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
           const SizedBox(height: 20),
           const Text('Season & Episode', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
           ...seasons.map((season) {
             final seasonNumber = (season['season_number'] as num).toInt();
             return ExpansionTile(
               title: Text((season['name'] ?? 'Season $seasonNumber').toString()),
               subtitle: Text('${season['episode_count'] ?? 0} episode'),
               children: [
                 FutureBuilder<Map<String, dynamic>>(
                   future: Tmdb.get('tv/${m.id}/season/$seasonNumber'),
                   builder: (context, episodeSnapshot) {
                     if (!episodeSnapshot.hasData) return const LinearProgressIndicator();
                     final episodes = (episodeSnapshot.data!['episodes'] as List? ?? [])
                         .whereType<Map<String, dynamic>>();
                     return Column(
                       children: episodes.map<Widget>((episode) {
                         final episodeNumber = (episode['episode_number'] as num? ?? 0).toInt();
                         return ListTile(
                           leading: const Icon(Icons.play_circle_outline),
                           title: Text('$episodeNumber. ${episode['name'] ?? 'Episode'}'),
                           subtitle: Text((episode['overview'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
                           onTap: () => Navigator.push(
                             context,
                             MaterialPageRoute(
                               builder: (_) => Scaffold(
                                 appBar: AppBar(title: Text('Episode $episodeNumber')),
                                 body: Padding(
                                   padding: const EdgeInsets.all(20),
                                   child: AutoSourceButton(movie: m, season: seasonNumber, episode: episodeNumber),
                                 ),
                               ),
                             ),
                           ),
                         );
                       }).toList(),
                     );
                   },
                 ),
               ],
             );
           }),
         ],
       );
     },
   );
 }
 @override Widget build(BuildContext context){final m=widget.movie;return Scaffold(appBar:AppBar(title:Text(m.title,maxLines:1),actions:[IconButton(icon:Icon(favorite?Icons.favorite:Icons.favorite_border),onPressed:(){widget.onFavorite();setState(()=>favorite=!favorite);})]),body:ListView(padding:const EdgeInsets.all(16),children:[if(m.backdrop.isNotEmpty)ClipRRect(borderRadius:BorderRadius.circular(12),child:Image.network('$imageRoot${m.backdrop}',height:190,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const SizedBox.shrink())),const SizedBox(height:14),Text(m.title,style:const TextStyle(fontSize:26,fontWeight:FontWeight.bold)),Text('${m.type=='tv'?'Series':'Film'} • ${m.year} • ★ ${m.rating.toStringAsFixed(1)}',style:const TextStyle(color:Colors.white70)),const SizedBox(height:14),Text(m.overview.isEmpty?'Sinopsis Bahasa Indonesia belum tersedia.':m.overview),if(m.type=='tv') _seasonSection(m),const SizedBox(height:22),ValueListenableBuilder<List<WatchEntry>>(valueListenable:WatchStore.entries,builder:(context,_,__) {final e=WatchStore.find('${m.type}:${m.id}');if(e==null)return const SizedBox.shrink();return Card(child:ListTile(leading:const Icon(Icons.history),title:Text(e.completed?'Sudah ditonton • Putar ulang':'Lanjutkan dari ${clock(e.positionMs)}'),subtitle:LinearProgressIndicator(value:e.progress),onTap:(){videoUrl.text=e.url;subtitleUrl.text=e.subtitle;Navigator.push(context,MaterialPageRoute(builder:(_)=>PlayerPage(url:e.url,subtitle:e.subtitle,title:m.title,historyKey:e.key,poster:m.poster,type:m.type,tmdbId:m.id)));}));}),const SizedBox(height:22),if(m.type=='movie') AutoSourceButton(movie:m),const SizedBox(height:12),OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ExternalSourcePage(movie:m))),icon:const Icon(Icons.travel_explore),label:const Text('Lihat katalog sumber terinspeksi')),const SizedBox(height:12),const Text('Katalog menampilkan arsip inspeksi, bukan pengecekan live atau jaminan pemutaran.',style:TextStyle(color:Colors.white70,fontSize:12)),const SizedBox(height:22),const Text('Pemutar video pribadi',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const Text('Masukkan URL HTTPS video MP4/HLS yang dapat Anda gunakan. TMDB tidak menyediakan video film lengkap.',style:TextStyle(color:Colors.white70)),const SizedBox(height:10),TextField(controller:videoUrl,decoration:const InputDecoration(labelText:'URL video HTTPS',border:OutlineInputBorder()),keyboardType:TextInputType.url),const SizedBox(height:10),TextField(controller:subtitleUrl,decoration:const InputDecoration(labelText:'URL subtitle .srt (opsional)',border:OutlineInputBorder()),keyboardType:TextInputType.url),const SizedBox(height:10),FilledButton.icon(onPressed:(){if(!https(videoUrl.text)||(subtitleUrl.text.trim().isNotEmpty&&!https(subtitleUrl.text))){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Masukkan URL HTTPS yang valid.')));return;}Navigator.push(context,MaterialPageRoute(builder:(_)=>PlayerPage(url:videoUrl.text.trim(),subtitle:subtitleUrl.text.trim(),title:m.title,historyKey:'${m.type}:${m.id}',poster:m.poster,type:m.type,tmdbId:m.id)));},icon:const Icon(Icons.play_arrow),label:const Text('Putar video')),const SizedBox(height:18),TextField(controller:sourcePage,decoration:const InputDecoration(labelText:'Tautan halaman sumber eksternal',border:OutlineInputBorder()),keyboardType:TextInputType.url),OutlinedButton.icon(onPressed:()async{if(!https(sourcePage.text)){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Masukkan URL HTTPS yang valid.')));return;}if(!context.mounted)return;Navigator.push(context,MaterialPageRoute(builder:(_)=>WebSourcePage(title:m.title,url:Uri.parse(sourcePage.text.trim()))));},icon:const Icon(Icons.open_in_browser),label:const Text('Buka di WebView')),const SizedBox(height:20),const Text('Metadata oleh TMDB. Aplikasi tidak berafiliasi dengan TMDB. Sumber video LK21 tidak terintegrasi otomatis.',style:TextStyle(color:Colors.white54,fontSize:12))]));}
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
