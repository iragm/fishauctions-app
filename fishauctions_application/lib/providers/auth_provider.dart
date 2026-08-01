import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_models.dart';
import '../models/social_provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

/// Holds the currently authenticated user, or null when logged out. This is
/// the single source of truth for "signed in" — the router's auth gate and the
/// WebView session bridging both key off it.
///
/// AsyncValue's loading state is only used for the initial session restore on
/// app start (the router shows the splash screen until it resolves). Login
/// attempts keep the previous state — the login screen shows its own progress
/// UI — so the router never yanks the login screen away mid-submit.
class AuthNotifier extends AsyncNotifier<AppUser?> {
  @override
  Future<AppUser?> build() {
    // A definitive mid-session death (the rotated refresh token was rejected
    // and the tokens wiped) flips the app to signed-out, and the router traps
    // back to the login screen.
    ApiService.instance.onSessionInvalidated = () {
      state = const AsyncData(null);
    };
    return AuthService.instance.tryRestoreSession();
  }

  Future<void> login(String credential, String password) async {
    state = await AsyncValue.guard(
      () => AuthService.instance.login(credential, password),
    );
  }

  /// Signs in with a native social credential (Google, Apple or Facebook).
  ///
  /// Returns the backend's answer so the caller can act on the one outcome this
  /// notifier can't represent: a sign-in that needs the user to finish a web
  /// flow first (supply an email, confirm one). That is not an error state:
  /// the notifier stays signed-out and the login screen takes over, so it must
  /// not go through [AsyncValue.guard], which would show it as a failure.
  ///
  /// Returns null when the exchange failed; the error is then on [state].
  Future<SocialLoginResult?> loginWithSocial(
    SocialCredential credential,
  ) async {
    SocialLoginResult? result;
    state = await AsyncValue.guard(() async {
      result = await AuthService.instance.loginWithSocial(credential);
      // Null keeps the notifier signed-out while the web continuation runs.
      return result!.user;
    });
    return state.hasError ? null : result;
  }

  /// Finishes a [SocialLoginResult.needsWeb] sign-in once the user has
  /// completed the web flow.
  Future<void> completeSocialLogin(String pendingToken) async {
    state = await AsyncValue.guard(
      () => AuthService.instance.completeSocialLogin(pendingToken),
    );
  }

  Future<void> logout() async {
    await AuthService.instance.logout();
    state = const AsyncData(null);
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(AuthService.instance.tryRestoreSession);
  }
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AppUser?>(
  AuthNotifier.new,
);
