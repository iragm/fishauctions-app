import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_models.dart';
import '../services/auth_service.dart';

/// Holds the currently authenticated user, or null when logged out.
/// AsyncValue is used so the UI can show a loading state on app start.
class AuthNotifier extends AsyncNotifier<AppUser?> {
  @override
  Future<AppUser?> build() => AuthService.instance.tryRestoreSession();

  Future<void> login(String credential, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => AuthService.instance.login(credential, password),
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
