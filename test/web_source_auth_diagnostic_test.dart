import 'package:flutter_test/flutter_test.dart';
import 'package:filmstream_personal/web_source_page.dart';

void main() {
  test('OAuth diagnostics never expose query state or authorization codes', () {
    final url = Uri.parse(
      'https://callback.example.test/oauth/return?code=TOP_SECRET&state=PRIVATE#fragment',
    );
    final message = loginReturnBlockedMessage(url);
    expect(message, contains('callback.example.test'));
    expect(message, isNot(contains('TOP_SECRET')));
    expect(message, isNot(contains('PRIVATE')));
    expect(message, isNot(contains('/oauth/return')));
    expect(message, isNot(contains('fragment')));
  });
}
