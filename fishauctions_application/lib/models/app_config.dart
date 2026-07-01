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

  /// `sandbox` | `production`. Not passed to init (the native
  /// `MobilePaymentsSdk.initialize` derives the environment from the app-id
  /// prefix); used for a sanity check against that prefix — see
  /// [squareConfigConsistent] — and for logging.
  final String squareEnvironment;

  /// Google (Web) OAuth client id for native sign-in, read at launch from
  /// `/api/mobile/config/`. Native Google login asks the SDK for an ID token
  /// whose audience is this id; the backend verifies it against the same id.
  /// Not a secret (it ships in every web page's GSI button). Empty → the
  /// "Continue with Google" button reports sign-in isn't configured here.
  final String googleServerClientId;

  /// The deployment's brand, shown as the app-bar title and drawer header
  /// (see `WebViewScreen`). Empty → the UI falls back to the compile-time
  /// `AppConstants.appName`. For this deployment it equals the site domain.
  final String brandName;

  /// Whether this deployment can do Tap to Pay at all (has a Square app id).
  bool get hasSquare => squareApplicationId.isNotEmpty;

  /// Whether [squareApplicationId] agrees with [squareEnvironment]: sandbox app
  /// ids are prefixed `sandbox-`, production ids are not. A mismatch means the
  /// deployment is misconfigured (e.g. a production id declared `sandbox`),
  /// which would otherwise surface only as an opaque reader failure. True when
  /// there's no app id (nothing to check) or the environment is unrecognized.
  bool get squareConfigConsistent {
    if (squareApplicationId.isEmpty) {
      return true;
    }
    final isSandboxId = squareApplicationId.startsWith('sandbox-');
    switch (squareEnvironment.toLowerCase()) {
      case 'sandbox':
        return isSandboxId;
      case 'production':
        return !isSandboxId;
      default:
        return true;
    }
  }

  static String _str(Object? v) => v == null ? '' : v.toString();
}
