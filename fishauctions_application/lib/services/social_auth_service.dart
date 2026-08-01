import 'dart:io' show Platform;

import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../models/app_config.dart';
import '../models/social_provider.dart';
import 'config_service.dart';

/// Thrown when a social sign-in can't proceed for a configuration or platform
/// reason — as opposed to the user simply cancelling, which returns null.
class SocialSignInUnavailable implements Exception {
  SocialSignInUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Legacy name for [SocialSignInUnavailable], kept so existing Google call
/// sites and their tests keep compiling.
typedef GoogleSignInUnavailable = SocialSignInUnavailable;

/// Runs the native sign-in flow for Google, Apple and Facebook, and hands the
/// resulting provider credential to the caller.
///
/// **Why native rather than the website's buttons.** Google blocks its OAuth
/// and One Tap flows inside embedded WebViews, so the app can't reuse the web
/// buttons; and on iOS, Apple's App Review guideline 4.8 wants Sign in with
/// Apple offered natively alongside them. The same three providers are also
/// configured on the web through django-allauth, and both paths converge on the
/// same `SocialAccount` rows because the app sends allauth's own provider ids.
///
/// This class does exactly one job: obtain a credential. It never decides who
/// the user is, never creates accounts, and never inspects an email — the
/// backend runs allauth's socialaccount pipeline for all of that.
class SocialAuthService {
  SocialAuthService._();
  static final SocialAuthService instance = SocialAuthService._();

  final _google = GoogleSignIn.instance;
  bool _googleInitialized = false;
  bool _facebookInitialized = false;

  /// Which providers this deployment + device can actually offer, in the order
  /// they should be shown.
  ///
  /// Apple leads on iOS deliberately. Guideline 4.8 requires an equivalent
  /// privacy-preserving option wherever a third-party login sets up the primary
  /// account, and Apple's Human Interface Guidelines expect its button to be
  /// presented at least as prominently as the others — putting it below Google
  /// and Facebook is a documented review flag, not just a style choice.
  Future<List<SocialProvider>> availableProviders(AppConfig? config) async {
    if (config == null) {
      return const [];
    }
    final providers = <SocialProvider>[];
    if (config.appleSignInEnabled && await _appleAvailable()) {
      providers.add(SocialProvider.apple);
    }
    if (config.googleServerClientId.isNotEmpty) {
      providers.add(SocialProvider.google);
    }
    if (config.facebookAppId.isNotEmpty) {
      providers.add(SocialProvider.facebook);
    }
    return providers;
  }

  /// Whether Sign in with Apple can run here. iOS 13+ only; the plugin's
  /// Android path needs a web redirect and a Services ID we deliberately don't
  /// configure (Apple only *requires* the button on its own platforms, and
  /// Android users still have it on the website through allauth).
  Future<bool> _appleAvailable() async {
    if (!Platform.isIOS) {
      return false;
    }
    try {
      return await SignInWithApple.isAvailable();
    } on Object {
      return false;
    }
  }

  /// Runs [provider]'s native sign-in. Returns the credential, or null if the
  /// user cancelled. Throws [SocialSignInUnavailable] when the flow can't start
  /// at all on this device/deployment.
  Future<SocialCredential?> signIn(SocialProvider provider) =>
      switch (provider) {
        SocialProvider.google => _signInWithGoogle(),
        SocialProvider.apple => _signInWithApple(),
        SocialProvider.facebook => _signInWithFacebook(),
      };

  // ── Google ────────────────────────────────────────────────────────────────

