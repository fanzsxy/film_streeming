import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

const tmdbToken = String.fromEnvironment('TMDB_TOKEN');
const imageRoot = 'https://image.tmdb.org/t/p/w500';
void main() => runApp(const FilmStream());

class FilmStream extends StatelessWidget {
  const FilmStream({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'FilmStream Personal', debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff101014),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffe53935), brightness: Brightness.dark),
    ), home: const HomePage());
}

class Movie {
  final int id; final String title, overview, poster, release; final double rating;
  Movie.fromJson(Map<String, dynamic> j): id=j['id'] as int,
    title=(j['title'] ?? j['name'] ?? 'Tanpa judul').toString(),
    overview=(j['overview'] ?? '').toString(), poster=(j['poster_path'] ?? '').toString(),
    release=(j['release_date'] ?? '').toString(), rating=((j['vote_average'] ?? 0) as num).toDouble();
}

class Tmdb {
  static Future<dynamic> get(String endpoint, [Map<String,String> params=const {}]) async {
    if (tmdbToken.isEmpty) throw Exception('TMDB_TOKEN belum diatur. Lihat README.md.');
    final uri=Uri.https('api.themoviedb.org','/3/$endpoint', {'language':'id-ID', ...params});
    final response=await http.get(uri, headers:{'Authorization':'Bearer $tmdbToken','accept':'application/json'}).timeout(const Duration(seconds:15));
    if (response.statusCode!=200) throw Exception('TMDB HTTP ${response.statusCode}: ${response.body.length > 150 ? response.body.substring(0,150) : response.body}');
    return jsonDecode(response.body);
  }
  static Future<List<Movie>> list(String endpoint,[Map<String,String> params=const {}]) async {
    final data=await get(endpoint,params) as Map<String,dynamic>;
    return (data['results'] as List).map((e)=>Movie.fromJson(e as Map<String,dynamic>)).toList();
  }
}

class HomePage extends StatefulWidget {const HomePage({super.key}); @override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage> {
  final search=TextEditingController(); Timer? debounce; late Future<List<Movie>> movies;
  String heading='Film Populer';
  @override void initState(){super.initState();movies=Tmdb.list('movie/popular');}
  @override void dispose(){debounce?.cancel();search.dispose();super.dispose();}
  void load(String value){setState(() {heading=value.isEmpty?'Film Populer':'Hasil Pencarian'; movies=value.isEmpty?Tmdb.list('movie/popular'):Tmdb.list('search/movie', {'query':value,'include_adult':'false'});});}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('FILMSTREAM',style:TextStyle(fontWeight:FontWeight.w900,letterSpacing:1.5)), actions:[IconButton(icon:const Icon(Icons.info_outline),onPressed:()=>showAboutDialog(context:context,applicationName:'FilmStream Personal',children:[const Text('Katalog menggunakan TMDB. Aplikasi ini tidak didukung atau disertifikasi TMDB. Pemutaran hanya untuk URL video yang berizin.')]))]),body:Column(children:[
    Padding(padding:const EdgeInsets.all(14),child:TextField(controller:search,decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Cari judul film...',border:OutlineInputBorder(borderRadius:BorderRadius.circular(14))),onChanged:(v){debounce?.cancel();debounce=Timer(const Duration(milliseconds:450),()=>load(v.trim()));})),
    Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(children:[Expanded(child:Text(heading,style:Theme.of(context).textTheme.titleLarge)),TextButton(onPressed:()=>load(''),child:const Text('Populer'))])),
    Expanded(child:FutureBuilder<List<Movie>>(future:movies,builder:(context,s){if(s.connectionState!=ConnectionState.done)return const Center(child:CircularProgressIndicator());if(s.hasError)return Center(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,children:[Text('${s.error}',textAlign:TextAlign.center),const SizedBox(height:12),FilledButton(onPressed:()=>load(search.text.trim()),child:const Text('Coba lagi'))])));final data=s.data??[];if(data.isEmpty)return const Center(child:Text('Film tidak ditemukan'));return GridView.builder(padding:const EdgeInsets.all(12),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2,mainAxisSpacing:14,crossAxisSpacing:12,childAspectRatio:.58),itemCount:data.length,itemBuilder:(context,i){final m=data[i];return InkWell(onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>DetailPage(movie:m))),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(12),child:m.poster.isEmpty?const ColoredBox(color:Colors.white12,child:Center(child:Icon(Icons.movie,size:52))):Image.network('$imageRoot${m.poster}',fit:BoxFit.cover,width:double.infinity,errorBuilder:(_,__,___)=>const Center(child:Icon(Icons.broken_image))))),const SizedBox(height:6),Text(m.title,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold)),Text('${m.release.isEmpty?'—':m.release.substring(0,4)}  ★ ${m.rating.toStringAsFixed(1)}',style:const TextStyle(color:Colors.white60,fontSize:12))]));});}))]));
}

