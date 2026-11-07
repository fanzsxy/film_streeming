import 'package:flutter_test/flutter_test.dart';
import 'package:filmstream_personal/main.dart';

void main() {
  group('filter page counts are stable while collecting matches', () {
    test('does not expose a 2 or 4 item page during scanning', () {
      expect(completedFilterPages(2, true), 0);
      expect(completedFilterPages(4, true), 0);
      expect(completedFilterPages(19, true), 0);
    });

    test('only complete sets of 20 count as navigable pages', () {
      expect(completedFilterPages(20, true), 1);
      expect(completedFilterPages(24, true), 1);
      expect(completedFilterPages(39, true), 1);
      expect(completedFilterPages(40, true), 2);
      expect(completedFilterPages(44, true), 2);
    });

    test('last page may be short once the source is exhausted', () {
      expect(completedFilterPages(0, false), 0);
      expect(completedFilterPages(4, false), 1);
      expect(completedFilterPages(24, false), 2);
      expect(completedFilterPages(40, false), 2);
    });
  });
}
