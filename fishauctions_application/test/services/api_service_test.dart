import 'package:fishauctions_application/services/api_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = ApiService.instance;

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('ApiService token storage', () {
    test('reports no tokens before login', () async {
      expect(await api.hasTokens, isFalse);
      expect(await api.getAccessToken(), isNull);
    });

    test('persists and reads back both tokens', () async {
      await api.saveTokens('access-1', 'refresh-1');

      expect(await api.getAccessToken(), 'access-1');
      expect(await api.getRefreshToken(), 'refresh-1');
      expect(await api.hasTokens, isTrue);
    });

    test('clearTokens removes everything', () async {
      await api.saveTokens('access-1', 'refresh-1');
      await api.clearTokens();

      expect(await api.hasTokens, isFalse);
      expect(await api.getAccessToken(), isNull);
      expect(await api.getRefreshToken(), isNull);
    });

    test('the Dio base URL targets the mobile API namespace', () {
      expect(api.dio.options.baseUrl, endsWith('/api/mobile/'));
    });
  });
}
