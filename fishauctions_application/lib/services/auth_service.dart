import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

import '../models/auth_models.dart';
import '../utils/device_identity.dart';
import 'api_service.dart';
import 'square_payment_service.dart';

final _log = Logger();

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final _api = ApiService.instance;

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
    return fetchCurrentUser();
  }

  /// Fetch the authenticated user's profile from /auth/me/.
  Future<AppUser> fetchCurrentUser() async {
    final res = await _api.dio.get('auth/me/');
    return AppUser.fromJson(res.data as Map<String, dynamic>);
  }

  /// Clear stored tokens and release the Square authorization. The WebView
  /// cookie session is cleared separately by the WebView screen.
  Future<void> logout() async {
    // Best-effort: a device left authorized for a seller after sign-out is a
    // security risk, but a deauthorize failure must not block logout.
    try {
      await SquarePaymentService.instance.deauthorize();
    } on Object catch (e) {
      _log.w('Square deauthorize on logout failed: $e');
    }
    await _api.clearTokens();
  }

  /// Returns a user if valid tokens exist, null otherwise.
  Future<AppUser?> tryRestoreSession() async {
    if (!await _api.hasTokens) {
      return null;
    }
    try {
      return await fetchCurrentUser();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // Access token expired — try refresh.
        final refreshed = await _api.refreshTokens();
        if (refreshed) {
          return fetchCurrentUser();
        }
      }
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
