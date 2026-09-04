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

    test('developer tools are on for a debug build outside prod', () {
      // Compile-time const, so a single run can only ever see one build's
      // answer — this one, which `flutter test` builds as debug on the dev
      // flavor, i.e. both halves of the default true. What the const buys is
      // the App Store build: a release prod build with no `DEV_TOOLS` define
      // resolves this to false and drops the guarded widgets outright, so the
      // Tap to Pay troubleshooting block cannot reach a reviewer.
      expect(EnvironmentConfig.enableDeveloperTools, isTrue);
      expect(EnvironmentConfig.currentEnvironment, isNot(Environment.prod));
    });

    test('exposes the custom URL scheme the WebView intercepts', () {
      expect(EnvironmentConfig.urlScheme, 'fishauctions');
    });
  });
}
