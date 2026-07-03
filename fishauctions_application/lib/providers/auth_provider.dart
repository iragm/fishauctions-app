import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_models.dart';
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

  Future<void> loginWithGoogle(String idToken) async {
    state = await AsyncValue.guard(
      () => AuthService.instance.loginWithGoogle(idToken),
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
