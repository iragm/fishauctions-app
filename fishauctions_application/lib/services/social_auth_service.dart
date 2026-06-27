import 'package:google_sign_in/google_sign_in.dart';

import '../config/environment.dart';

/// Thrown when Google sign-in can't proceed for a configuration/platform
/// reason (as opposed to the user simply cancelling, which returns null).
class GoogleSignInUnavailable implements Exception {
  GoogleSignInUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Wraps the native Google Sign-In SDK. Google blocks its OAuth/One-Tap flows
/// inside embedded WebViews, so the app can't reuse the website's Google
/// button; instead it signs in natively here and hands the resulting ID token
/// to the backend, which verifies it and issues a JWT.
class SocialAuthService {
  SocialAuthService._();
  static final SocialAuthService instance = SocialAuthService._();

  final _google = GoogleSignIn.instance;
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    if (EnvironmentConfig.googleServerClientId.isEmpty) {
      throw GoogleSignInUnavailable(
        'Google sign-in is not configured for this build.',
      );
    }
    // serverClientId is the Web OAuth client id; it makes the SDK mint an ID
    // token whose audience the backend can verify. initialize() is required
    // before authenticate() in google_sign_in v7 and is safe to call once.
    await _google.initialize(
      serverClientId: EnvironmentConfig.googleServerClientId,
    );
    _initialized = true;
  }

  /// Runs the interactive Google sign-in and returns an OpenID Connect ID
  /// token for the chosen account, or null if the user cancelled. Throws
  /// [GoogleSignInUnavailable] when the SDK can't run on this device/build.
  Future<String?> signInForIdToken() async {
    await _ensureInitialized();
    if (!_google.supportsAuthenticate()) {
      throw GoogleSignInUnavailable(
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
      throw GoogleSignInUnavailable('Google sign-in failed: ${e.code.name}.');
    }
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw GoogleSignInUnavailable(
        'Google did not return an ID token. Check the OAuth configuration.',
      );
    }
    return idToken;
  }

  /// Clears the cached Google account so the next sign-in shows the picker.
  /// Best-effort; never throws.
  Future<void> signOut() async {
    try {
      if (_initialized) {
        await _google.signOut();
      }
    } on Object {
      // Sign-out is best-effort; ignore SDK errors.
    }
  }
}