class DetailPage extends StatefulWidget {final Movie movie;const DetailPage({super.key,required this.movie});@override State<DetailPage> createState()=>_DetailPageState();}
class _DetailPageState extends State<DetailPage> {
  final videoUrl=TextEditingController();final subtitleUrl=TextEditingController(); final sourcePage=TextEditingController();
  @override void dispose(){videoUrl.dispose();subtitleUrl.dispose();sourcePage.dispose();super.dispose();}
  bool https(String input){final u=Uri.tryParse(input.trim());return u!=null&&u.scheme=='https'&&u.host.isNotEmpty;}
  @override Widget build(BuildContext context){final m=widget.movie;return Scaffold(appBar:AppBar(title:Text(m.title,maxLines:1)),body:ListView(padding:const EdgeInsets.all(18),children:[if(m.poster.isNotEmpty)Center(child:Image.network('$imageRoot${m.poster}',height:260,errorBuilder:(_,__,___)=>const Icon(Icons.movie,size:100))),const SizedBox(height:12),Text(m.title,style:Theme.of(context).textTheme.headlineSmall),Text('${m.release} • Rating ${m.rating.toStringAsFixed(1)}'),const SizedBox(height:14),Text(m.overview.isEmpty?'Sinopsis Bahasa Indonesia belum tersedia.':m.overview),const SizedBox(height:22),const Text('Sumber pemutaran',style:TextStyle(fontWeight:FontWeight.bold,fontSize:20)),const SizedBox(height:5),const Text('Masukkan URL HTTPS video MP4/HLS yang Anda berhak akses. URL halaman biasa atau iframe bukan URL video langsung.',style:TextStyle(color:Colors.white70)),const SizedBox(height:10),TextField(controller:videoUrl,decoration:const InputDecoration(labelText:'URL video HTTPS (.mp4 / .m3u8)',border:OutlineInputBorder()),keyboardType:TextInputType.url),const SizedBox(height:9),TextField(controller:subtitleUrl,decoration:const InputDecoration(labelText:'URL subtitle HTTPS (.srt) — opsional',border:OutlineInputBorder()),keyboardType:TextInputType.url),const SizedBox(height:10),FilledButton.icon(onPressed:(){if(!https(videoUrl.text)||(subtitleUrl.text.trim().isNotEmpty&&!https(subtitleUrl.text))){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Masukkan URL HTTPS yang valid.')));return;}Navigator.push(context,MaterialPageRoute(builder:(_)=>PlayerPage(url:videoUrl.text.trim(),subtitle:subtitleUrl.text.trim(),title:m.title)));},icon:const Icon(Icons.play_arrow),label:const Text('Putar video')),const SizedBox(height:24),const Text('Halaman sumber eksternal (opsional)',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:8),TextField(controller:sourcePage,decoration:const InputDecoration(labelText:'Tempel tautan halaman sumber HTTPS',border:OutlineInputBorder()),keyboardType:TextInputType.url),const SizedBox(height:8),OutlinedButton.icon(onPressed:() async {final str=sourcePage.text.trim();if(!https(str)){if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('URL halaman harus HTTPS.')));return;} final ok=await launchUrl(Uri.parse(str),mode:LaunchMode.externalApplication);if(!ok&&context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Gagal membuka halaman sumber.')));},icon:const Icon(Icons.open_in_browser),label:const Text('Buka halaman sumber di browser')),const SizedBox(height:20),const Text('Data film: TMDB. Tidak ada link LK21 otomatis; player pihak ketiga belum terverifikasi untuk embed.',style:TextStyle(color:Colors.white54,fontSize:12))]));}
}

