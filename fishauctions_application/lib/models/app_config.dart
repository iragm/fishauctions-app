/// Deployment-wide configuration, parsed from `GET /api/mobile/config/`.
///
/// This endpoint is **public** (no auth) and lets one app binary serve any
/// deployment (a fork's own Square account/environment) without baking Square
/// config into the build. The values here are all *public* integrator config —
/// the secret, per-seller Square access token still arrives only in the
/// `/payments/create/` response and is never stored.
class AppConfig {
  const AppConfig({
    required this.squareApplicationId,
    required this.squareEnvironment,
    required this.googleServerClientId,
    required this.brandName,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
    squareApplicationId: _str(json['square_application_id']),
    squareEnvironment: _str(json['square_environment']),
    googleServerClientId: _str(json['google_server_client_id']),
    brandName: _str(json['brand_name']),
  );

  /// The deployment's public Square Application ID used to initialize the
  /// Square SDK. Environment-specific (`sandbox-sq0idb-…` vs `sq0idp-…`), so it
  /// must agree with [squareEnvironment]. Empty when the deployment has no
  /// Square account configured — [hasSquare] is false and Tap to Pay is off.
  final String squareApplicationId;

  /// `sandbox` | `production`. Informational only: the native
  /// `MobilePaymentsSdk.initialize` derives the environment from the app-id
  /// prefix, so this is used for logging/sanity, not passed to init.
  final String squareEnvironment;

  /// Google (Web) OAuth client id for native sign-in. Not consumed yet — the
  /// app still reads it from a compile-time dart-define; carried here for the
  /// eventual move to fully server-driven config.
  final String googleServerClientId;

  /// Deployment label (e.g. `staging`), for logging/diagnostics.
  final String brandName;

  /// Whether this deployment can do Tap to Pay at all (has a Square app id).
  bool get hasSquare => squareApplicationId.isNotEmpty;

  static String _str(Object? v) => v == null ? '' : v.toString();
}
