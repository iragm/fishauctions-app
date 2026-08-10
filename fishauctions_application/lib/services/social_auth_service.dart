import 'dart:io' show Platform;

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

/// Runs the native sign-in flow for Google and Apple, and hands the resulting
/// provider credential to the caller.
///
/// **Why native rather than the website's buttons.** Google blocks its OAuth
/// and One Tap flows inside embedded WebViews, so the app can't reuse the web
/// buttons; and on iOS, Apple's App Review guideline 4.8 wants Sign in with
/// Apple offered natively alongside them. Both providers are also configured on
/// the web through django-allauth, and both paths converge on the same
/// `SocialAccount` rows because the app sends allauth's own provider ids.
///
/// **Facebook was removed 2026-08-10** and shouldn't come back without a
/// reason that answers this: Facebook doesn't verify the email addresses it
/// hands over, and an unverified address can't be trusted to identify an
/// account — which meant every Facebook sign-in either landed in the web
/// continuation flow or risked attaching a session to the wrong user.
///
/// This class does exactly one job: obtain a credential. It never decides who
/// the user is, never creates accounts, and never inspects an email — the
/// backend runs allauth's socialaccount pipeline for all of that.
class SocialAuthService {
  SocialAuthService._();
  static final SocialAuthService instance = SocialAuthService._();

  final _google = GoogleSignIn.instance;
  bool _googleInitialized = false;

  /// Which providers this deployment + device can actually offer, in the order
  /// they should be shown.
  ///
  /// Apple leads on iOS deliberately. Guideline 4.8 requires an equivalent
  /// privacy-preserving option wherever a third-party login sets up the primary
  /// account, and Apple's Human Interface Guidelines expect its button to be
  /// presented at least as prominently as the others — putting it below Google
  /// is a documented review flag, not just a style choice.
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
  }
}
