import 'package:flutter_test/flutter_test.dart';

import '../lib/source_domain_config.dart';

void main() {
  group('SourceDomainConfig.isKnownSourceHost', () {
    test('accepts existing LK21 film and series hosts', () {
      expect(SourceDomainConfig.isKnownSourceHost('tv12.lk21official.cc'), isTrue);
      expect(SourceDomainConfig.isKnownSourceHost('tv.lk21online.de'), isTrue);
      expect(SourceDomainConfig.isKnownSourceHost('tv9.nontondrama.my'), isTrue);
    });

    test('accepts a rotated numbered LK21 subdomain', () {
      expect(SourceDomainConfig.isKnownSourceHost('tv13.lk21official.cc'), isTrue);
      expect(SourceDomainConfig.isKnownSourceHost('tv99.lk21official.cc'), isTrue);
    });

    test('rejects look-alike and unrelated hosts', () {
      expect(SourceDomainConfig.isKnownSourceHost('lk21official.cc.attacker.example'), isFalse);
      expect(SourceDomainConfig.isKnownSourceHost('fake-lk21official.cc'), isFalse);
      expect(SourceDomainConfig.isKnownSourceHost('example.com'), isFalse);
      expect(SourceDomainConfig.isKnownSourceHost(null), isFalse);
    });
  });
}