class Cue {final Duration start,end;final String text;Cue(this.start,this.end,this.text);}
Duration? parseTime(String input){final parts=input.trim().replaceAll(',','.').split(':');if(parts.length!=3)return null;final h=int.tryParse(parts[0]),m=int.tryParse(parts[1]),sec=double.tryParse(parts[2]);if(h==null||m==null||sec==null)return null;return Duration(milliseconds:(((h*3600+m*60)+sec)*1000).round());}
List<Cue> parseSrt(String content){final cues=<Cue>[];for(final block in content.replaceAll('\r','').split(RegExp(r'\n\s*\n'))){final lines=block.trim().split('\n');final idx=lines.indexWhere((s)=>s.contains('-->'));if(idx<0||idx>=lines.length-1)continue;final range=lines[idx].split('-->');if(range.length!=2)continue;final a=parseTime(range[0]),b=parseTime(range[1].trim().split(' ').first);if(a!=null&&b!=null)cues.add(Cue(a,b,lines.skip(idx+1).join('\n').replaceAll(RegExp(r'<[^>]*>'),'')));}return cues;}
class PlayerPage extends StatefulWidget {final String url,subtitle,title;const PlayerPage({super.key,required this.url,required this.subtitle,required this.title});@override State<PlayerPage> createState()=>_PlayerPageState();}
class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? controller;List<Cue> cues=[];String error='';bool captions=true;
  @override void initState(){super.initState();init();}
  Future<void> init() async {try{final c=VideoPlayerController.networkUrl(Uri.parse(widget.url));controller=c;await c.initialize();if(widget.subtitle.isNotEmpty){try{final r=await http.get(Uri.parse(widget.subtitle)).timeout(const Duration(seconds:15));if(r.statusCode==200)cues=parseSrt(utf8.decode(r.bodyBytes));}catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Subtitle tidak dapat dimuat.')));}}c.addListener(refresh);await c.play();if(mounted)setState((){});}catch(e){if(mounted)setState(()=>error='Tidak dapat memutar video: $e');}}
  void refresh(){if(mounted)setState((){});}
  @override void dispose(){controller?.removeListener(refresh);controller?.dispose();super.dispose();}
  String get caption {if(!captions||controller==null)return '';final pos=controller!.value.position;for(final c in cues){if(pos>=c.start&&pos<=c.end)return c.text;}return '';}
  @override Widget build(BuildContext context){final c=controller;return Scaffold(appBar:AppBar(title:Text(widget.title)),body:Center(child:error.isNotEmpty?Padding(padding:const EdgeInsets.all(18),child:Text(error,textAlign:TextAlign.center)):c==null||!c.value.isInitialized?const CircularProgressIndicator():Column(mainAxisSize:MainAxisSize.min,children:[AspectRatio(aspectRatio:c.value.aspectRatio,child:Stack(alignment:Alignment.bottomCenter,children:[VideoPlayer(c),if(caption.isNotEmpty)Padding(padding:const EdgeInsets.only(bottom:20,left:12,right:12),child:Text(caption,textAlign:TextAlign.center,style:const TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold,backgroundColor:Colors.black87)))])),VideoProgressIndicator(c,allowScrubbing:true,padding:const EdgeInsets.all(10)),Row(mainAxisAlignment:MainAxisAlignment.center,children:[IconButton(icon:Icon(c.value.isPlaying?Icons.pause:Icons.play_arrow),onPressed:()=>c.value.isPlaying?c.pause():c.play()),IconButton(tooltip:'Subtitle Indonesia',icon:Icon(captions?Icons.closed_caption:Icons.closed_caption_disabled),onPressed:()=>setState(()=>captions=!captions)),Text('${c.value.position.inMinutes}:${(c.value.position.inSeconds%60).toString().padLeft(2,'0')} / ${c.value.duration.inMinutes}:${(c.value.duration.inSeconds%60).toString().padLeft(2,'0')}')]),if(widget.subtitle.isNotEmpty&&cues.isEmpty)const Text('Subtitle belum tersedia / gagal dimuat',style:TextStyle(color:Colors.white54))])));}
}
