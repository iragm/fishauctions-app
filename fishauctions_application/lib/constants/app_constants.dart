/// Application-wide constants.
///
/// Network configuration lives in EnvironmentConfig (per-flavor), not here —
/// keep environment-specific values out of this file so they can't drift.
class AppConstants {
  const AppConstants._();

  /// Human-readable app name shown in the UI.
  static const String appName = 'FishAuctions';

  /// App version. Keep in sync with `version` in pubspec.yaml.
  static const String appVersion = '1.0.0';
}
