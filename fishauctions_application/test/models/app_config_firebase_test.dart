import 'package:fishauctions_application/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _platform(String idKey, String id) => {
  idKey: id,
  'api_key': 'AIzaKey',
  'app_id': '1:123:abc:def',
  'messaging_sender_id': '123',
  'project_id': 'fishauctions-staging',
};

void main() {
  group('AppConfig.firebase parsing', () {
    test('absent firebase block → null (push inert, email fallback)', () {
      final cfg = AppConfig.fromJson({'brand_name': 'auction.fish'});
      expect(cfg.firebase, isNull);
    });

    test('parses android + ios blocks with their target ids', () {
      final cfg = AppConfig.fromJson({
        'firebase': {
          'android': _platform('package_name', 'com.fishauctions.app.staging'),
          'ios': _platform('bundle_id', 'com.fishauctions.app'),
        },
      });
      final android = cfg.firebase!.forPlatform(isIOS: false)!;
      final ios = cfg.firebase!.forPlatform(isIOS: true)!;
      expect(android.applicationId, 'com.fishauctions.app.staging');
      expect(android.appId, '1:123:abc:def');
      expect(ios.applicationId, 'com.fishauctions.app');
      expect(ios.messagingSenderId, '123');
    });

    test('a block missing a required value is dropped', () {
      final incomplete = _platform('package_name', 'com.fishauctions.app')
        ..remove('app_id');
      final cfg = AppConfig.fromJson({
        'firebase': {'android': incomplete},
      });
      // android incomplete → null; no ios → whole block null.
      expect(cfg.firebase, isNull);
    });

    test('one platform present, the other absent', () {
      final cfg = AppConfig.fromJson({
        'firebase': {
          'android': _platform('package_name', 'com.fishauctions.app'),
        },
      });
      expect(cfg.firebase!.forPlatform(isIOS: false), isNotNull);
      expect(cfg.firebase!.forPlatform(isIOS: true), isNull);
    });

    test('non-map firebase value is ignored, not a crash', () {
      final cfg = AppConfig.fromJson({'firebase': 'nope'});
      expect(cfg.firebase, isNull);
    });
  });
}
