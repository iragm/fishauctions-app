import 'package:fishauctions_application/utils/lot_qr.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLotQr', () {
    test('parses the canonical label QR URL', () {
      expect(parseLotQr('https://auction.fish/qr/12345/'), 12345);
    });

    test('accepts any deployment host and http', () {
      // Labels encode whatever domain printed them — often production while
      // the app points at staging.
      expect(parseLotQr('https://staging.auction.fish/qr/7/'), 7);
      expect(parseLotQr('http://example.org/qr/42/'), 42);
    });

    test('tolerates a missing trailing slash and whitespace', () {
      expect(parseLotQr(' https://auction.fish/qr/99 '), 99);
    });

    test('rejects everything that is not a lot QR', () {
      expect(parseLotQr(null), isNull);
      expect(parseLotQr(''), isNull);
      expect(parseLotQr('hello world'), isNull);
      expect(parseLotQr('https://auction.fish/lots/123/'), isNull);
      expect(parseLotQr('https://auction.fish/qr/'), isNull);
      expect(parseLotQr('https://auction.fish/qr/abc/'), isNull);
      expect(parseLotQr('https://auction.fish/qr/12/extra/'), isNull);
      expect(parseLotQr('https://auction.fish/qr/-5/'), isNull);
      expect(parseLotQr('https://auction.fish/qr/0/'), isNull);
      // Wrong scheme — a WiFi QR or deep link isn't a lot label.
      expect(parseLotQr('fishauctions://qr/12/'), isNull);
    });
  });
}
