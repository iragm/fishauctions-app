import 'package:fishauctions_application/models/payment_context.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _base({
  String amount = '15.00',
  String currency = 'USD',
  String? appId = 'sandbox-sq0idb-abc',
}) => {
  'amount': amount,
  'currency': currency,
  'access_token': 'tok',
  'location_id': 'loc',
  'idempotency_key': 'key-1',
  'reference_id': 'ref-1',
  'square_application_id': ?appId,
};

void main() {
  group('PaymentContext.fromJson', () {
    test('parses a full response', () {
      final ctx = PaymentContext.fromJson(_base());
      expect(ctx.amountCents, 1500);
      expect(ctx.amountDisplay, '15.00');
      expect(ctx.currency, 'USD');
      expect(ctx.accessToken, 'tok');
      expect(ctx.locationId, 'loc');
      expect(ctx.idempotencyKey, 'key-1');
      expect(ctx.referenceId, 'ref-1');
      expect(ctx.applicationId, 'sandbox-sq0idb-abc');
    });

    test('square_application_id is optional (sourced from config)', () {
      final ctx = PaymentContext.fromJson(_base(appId: null));
      expect(ctx.applicationId, isNull);
    });

    test('empty square_application_id is treated as absent', () {
      final ctx = PaymentContext.fromJson(_base(appId: ''));
      expect(ctx.applicationId, isNull);
    });

    test('defaults currency to USD', () {
      final json = _base()..remove('currency');
      expect(PaymentContext.fromJson(json).currency, 'USD');
    });

    for (final missing in [
      'amount',
      'access_token',
      'location_id',
      'idempotency_key',
      'reference_id',
    ]) {
      test('throws when $missing is missing', () {
        final json = _base()..remove(missing);
        expect(
          () => PaymentContext.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });
    }

    test('rejects an empty reference_id', () {
      final json = _base()..['reference_id'] = '';
      expect(
        () => PaymentContext.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('amountLabel', () {
    String label(String amount, String currency) => PaymentContext.fromJson(
      _base(amount: amount, currency: currency),
    ).amountLabel;

    test('uses a symbol for common currencies', () {
      expect(label('15.00', 'USD'), r'$15.00');
      expect(label('15.00', 'CAD'), r'$15.00');
      expect(label('9.50', 'EUR'), '€9.50');
      expect(label('9.50', 'GBP'), '£9.50');
      expect(label('1500', 'JPY'), '¥1500');
    });

    test('falls back to the ISO code for other currencies', () {
      expect(label('15.00', 'MXN'), 'MXN 15.00');
    });
  });

  group('minor-unit money math (via amountCents)', () {
    int cents(String amount, {String currency = 'USD'}) =>
        PaymentContext.fromJson(
          _base(amount: amount, currency: currency),
        ).amountCents;

    test('exact 2-decimal amounts', () {
      expect(cents('15.00'), 1500);
      expect(cents('0.07'), 7); // no binary-float drift
      expect(cents('1234.56'), 123456);
    });

    test('pads/normalizes short or whole amounts', () {
      expect(cents('5'), 500);
      expect(cents('5.1'), 510);
      expect(cents('.5'), 50);
    });

    test('JPY is zero-decimal', () {
      expect(cents('1500', currency: 'JPY'), 1500);
      expect(cents('1500', currency: 'jpy'), 1500);
    });

    test('rounds half-up when given excess precision', () {
      expect(cents('1.005'), 101); // 3rd decimal 5 → round up
      expect(cents('1.004'), 100); // 3rd decimal 4 → round down
      expect(cents('1500.5', currency: 'JPY'), 1501); // .5 → up for zero-dec
    });

    test('rejects malformed amounts', () {
      for (final bad in ['abc', '1.2.3', '1,000.00', '-5.00', '']) {
        expect(
          () => cents(bad),
          throwsA(isA<FormatException>()),
          reason: 'should reject "$bad"',
        );
      }
    });
  });
}
