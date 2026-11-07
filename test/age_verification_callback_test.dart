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

    test('also permits the observed legacy series login callback only during consent', () {
      final callback = Uri.parse(
        'https://login.lk21online.de/oauth/complete?code=PRIVATE');
      expect(isAllowedAgeVerificationCallback(callback, true), isTrue);
      expect(isAllowedAgeVerificationCallback(callback, false), isFalse);
    });

    test('refreshes source only once after an actual Google return', () {
      expect(shouldRefreshAfterGoogleReturn(
        awaitingGoogleReturn: true,
        isOriginalSource: true,
        isKnownSeriesSource: false,
      ), isTrue);
      expect(shouldRefreshAfterGoogleReturn(
        awaitingGoogleReturn: true,
        isOriginalSource: false,
        isKnownSeriesSource: true,
      ), isTrue);
      expect(shouldRefreshAfterGoogleReturn(
        awaitingGoogleReturn: false,
        isOriginalSource: true,
        isKnownSeriesSource: false,
      ), isFalse);
      expect(shouldRefreshAfterGoogleReturn(
        awaitingGoogleReturn: true,
        isOriginalSource: false,
        isKnownSeriesSource: false,
      ), isFalse);
    });

    test('Google consent YouTube account host only during active sign-in', () {
      final consent = Uri.parse('https://accounts.youtube.com/signin?state=PRIVATE');
      expect(isAllowedGoogleConsentHost(consent, true), isTrue);
      expect(isAllowedGoogleConsentHost(consent, false), isFalse);
    });

    test('Indonesian Google account consent host only during sign-in', () {
      final consent = Uri.parse(
        'https://accounts.google.co.id/consent?state=SECRET');
      expect(isAllowedGoogleConsentHost(consent, true), isTrue);
      expect(isAllowedGoogleConsentHost(consent, false), isFalse);
    });

    test('Indonesian account login host rejects impostors', () {
      for (final url in <String>[
        'https://accounts.google.co.id.evil.test/consent',
        'https://fake-accounts.google.co.id/consent',
        'https://accounts.google.co.id@evil.test/consent',
        'http://accounts.google.co.id/consent',
        'https://accounts.google.co.id:8443/consent',
      ]) {
        expect(isAllowedGoogleConsentHost(Uri.parse(url), true),
            isFalse, reason: url);
      }
    });

    test('Google consent does not permit lookalike or other YouTube hosts', () {
      for (final url in <String>[
        'https://accounts.youtube.com.evil.test/signin',
        'https://youtube.com/watch?v=1',
        'https://www.youtube.com/',
        'https://other.youtube.com/',
        'http://accounts.youtube.com/signin',
        'https://accounts.youtube.com:8443/signin',
        'https://accounts.youtube.com@evil.test/signin',
      ]) {
        expect(isAllowedGoogleConsentHost(Uri.parse(url), true),
            isFalse, reason: url);
      }
    });

    test('does not allow lookalike, unrelated or insecure hosts', () {
      for (final url in <String>[
        'https://login.lk21official.cc.evil.test/return',
        'https://login.lk21online.de.evil.test/return',
        'https://fake-login.lk21online.de/return',
        'http://login.lk21online.de/return',
        'https://login.lk21online.de:8443/return',
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
