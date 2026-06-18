enum Environment { dev, staging, prod }

class EnvironmentConfig {
  // Resolved at compile time via --dart-define=FLAVOR=dev|staging|prod.
  //
  // IMPORTANT: the Gradle product flavor (--flavor) only selects the Android
  // applicationId; it does NOT reach Dart. You MUST also pass
  // --dart-define=FLAVOR=<flavor> or this resolves to the default below and a
  // prod build would silently talk to the staging backend. CI and the
  // documented run/build commands always pass it together.
  //
  // Falls back to dev so a bare `flutter run` still works for local dev.
  static const _flavor = String.fromEnvironment('FLAVOR', defaultValue: 'dev');

  static Environment get currentEnvironment {
    switch (_flavor) {
      case 'prod':
        return Environment.prod;
      case 'staging':
        return Environment.staging;
      default:
        return Environment.dev;
    }
  }

  static String get apiBaseUrl {
    switch (currentEnvironment) {
      case Environment.dev:
      case Environment.staging:
        return 'https://staging.auction.fish';
      case Environment.prod:
        return 'https://auction.fish';
    }
  }

  // The web UI the WebView loads. Same host as the API.
  static String get webBaseUrl => apiBaseUrl;

  static bool get enableLogging => currentEnvironment == Environment.dev;

  // Custom URL scheme Flutter intercepts from the WebView.
  static const String urlScheme = 'fishauctions';
}
