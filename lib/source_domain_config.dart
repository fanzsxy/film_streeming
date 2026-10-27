import 'dart:convert';
import 'package:http/http.dart' as http;

/// Domain settings hosted in the project repository.
class SourceDomainConfig {
  static const _configUrl =
      'https://raw.githubusercontent.com/fanzsxy/film_streeming/main/config/source_domains.json';
  static const _fallbackHost = 'tv.lk21online.de';
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

  static bool _trusted(Uri uri, Set<String> hosts) =>
      uri.scheme == 'https' && uri.userInfo.isEmpty &&
      !uri.hasPort && hosts.contains(uri.host);

  /// Inspect HTTP redirects without replacing old permalinks with guessed paths.
  /// Only follow redirect destinations explicitly approved in source_domains.json.
  static Future<Uri?> _followTrustedRedirects(
      Uri original, Set<String> allowed) async {
    final client = http.Client();
    try {
      var current = original;
      for (var i = 0; i < 5; i++) {
        if (!_trusted(current, allowed)) return null;
        final request = http.Request('GET', current)..followRedirects = false;
        final response = await client.send(request)
            .timeout(const Duration(seconds: 6));
        final status = response.statusCode;
        if (status >= 200 && status < 300) {
          // Stop after headers. The WebView loads the real page.
          return current;
        }
        if (status < 300 || status >= 400) return null;
        final location = response.headers['location'];
        if (location == null || location.isEmpty) return null;
        final next = current.resolve(location);
        if (!_trusted(next, allowed)) return null;
        current = next;
      }
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
    return null;
  }

  /// WebView must receive the original catalog detail URL so the website can
  /// redirect it using cookies, JavaScript or HTTP just like a normal browser.
  /// Do not preflight with an HTTP client or replace a valid detail URL with search.
  static Future<Uri> seriesPage(Uri original) async {
    if (original.scheme != 'https' || original.userInfo.isNotEmpty ||
        original.hasPort) return original;
    const legacy = {'tv9.nontondrama.my', 'tv.nontondrama.vip'};
    if (!legacy.contains(original.host)) return original;
    // The legacy hostname no longer resolves, so no HTTP redirect can happen.
    // Keep the original detail permalink, query and fragment; replace ONLY
    // its hostname with the active, explicitly approved source domain.
    final current = await (_hostFuture ??= _readHost());
    return original.replace(host:current);
  }
}
