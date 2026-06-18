enum Environment { dev, staging, prod }

class EnvironmentConfig {
  // Resolved at compile time via --dart-define=FLAVOR=dev|staging|prod
  // Falls back to dev so plain `flutter run` still works.
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
