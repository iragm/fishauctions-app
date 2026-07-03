import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

import '../models/auth_models.dart';
import '../utils/device_identity.dart';
import '../utils/secure_storage.dart';
import 'api_service.dart';
import 'social_auth_service.dart';
import 'square_payment_service.dart';

final _log = Logger();

const _keyCachedUser = 'cached_user_profile';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final _api = ApiService.instance;
  final _storage = secureStorage;

  /// Log in with username/email + password. Stores tokens and returns the user.
  Future<AppUser> login(String credential, String password) async {
    final res = await _api.dio.post(
      'auth/login/',
      data: {'credential': credential, 'password': password},
    );
    return _storeTokensAndFetchUser(res.data as Map<String, dynamic>);
  }

  /// Log in with a Google ID token obtained from the native Google Sign-In SDK.
  /// The backend verifies the token, links/creates the account, and returns a
  /// JWT pair — the same single session the password login produces.
  /// Backend endpoint: POST /api/mobile/auth/google/  { "id_token": "..." }
  Future<AppUser> loginWithGoogle(String idToken) async {
    final res = await _api.dio.post(
      'auth/google/',
      data: {'id_token': idToken},
    );
    return _storeTokensAndFetchUser(res.data as Map<String, dynamic>);
  }

  Future<AppUser> _storeTokensAndFetchUser(Map<String, dynamic> data) async {
    final pair = TokenPair.fromJson(data);
    await _api.saveTokens(pair.access, pair.refresh);
    final user = await fetchCurrentUser();
    // Every fresh sign-in registers the install; best-effort, never throws.
    await registerThisDevice();
    return user;
  }

  /// Fetch the authenticated user's profile from /auth/me/. The profile is
  /// cached in secure storage so [tryRestoreSession] can restore a signed-in
  /// state when the network is down at launch.
  Future<AppUser> fetchCurrentUser() async {
    final res = await _api.dio.get('auth/me/');
    final data = res.data as Map<String, dynamic>;
    await _storage.write(key: _keyCachedUser, value: jsonEncode(data));
    return AppUser.fromJson(data);
  }

  Future<AppUser?> _cachedUser() async {
    final raw = await _storage.read(key: _keyCachedUser);
    if (raw == null) {
      return null;
    }
    try {
      return AppUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null; // unreadable cache — treat as absent
    }
  }

  /// Clear stored tokens, the cached profile, the Google account picker
  /// state, and the Square authorization. The WebView cookie session is
  /// cleared separately by the WebView screen.
  Future<void> logout() async {
    // Best-effort: a device left authorized for a seller after sign-out is a
    // security risk, but a deauthorize failure must not block logout.
    try {
      await SquarePaymentService.instance.deauthorize();
    } on Object catch (e) {
      _log.w('Square deauthorize on logout failed: $e');
    }
    // So the next Google sign-in shows the account picker instead of silently
    // reusing the signed-out account. Never throws.
    await SocialAuthService.instance.signOut();
    await _api.clearTokens();
    await _storage.delete(key: _keyCachedUser);
  }

  /// Returns the signed-in user, or null when there is no usable session.
  ///
  /// The API client refreshes-and-retries a 401 internally and wipes the
  /// stored tokens only when the refresh token is definitively rejected. So
  /// after a failure here: tokens gone → the session is truly dead; tokens
  /// still present → the failure was transient (offline, 5xx, mid-flight
  /// drop) and we restore the cached profile instead of bouncing a signed-in
  /// user to the login screen. If the session later turns out to be dead, the
  /// first definitive refresh rejection signs the app out globally via
  /// [ApiService.onSessionInvalidated].
  Future<AppUser?> tryRestoreSession() async {
    if (!await _api.hasTokens) {
      return null;
    }
    try {
      return await fetchCurrentUser();
    } on DioException {
      if (await _api.hasTokens) {
        return _cachedUser();
      }
      await _storage.delete(key: _keyCachedUser);
      return null;
    }
  }

  /// Bridge the native JWT session into the WebView's Django/allauth session
  /// so one sign-in authenticates both. Mints a single-use handoff token bound
  /// to the user and returns the URL the WebView should load: the consume view
  /// burns the token and sets the `sessionid` cookie on its redirect, so the
  /// cookie is server-set (HttpOnly intact), never reconstructed in Dart.
  ///
  /// [next] (a same-host path) becomes the post-login landing page. Returns
  /// null if the handoff endpoint is unavailable, so the caller can fall back
  /// to a plain load.
  ///
  /// Backend endpoint: POST /api/mobile/auth/web-session/  → { "handoff_url" }
  Future<String?> createWebSessionHandoffUrl({String? next}) async {
    try {
      final res = await _api.dio.post(
        'auth/web-session/',
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      if (res.statusCode != 200) {
        return null;
      }
      final url = (res.data as Map<String, dynamic>)['handoff_url'] as String?;
      if (url == null || url.isEmpty) {
        return null;
      }
      if (next == null || next.isEmpty) {
        return url;
      }
      // The consume view honours ?next= (same-host only). The handoff_url
      // already carries ?t=<token>, so append next as a second query param.
      final sep = url.contains('?') ? '&' : '?';
      return '$url${sep}next=${Uri.encodeQueryComponent(next)}';
    } on DioException catch (_) {
      // Endpoint unavailable — caller loads the site without pre-auth.
      return null;
    }
  }

  /// Registers the current install using its stable identity. Best-effort;
  /// safe to call repeatedly (the backend upserts on `device_uuid`).
  Future<void> registerThisDevice() async {
    await registerDevice(
      deviceUuid: await DeviceIdentity.uuid(),
      deviceName: DeviceIdentity.deviceName,
      platform: DeviceIdentity.platformTag,
      appVersion: DeviceIdentity.appVersion,
    );
  }

  /// Register or update this device on the backend.
  Future<void> registerDevice({
    required String deviceUuid,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    try {
      await _api.dio.post(
        'devices/register/',
        data: {
          'device_uuid': deviceUuid,
          'device_name': deviceName,
          'platform': platform,
          'app_version': appVersion,
        },
      );
    } on DioException catch (e) {
      // Non-fatal — log and continue.
      _log.w('Device registration failed: ${e.response?.statusCode}');
    }
  }
}