  Future<SocialCredential?> _signInWithGoogle() async {
    await _ensureGoogleInitialized();
    if (!_google.supportsAuthenticate()) {
      throw SocialSignInUnavailable(
        'Google sign-in is not supported on this device.',
      );
    }
    final GoogleSignInAccount account;
    try {
      account = await _google.authenticate(
        scopeHint: const ['email', 'profile'],
      );
    } on GoogleSignInException catch (e) {
      // A user-initiated cancel/dismiss is a normal outcome, not an error.
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        return null;
      }
      throw SocialSignInUnavailable('Google sign-in failed: ${e.code.name}.');
    }
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw SocialSignInUnavailable(
        'Google did not return an ID token. Check the OAuth configuration.',
      );
    }
    return SocialCredential(
      provider: SocialProvider.google,
      idToken: idToken,
      email: account.email,
    );
  }

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) {
      return;
    }
    final clientId = (await _config()).googleServerClientId;
    if (clientId.isEmpty) {
      throw SocialSignInUnavailable(
        'Google sign-in is not configured for this deployment.',
      );
    }
    // serverClientId is the Web OAuth client id; it makes the SDK mint an ID
    // token whose audience the backend can verify. initialize() is required
    // before authenticate() in google_sign_in v7 and is safe to call once.
    await _google.initialize(serverClientId: clientId);
    _googleInitialized = true;
  }

  // ── Apple ─────────────────────────────────────────────────────────────────

  Future<SocialCredential?> _signInWithApple() async {
    final nonce = SignInNonce.generate();
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        // Both scopes are requested even though Apple honours them only on the
        // first authorization — see the note on [SocialCredential.email].
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        // Apple embeds the SHA-256 in the identity token's `nonce` claim; the
        // backend recomputes it from the raw value we send alongside.
        nonce: nonce.hashed,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        return null;
      }
      throw SocialSignInUnavailable('Sign in with Apple failed: ${e.message}');
    } on SignInWithAppleException catch (e) {
      throw SocialSignInUnavailable('Sign in with Apple failed: $e');
    }
    final identityToken = credential.identityToken;
    if (identityToken == null || identityToken.isEmpty) {
      throw SocialSignInUnavailable(
        'Apple did not return an identity token. Please try again.',
      );
    }
    return SocialCredential(
      provider: SocialProvider.apple,
      idToken: identityToken,
      authorizationCode: credential.authorizationCode,
      rawNonce: nonce.raw,
      // All three are null on every authorization after the first. That's
      // Apple's design, not a failure — the backend keeps what it was given the
      // first time.
      email: credential.email,
      firstName: credential.givenName,
      lastName: credential.familyName,
    );
  }

  // ── Facebook ──────────────────────────────────────────────────────────────

  Future<SocialCredential?> _signInWithFacebook() async {
    await _ensureFacebookInitialized();
    // Limited Login on iOS: returns a nonce-bound OIDC ID token and — crucially
    // — does **not** touch the advertising identifier, so it raises no App
    // Tracking Transparency prompt. Apple treats a login that triggers ATT for
    // no reason as a dark pattern, and we have no use for ad attribution.
    //
    // Android's Facebook SDK has no Limited Login, so it takes the classic
    // path and returns an access token the backend verifies against Facebook's
    // `debug_token` endpoint instead.
    final useLimited = Platform.isIOS;
    final nonce = SignInNonce.generate();
    final LoginResult result;
    try {
      result = await FacebookAuth.instance.login(
        // Same as the plugin's default, but stated because it's load-bearing:
        // dropping `email` is what turns every Facebook sign-in into the
        // no-email continuation flow.
        // ignore: avoid_redundant_argument_values
        permissions: const ['email', 'public_profile'],
        loginTracking: useLimited
            ? LoginTracking.limited
            : LoginTracking.enabled,
        // Facebook requires a nonce for limited login and rejects the request
        // without one; it's meaningless on the classic path.
        nonce: useLimited ? nonce.hashed : null,
      );
    } on Object catch (e) {
      throw SocialSignInUnavailable('Facebook sign-in failed: $e');
    }
    switch (result.status) {
      case LoginStatus.cancelled:
        return null;
      case LoginStatus.failed:
        throw SocialSignInUnavailable(
          'Facebook sign-in failed: ${result.message ?? 'unknown error'}',
        );
      case LoginStatus.operationInProgress:
        // A previous attempt's dialog is still up; treat as a cancel rather
        // than stacking a second prompt on top of it.
        return null;
      case LoginStatus.success:
        break;
    }
    final token = result.accessToken;
    if (token == null) {
      throw SocialSignInUnavailable(
        'Facebook did not return a token. Please try again.',
      );
    }
    return switch (token) {
      // The limited token's `tokenString` *is* the OIDC ID token.
      LimitedToken() => SocialCredential(
        provider: SocialProvider.facebook,
        idToken: token.tokenString,
        rawNonce: nonce.raw,
        // Nullable, and routinely null: a Facebook account can have no email,
        // or the user can decline the email permission. The backend decides
        // what to do about that (see BACKEND_SPEC Part SOCIAL) — the app just
        // reports what it got.
        email: token.userEmail,
      ),
      ClassicToken() => SocialCredential(
        provider: SocialProvider.facebook,
        accessToken: token.tokenString,
      ),
      _ => throw SocialSignInUnavailable(
        'Facebook returned an unrecognized token type.',
      ),
    };
  }

  Future<void> _ensureFacebookInitialized() async {
    if (_facebookInitialized) {
      return;
    }
    final appId = (await _config()).facebookAppId;
    if (appId.isEmpty) {
      throw SocialSignInUnavailable(
        'Facebook sign-in is not configured for this deployment.',
      );
    }
    // Nothing to initialize on iOS/Android — the SDK reads its app id from
    // Info.plist / AndroidManifest at launch, which is why the id is also a
    // build-time value there (see BACKEND_SPEC Part SOCIAL on why Facebook,
    // unlike Google and Square, can't be fully deployment-configured). The
    // config check above is what keeps a deployment that hasn't set Facebook up
    // from showing a button that would fail.
    _facebookInitialized = true;
  }

  // ── Shared ────────────────────────────────────────────────────────────────

  Future<AppConfig> _config() async {
    try {
      return await ConfigService.instance.load();
    } on Object {
      throw SocialSignInUnavailable(
        'Couldn\'t load sign-in configuration. Check your connection and try '
        'again.',
      );
    }
  }

  /// Clears cached provider sessions so the next sign-in shows the picker
  /// rather than silently reusing the signed-out account. Best-effort per
  /// provider; never throws.
  ///
  /// Apple is deliberately absent: there is no sign-out API, because there's no
  /// app-side session to clear — Sign in with Apple hands over a credential and
  /// keeps its state in the system's Apple Account settings.
  Future<void> signOut() async {
    try {
      if (_googleInitialized) {
        await _google.signOut();
      }
    } on Object {
      // Sign-out is best-effort; ignore SDK errors.
    }
    try {
      await FacebookAuth.instance.logOut();
    } on Object {
      // Ditto — and this also throws harmlessly when Facebook was never used.
    }
  }
}
