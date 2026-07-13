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
    this.firebase,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
    squareApplicationId: _str(json['square_application_id']),
    squareEnvironment: _str(json['square_environment']),
    googleServerClientId: _str(json['google_server_client_id']),
    brandName: _str(json['brand_name']),
    firebase: FirebaseClientConfig.tryParse(json['firebase']),
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

  /// Public Firebase *client* config for push, or null when this deployment
  /// has no push configured (then push stays inert → email fallback).
  /// Delivered here — like [squareApplicationId] — so one binary serves any
  /// deployment without a bundled `google-services.json`. See `PUSH.md`.
  final FirebaseClientConfig? firebase;

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

/// The `firebase` block of `GET /api/mobile/config/` — the public client config
/// for FCM, split by platform. Each deployment (staging / prod backend) returns
/// only its own project's values; the values are the same class as those in a
/// `google-services.json` / `GoogleService-Info.plist` (public, ship in every
/// binary), so serving them here — not baking a config file into the build —
/// keeps one binary able to serve any deployment. The secret half (the FCM
/// service-account JSON) stays server-side. See `PUSH.md`.
class FirebaseClientConfig {
  const FirebaseClientConfig({this.android, this.ios});

  /// Present and complete only when the deployment configured push for that
  /// platform; null otherwise (that platform simply gets no push).
  final FirebaseAppOptions? android;
  final FirebaseAppOptions? ios;

  /// The options for the running platform, or null if this deployment has no
  /// push config for it.
  FirebaseAppOptions? forPlatform({required bool isIOS}) =>
      isIOS ? ios : android;

  static FirebaseClientConfig? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final android = FirebaseAppOptions.tryParse(
      raw['android'],
      idKey: 'package_name',
    );
    final ios = FirebaseAppOptions.tryParse(raw['ios'], idKey: 'bundle_id');
    if (android == null && ios == null) {
      return null;
    }
    return FirebaseClientConfig(android: android, ios: ios);
  }
}

/// One platform's Firebase client options — the four values
/// `FirebaseOptions` needs, plus the applicationId/bundle id the config targets
/// so the app can refuse a config meant for a different build (a dev-flavor
/// install hitting the staging backend). Only exposed when every field is
/// present — a partial block is treated as "no push" rather than a crash.
class FirebaseAppOptions {
  const FirebaseAppOptions({
    required this.applicationId,
    required this.apiKey,
    required this.appId,
    required this.messagingSenderId,
    required this.projectId,
  });

  /// Android `package_name` / iOS `bundle_id` this config is for.
  final String applicationId;
  final String apiKey;
  final String appId;
  final String messagingSenderId;
  final String projectId;

  static FirebaseAppOptions? tryParse(Object? raw, {required String idKey}) {
    if (raw is! Map) {
      return null;
    }
    final opts = FirebaseAppOptions(
      applicationId: AppConfig._str(raw[idKey]),
      apiKey: AppConfig._str(raw['api_key']),
      appId: AppConfig._str(raw['app_id']),
      messagingSenderId: AppConfig._str(raw['messaging_sender_id']),
      projectId: AppConfig._str(raw['project_id']),
    );
    final complete =
        opts.applicationId.isNotEmpty &&
        opts.apiKey.isNotEmpty &&
        opts.appId.isNotEmpty &&
        opts.messagingSenderId.isNotEmpty &&
        opts.projectId.isNotEmpty;
    return complete ? opts : null;
  }
}
