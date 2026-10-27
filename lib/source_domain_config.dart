import 'dart:convert';
import 'package:http/http.dart' as http;

/// Domain settings hosted in the project repository.
class SourceDomainConfig {
  static const _configUrl =
      'https://raw.githubusercontent.com/fanzsxy/film_streeming/main/config/source_domains.json';
  static const _fallbackHost = 'tv.nontondrama.vip';
  static Future<String>? _hostFuture;

  static Future<String> _readHost() async {
    try {
      final response = await http.get(Uri.parse(_configUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return _fallbackHost;
      final data = jsonDecode(response.body);
      if (data is! Map) return _fallbackHost;
      final series = data['series'];
      if (series is! Map) return _fallbackHost;
      final active = Uri.tryParse((series['active_base_url'] ?? '').toString());
      // Only hosts explicitly approved in the repository configuration.
      final allowed = (series['allowed_hosts'] as List? ?? const [])
          .whereType<String>().toSet();
      if (active == null || active.scheme != 'https' ||
          active.userInfo.isNotEmpty || active.hasPort ||
          !allowed.contains(active.host)) return _fallbackHost;
      return active.host;
    } catch (_) {
      return _fallbackHost;
    }
  }

  static String _titleFromSlug(Uri uri) {
    final last = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
    return Uri.decodeComponent(last)
        .replaceAll(RegExp(r'-(19|20)[0-9]{2}$'), '')
        .replaceAll('-', ' ');
  }

  /// Preserve valid current URLs; search by title when a legacy domain changes.
  static Future<Uri> seriesPage(Uri original) async {
    if (original.scheme != 'https') return original;
    if (original.host != 'tv9.nontondrama.my' &&
        original.host != 'tv.nontondrama.vip' &&
        original.host != 'tv.lk21online.de') return original;
    final host = await (_hostFuture ??= _readHost());
    if (original.host == host) return original;
    if (original.path != '/search' && original.path != '/search/') {
      final title = _titleFromSlug(original);
      if (title.isEmpty) return Uri.https(host, '/');
      return Uri.https(host, '/search', {'s': title});
    }
    return original.replace(host: host);
  }
}
