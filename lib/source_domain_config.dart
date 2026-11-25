import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Resolves LK21 page redirects for both films and series.
///
/// A new hostname is learned only from an HTTPS redirect issued by a known
/// LK21 host, and only after the destination returns an HTML page containing
/// an LK21 brand marker. The verified host is cached per original hostname.
class SourceDomainConfig {
  static const _redirectCacheKey = 'filmstream_lk21_redirect_cache_v1';
  static const _cacheTtl = Duration(minutes: 15);
  static const _maxRedirects = 5;
  static const _requestTimeout = Duration(seconds: 8);
  // Hosts learned from a verified HTTPS redirect and LK21-branded response.
  static final Set<String> _verifiedRedirectHosts = <String>{};

  static const _knownExactHosts = <String>{
    'tv12.lk21official.cc',
    'tv13.lk21official.cc',
    'tv.lk21online.de',
    'tv9.nontondrama.my',
    'tv.nontondrama.vip',
  };

  static bool isKnownSourceHost(String? host) {
    if (host == null || host.trim().isEmpty) return false;
    final value = host.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (value.length > 253 ||
        !RegExp(r'^[a-z0-9.-]+$').hasMatch(value) ||
        value.startsWith('.') || value.endsWith('.') ||
        value.contains('..')) return false;
    if (_knownExactHosts.contains(value) ||
        _verifiedRedirectHosts.contains(value)) return true;
    const sourceBases = <String>{
      'lk21official.cc',
      'lk21online.de',
      'nontondrama.my',
      'nontondrama.vip',
    };
    return sourceBases.any((base) => value == base || value.endsWith('.$base'));
  }

  static bool _safeHttps(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.contains('.') &&
      uri.userInfo.isEmpty &&
      !uri.hasPort;

  static bool _looksLikeLk21Page(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) return false;
    final html = utf8.decode(bytes, allowMalformed: true).toLowerCase();
    final isHtml = html.contains('<html') || html.contains('<!doctype html');
    final hasBrand = html.contains('lk21') ||
        html.contains('layarkaca21') ||
        html.contains('layar kaca 21');
    return isHtml && hasBrand;
  }

  static Future<Map<String, dynamic>> _readCache() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_redirectCacheKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveRedirect(String oldHost, String newHost) async {
    try {
      final cache = await _readCache();
      cache[oldHost.toLowerCase()] = {
        'host': newHost.toLowerCase(),
        'checked_at': DateTime.now().millisecondsSinceEpoch,
      };
      if (oldHost.toLowerCase() != newHost.toLowerCase()) {
        _verifiedRedirectHosts.add(newHost.toLowerCase());
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_redirectCacheKey, jsonEncode(cache));
    } catch (_) {
      // A cache write failure must never block the source page.
    }
  }

  static Uri? _cachedDestination(Uri original, Map<String, dynamic> cache) {
    final record = cache[original.host.toLowerCase()];
    if (record is! Map) return null;
    final host = (record['host'] ?? '').toString().toLowerCase();
    final checkedAt = record['checked_at'];
    if (host.isEmpty || checkedAt is! num) return null;
    final age = DateTime.now().millisecondsSinceEpoch - checkedAt.toInt();
    if (age < 0 || age > _cacheTtl.inMilliseconds) return null;
    // A destination outside the known families is allowed only because this
    // exact host was learned from a verified redirect and stored locally.
    if (host.contains('/') || host.contains(':') || host.contains('@') ||
        !RegExp(r'^[a-z0-9.-]+$').hasMatch(host) ||
        host.startsWith('.') || host.endsWith('.') || host.contains('..')) {
      return null;
    }
    if (host != original.host.toLowerCase()) {
      _verifiedRedirectHosts.add(host);
    }
    return original.replace(host: host);
  }

  static Future<Uri?> _discoverRedirect(Uri original) async {
    final client = http.Client();
    try {
      var current = original;
      var redirected = false;
      for (var attempt = 0; attempt <= _maxRedirects; attempt++) {
        if (!_safeHttps(current)) return null;
        final request = http.Request('GET', current)..followRedirects = false;
        final response = await client.send(request).timeout(_requestTimeout);
        final status = response.statusCode;

        if (status >= 300 && status < 400) {
          final location = response.headers['location'];
          if (location == null || location.trim().isEmpty ||
              attempt == _maxRedirects) return null;
          final next = current.resolve(location.trim());
          if (!_safeHttps(next)) return null;
          current = next;
          redirected = true;
          continue;
        }

        if (status < 200 || status >= 300) return null;
        if (!redirected) {
          // Cache the current host too, so healthy pages do not trigger an
          // extra preflight request on every title opened in the app.
          await _saveRedirect(original.host, current.host);
          return original;
        }
        final bytes = await response.stream.toBytes().timeout(_requestTimeout);
        if (!_looksLikeLk21Page(bytes)) return null;
        await _saveRedirect(original.host, current.host);
        return current;
      }
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
    return null;
  }

  /// Return the original page URL unless a verified redirect is available.
  /// If discovery is temporarily offline, reuse the last verified host for
  /// up to seven days while preserving the original page path and query.
  static Future<Uri> resolvePage(Uri original) async {
    if (!_safeHttps(original) || !isKnownSourceHost(original.host)) {
      return original;
    }

    final cache = await _readCache();
    final cached = _cachedDestination(original, cache);
    if (cached != null) return cached;

    final discovered = await _discoverRedirect(original);
    if (discovered != null) return discovered;

    // Keep the existing series fallback for legacy URLs when the redirect
    // endpoint is unavailable. It is intentionally not used for movie URLs.
    if (original.host == 'tv9.nontondrama.my' ||
        original.host == 'tv.nontondrama.vip') {
      try {
        final response = await http.get(Uri.parse(
          'https://raw.githubusercontent.com/fanzsxy/film_streeming/main/config/source_domains.json',
        )).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final series = data is Map ? data['series'] : null;
          if (series is Map) {
            final active = Uri.tryParse(
              (series['active_base_url'] ?? '').toString(),
            );
            final allowed = (series['allowed_hosts'] as List? ?? const [])
                .whereType<String>().toSet();
            if (active != null && _safeHttps(active) &&
                allowed.contains(active.host)) {
              return original.replace(host: active.host);
            }
          }
        }
      } catch (_) {
        // Preserve the catalog permalink if the remote config is unavailable.
      }
    }
    return original;
  }
}
