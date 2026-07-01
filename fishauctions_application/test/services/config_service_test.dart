import 'package:fishauctions_application/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig.fromJson', () {
    test('parses the live config shape', () {
      final config = AppConfig.fromJson({
        'square_application_id': 'sandbox-sq0idb-abc123',
        'square_environment': 'sandbox',
        'google_server_client_id': '',
        'brand_name': 'staging',
      });

      expect(config.squareApplicationId, 'sandbox-sq0idb-abc123');
      expect(config.squareEnvironment, 'sandbox');
      expect(config.googleServerClientId, '');
      expect(config.brandName, 'staging');
      expect(config.hasSquare, isTrue);
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
