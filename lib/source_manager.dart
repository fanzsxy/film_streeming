import 'dart:convert';
import 'package:http/http.dart' as http;

// Backend milik Anda, bukan domain website atau alamat halaman LK21.
const sourceApiBase = String.fromEnvironment('SOURCE_API_BASE');
class PlaybackSource {
 final String provider, url, subtitleUrl;
 const PlaybackSource({required this.provider,required this.url,required this.subtitleUrl});
}
class PlaybackSourceManager {
 static bool validUrl(String value) {
  final uri=Uri.tryParse(value);
  return uri!=null && uri.scheme=='https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
 }
 static Future<PlaybackSource?> resolve({required int tmdbId,required String type,int season=0,int episode=0}) async {
  if(sourceApiBase.isEmpty)throw StateError('SOURCE_API_BASE belum diatur. Hubungkan backend Source API dahulu.');
  if(!validUrl(sourceApiBase))throw const FormatException('SOURCE_API_BASE wajib menggunakan HTTPS yang valid.');
  if(type!='movie'&&type!='tv')throw const FormatException('Tipe konten tidak dikenal.');
  final base=Uri.parse(sourceApiBase);
  final prefix=base.path.endsWith('/')?base.path.substring(0,base.path.length-1):base.path;
  final uri=base.replace(path:'$prefix/resolve',queryParameters:{'tmdb_id':'$tmdbId','type':type,'season':'$season','episode':'$episode'});
  final response=await http.get(uri,headers:{'Accept':'application/json'}).timeout(const Duration(seconds:15));
  if(response.statusCode==404)return null;
  if(response.statusCode!=200)throw StateError('Source API mengembalikan HTTP ${response.statusCode}.');
  final raw=jsonDecode(response.body);
  if(raw is! Map<String,dynamic>)throw const FormatException('Respons Source API bukan object JSON.');
  if(raw['available']!=true)return null;
  final item=raw['playback'];
  if(item is! Map)throw const FormatException('Field playback tidak tersedia.');
  final url=(item['url']??'').toString().trim();
  final format=(item['type']??'').toString().toLowerCase();
  final subtitle=(raw['subtitle_url']??'').toString().trim();
  if(!validUrl(url)||!['mp4','hls'].contains(format))throw const FormatException('Sumber harus berupa URL media HTTPS MP4/HLS.');
  if(subtitle.isNotEmpty&&!validUrl(subtitle))throw const FormatException('URL subtitle tidak valid.');
  return PlaybackSource(provider:(raw['provider']??'Sumber video').toString(),url:url,subtitleUrl:subtitle);
 }
}
