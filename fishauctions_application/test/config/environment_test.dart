import 'package:fishauctions_application/config/environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EnvironmentConfig', () {
    test('defaults to the dev flavor when FLAVOR is not provided', () {
      // `flutter test` runs with no --dart-define=FLAVOR, so the default wins.
      expect(EnvironmentConfig.currentEnvironment, Environment.dev);
    });

    test('the WebView host always matches the API host', () {
      expect(EnvironmentConfig.webBaseUrl, EnvironmentConfig.apiBaseUrl);
    });

    test('base URL is https and has no trailing slash', () {
      final url = EnvironmentConfig.apiBaseUrl;
      expect(url, startsWith('https://'));
      expect(url.endsWith('/'), isFalse);
    });

    test('exposes the custom URL scheme the WebView intercepts', () {
      expect(EnvironmentConfig.urlScheme, 'fishauctions');
    });
  });
}
