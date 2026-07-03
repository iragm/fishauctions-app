import 'package:flutter/foundation.dart';

/// Application-wide constants.
///
/// Network configuration lives in EnvironmentConfig (per-flavor), not here —
/// keep environment-specific values out of this file so they can't drift.
class AppConstants {
  const AppConstants._();

  /// User-Agent for every WebView the app hosts (the main shell and the
  /// account screens), carrying the FishAuctionsApp token the backend's
  /// is_mobile_app middleware keys on to drop web chrome (navbar/footer) and
  /// switch to the native bridges. Also reused verbatim for authenticated
  /// download refetches so they look like the same client.
  static final String userAgent =
      'FishAuctionsApp/1.0 (Flutter; ${defaultTargetPlatform.name})';

  /// The brand shown in the UI — the navbar/app-bar title, the drawer header,
  /// and the OS task title. This is the single source of truth for the brand;
  /// forks running their own deployment change it here (and the matching
  /// `android:label` in AndroidManifest.xml, which native code can't read from
  /// Dart). For this deployment it equals the site domain.
  static const String appName = 'auction.fish';

  /// App version. Keep in sync with `version` in pubspec.yaml.
  static const String appVersion = '1.0.0';
}
