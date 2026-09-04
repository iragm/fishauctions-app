import 'package:flutter/foundation.dart' show kDebugMode;

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

  // Whether to build in the developer-facing affordances: diagnostic dumps,
  // reset-to-factory-state buttons, anything that exists to debug the app
  // rather than to run an auction.
  //
  // Off in a release prod build, which is what ships to the App Store and
  // TestFlight: Apple reviews Tap to Pay against a merchant's experience, and a
  // settings screen offering "here is what the SDK reports" and "release this
  // device's authorization" reads as an unfinished build. On for dev and
  // staging, and for any debug build whatever it points at.
  //
  // Overridable per build with `--dart-define=DEV_TOOLS=true|false`, because
  // the flavor alone gets this wrong for Tap to Pay: Square only issues live
  // seller credentials on production, so the build that most needs the
  // diagnostics dump is a prod-flavored one on a real phone. `true` puts the
  // tools into such a build without pointing it at staging; `false` takes them
  // out of a dev build (e.g. to check what a reviewer will see).
  //
  // Deliberately `const`: a `false` here lets the compiler drop the guarded
  // widgets from a prod build entirely rather than merely not showing them.
  static const bool enableDeveloperTools = bool.fromEnvironment(
    'DEV_TOOLS',
    defaultValue: kDebugMode || _flavor != 'prod',
  );

  // Custom URL scheme Flutter intercepts from the WebView.
  static const String urlScheme = 'fishauctions';
}
