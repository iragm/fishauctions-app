/// Application-wide constants.
///
/// Network configuration lives in EnvironmentConfig (per-flavor), not here —
/// keep environment-specific values out of this file so they can't drift.
class AppConstants {
  const AppConstants._();

  /// The brand shown in the UI — the navbar/app-bar title, the drawer header,
  /// and the OS task title. This is the single source of truth for the brand;
  /// forks running their own deployment change it here (and the matching
  /// `android:label` in AndroidManifest.xml, which native code can't read from
  /// Dart). For this deployment it equals the site domain.
  static const String appName = 'auction.fish';

  /// App version. Keep in sync with `version` in pubspec.yaml.
  static const String appVersion = '1.0.0';
}
