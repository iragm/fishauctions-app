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
    final pair = TokenPair.fromJson(res.data as Map<String, dynamic>);
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

  /// Exchange JWT for a Django session cookie so the WebView is authenticated.
  /// Backend endpoint: POST /api/mobile/auth/web-session/
  /// Returns the raw Set-Cookie header value, or null if not yet implemented.
  Future<String?> getWebSessionCookie() async {
    try {
      final res = await _api.dio.post(
        'auth/web-session/',
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
      if (res.statusCode == 200) {
        final cookies = res.headers['set-cookie'];
        return cookies?.join('; ');
      }
    } on DioException catch (_) {
      // Endpoint not yet implemented — WebView will fall back to its own login.
    }
    return null;
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
