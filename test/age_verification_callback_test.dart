import 'package:flutter_test/flutter_test.dart';
import 'package:filmstream_personal/web_source_page.dart';

void main() {
  group('Age verification Google callback allowlist', () {
    test('permits only observed callback host during active consent', () {
      final callback = Uri.parse(
        'https://login.lk21official.cc/auth/callback?code=do-not-log');
      expect(isAllowedAgeVerificationCallback(callback, true), isTrue);
      expect(isAllowedAgeVerificationCallback(callback, false), isFalse);
    });

    test('does not allow lookalike, unrelated or insecure hosts', () {
      for (final url in <String>[
        'https://login.lk21official.cc.evil.test/return',
        'https://fake-login.lk21official.cc/return',
        'https://login.lk21official.cc@evil.test/return',
        'http://login.lk21official.cc/return',
        'https://login.lk21official.cc:8443/return',
        'https://other.example.org/return',
      ]) {
        expect(isAllowedAgeVerificationCallback(Uri.parse(url), true),
            isFalse, reason: url);
      }
    });
  });
}
