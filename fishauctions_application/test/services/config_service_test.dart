import 'package:fishauctions_application/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig.fromJson', () {
    test('parses the live config shape', () {
      final config = AppConfig.fromJson({
        'square_application_id': 'sandbox-sq0idb-abc123',
        'square_environment': 'sandbox',
        'google_server_client_id': 'gcid-123',
        'brand_name': 'staging',
      });

      expect(config.squareApplicationId, 'sandbox-sq0idb-abc123');
      expect(config.squareEnvironment, 'sandbox');
      expect(config.googleServerClientId, 'gcid-123');
      expect(config.brandName, 'staging');
      expect(config.hasSquare, isTrue);
      expect(config.squareConfigConsistent, isTrue);
    });

    group('squareConfigConsistent', () {
      test('sandbox id + sandbox env is consistent', () {
        final config = AppConfig.fromJson({
          'square_application_id': 'sandbox-sq0idb-abc',
          'square_environment': 'sandbox',
        });
        expect(config.squareConfigConsistent, isTrue);
      });

      test('production id + production env is consistent', () {
        final config = AppConfig.fromJson({
          'square_application_id': 'sq0idp-abc',
          'square_environment': 'production',
        });
        expect(config.squareConfigConsistent, isTrue);
      });

      test('production id declared sandbox is a mismatch', () {
        final config = AppConfig.fromJson({
          'square_application_id': 'sq0idp-abc',
          'square_environment': 'sandbox',
        });
        expect(config.squareConfigConsistent, isFalse);
      });

      test('sandbox id declared production is a mismatch', () {
        final config = AppConfig.fromJson({
          'square_application_id': 'sandbox-sq0idb-abc',
          'square_environment': 'production',
        });
        expect(config.squareConfigConsistent, isFalse);
      });

      test('no app id is trivially consistent', () {
        final config = AppConfig.fromJson({'square_environment': 'production'});
        expect(config.squareConfigConsistent, isTrue);
      });

      test('unrecognized environment is not flagged', () {
        final config = AppConfig.fromJson({
          'square_application_id': 'sq0idp-abc',
          'square_environment': '',
        });
        expect(config.squareConfigConsistent, isTrue);
      });
    });

    test('hasSquare is false when the app id is empty', () {
      final config = AppConfig.fromJson({
        'square_application_id': '',
        'square_environment': '',
      });
      expect(config.hasSquare, isFalse);
    });

    test('hasSquare is false when the app id is absent', () {
      final config = AppConfig.fromJson(const {});
      expect(config.squareApplicationId, '');
      expect(config.hasSquare, isFalse);
      expect(config.brandName, '');
    });

    test('coerces non-string values to strings', () {
      final config = AppConfig.fromJson({'brand_name': 123});
      expect(config.brandName, '123');
    });
  });
}
