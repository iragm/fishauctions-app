import '../config/environment.dart';

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
    this.appleSignInEnabled = false,
    this.termsPath = defaultTermsPath,
    this.privacyPath = '',
    this.firebase,
    this.voice,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
    squareApplicationId: _str(json['square_application_id']),
    squareEnvironment: _str(json['square_environment']),
    googleServerClientId: _str(json['google_server_client_id']),
    appleSignInEnabled: json['apple_sign_in_enabled'] == true,
    brandName: _str(json['brand_name']),
    termsPath: _pathOr(json['terms_url'], defaultTermsPath),
    privacyPath: _pathOr(json['privacy_policy_url'], ''),
    firebase: FirebaseClientConfig.tryParse(json['firebase']),
    voice: json['voice'] is Map<String, dynamic>
        ? json['voice'] as Map<String, dynamic>
        : null,
  );

  /// Where this deployment's terms live when config doesn't say. `/tos/`
  /// (`UserAgreement`) has existed on the site since long before the app, and a
  /// signup screen with no terms link is an App Store rejection — so the
  /// fallback is the known-good path rather than nothing.
  static const String defaultTermsPath = '/tos/';

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
  /// Not a secret (it ships in every web page's GSI button). Empty → the login
  /// screen hides the "Sign in with Google" button entirely.
  final String googleServerClientId;

  /// Whether this deployment has django-allauth's `apple` provider configured
  /// (Services ID, team id, key id and the signing key). A boolean rather than
  /// an id because, unlike Google, the app needs no client id at runtime: the
  /// native flow's audience is the app's own bundle id, which the *backend*
  /// must be told about — see `BACKEND_SPEC.md` Part SOCIAL.
  ///
  /// The button additionally requires iOS 13+; `SocialAuthService` checks that
  /// separately, so this being true doesn't guarantee the button appears.
  final bool appleSignInEnabled;

  // `facebook_app_id` is ignored. Facebook login was removed on 2026-08-10
  // (Facebook doesn't verify the email addresses it returns), and the key is
  // deliberately not parsed rather than parsed-and-unused, so nothing can
  // quietly start gating a button on it again. The backend may keep serving it
  // for the website's own allauth config; unknown keys are ignored here anyway.

  /// The deployment's brand, shown as the app-bar title and drawer header
  /// (see `WebViewScreen`). Empty → the UI falls back to the compile-time
  /// `AppConstants.appName`. For this deployment it equals the site domain.
  final String brandName;

  /// Site-relative path to this deployment's terms, e.g. `/tos/`. Never empty —
  /// falls back to [defaultTermsPath]. Shown on the login and signup screens,
  /// which is where an account is created and therefore where the App Store
  /// expects the link.
  final String termsPath;

  /// Site-relative path to this deployment's privacy policy, or empty when the
  /// deployment hasn't published one — in which case the app shows no privacy
  /// link rather than a dead one. Apple requires this link in-app for any app
  /// with account registration, so an empty value is a submission blocker, not
  /// a style choice (BACKEND_SPEC.md Part L).
  final String privacyPath;

  /// Whether there's a privacy policy to link to.
  bool get hasPrivacyPolicy => privacyPath.isNotEmpty;

  /// Public Firebase *client* config for push, or null when this deployment
  /// has no push configured (then push stays inert → email fallback).
  /// Delivered here — like [squareApplicationId] — so one binary serves any
  /// deployment without a bundled `google-services.json`. See `PUSH.md`.
  final FirebaseClientConfig? firebase;

  /// The `voice` block — anchor keywords, confidence weights and thresholds for
  /// voice-driven set winners, or null when the deployment hasn't configured
  /// one (the app then uses `bundledVoiceGrammar()`).
  ///
  /// Kept as a raw map rather than parsed here because it is *tuning data*,
  /// not app config: which words a given auctioneer uses is exactly what a
  /// deployment will want to change without an app release, and
  /// `VoiceGrammar.fromJson` merges it over the bundled default field by
  /// field. See `VOICE.md` §3 and `BACKEND_SPEC.md` Part VOICE-3.
  final Map<String, dynamic>? voice;

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

  /// Normalizes a config URL to a **site-relative path** so the app can load it
  /// in its own restricted WebView against `EnvironmentConfig.webBaseUrl`. The
  /// backend may send either form; an absolute URL pointing somewhere else
  /// entirely is rejected in favour of [fallback], because these links are
  /// rendered inside the login trap and must not become an escape hatch to an
  /// arbitrary host.
  static String _pathOr(Object? raw, String fallback) {
    final value = _str(raw);
    if (value.isEmpty) {
      return fallback;
    }
    if (value.startsWith('/') && !value.startsWith('//')) {
      return value;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return fallback;
    }
    final path = uri.path.isEmpty ? '/' : uri.path;
    return uri.host == Uri.parse(EnvironmentConfig.webBaseUrl).host
        ? path
        : fallback;
  }
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
