import 'package:fishauctions_application/utils/device_identity.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('DeviceIdentity', () {
    test('generates a v4-shaped uuid', () async {
      final id = await DeviceIdentity.uuid();
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            r'[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('is stable across calls (persisted)', () async {
      final first = await DeviceIdentity.uuid();
      final second = await DeviceIdentity.uuid();
      expect(first, second);
    });

    test('exposes a backend-friendly platform tag', () {
      expect(DeviceIdentity.platformTag, anyOf('ios', 'android'));
    });
  });
}
