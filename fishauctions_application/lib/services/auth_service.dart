import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

import '../models/auth_models.dart';
import '../models/social_provider.dart';
import '../utils/device_identity.dart';
import '../utils/secure_storage.dart';
import 'api_service.dart';
import 'last_page_service.dart';
import 'offline_sync_service.dart';
import 'push_prompt_service.dart';
import 'push_service.dart';
import 'social_auth_service.dart';
import 'square_payment_service.dart';
import 'tap_to_pay_service.dart';

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

  /// Log in with a credential from a native social sign-in (Google or Apple).
  ///
  /// The backend verifies the provider token and runs django-allauth's
  /// socialaccount pipeline, which either signs the user in — returning the
  /// same JWT pair a password login produces — or reports that it needs more
  /// from the user before it can. That second case is not an error and is the
  /// whole reason this returns [SocialLoginResult] rather than an [AppUser]:
  ///
  /// - **An email the provider hasn't verified** must be confirmed before it
  ///   can be trusted, or anyone could take over an account by signing up to
  ///   the provider with someone else's address. (This is exactly why Facebook
  ///   login was dropped on 2026-08-10 — it never verifies them, so every
  ///   Facebook sign-in was this case.)
  /// - **The address already belongs to another account**, which allauth has to
  ///   resolve by linking rather than by silently signing someone in.
  ///
  /// In both cases allauth already has the right web flow, so the backend
  /// returns a `continue_url` and the app hands the user to it in the
  /// restricted allauth WebView instead of re-implementing email collection and
  /// confirmation natively. `pending_token` is what turns the finished web flow
  /// back into a JWT pair — see [completeSocialLogin].
  ///
  /// Backend endpoint: POST /api/mobile/auth/social/ (BACKEND_SPEC Part SOCIAL)
  Future<SocialLoginResult> loginWithSocial(SocialCredential credential) async {
    final res = await _api.dio.post('auth/social/', data: credential.toJson());
    final data = res.data as Map<String, dynamic>;
    final continueUrl = data['continue_url'] as String?;
    if (continueUrl != null && continueUrl.isNotEmpty) {
      return SocialLoginResult.needsWeb(
        continueUrl: continueUrl,
        pendingToken: data['pending_token'] as String? ?? '',
        detail: data['detail'] as String?,
      );
    }
    return SocialLoginResult.signedIn(await _storeTokensAndFetchUser(data));
  }

  /// Exchanges the `pending_token` from a [SocialLoginResult.needsWeb] for a
  /// JWT pair, once the user has finished the web continuation.
  ///
  /// Throws if the flow wasn't actually completed — the caller treats that as
  /// "the user backed out", not as a failure worth an error message.
  Future<AppUser> completeSocialLogin(String pendingToken) async {
    final res = await _api.dio.post(
      'auth/social/complete/',
      data: {'pending_token': pendingToken},
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
    // Drop the reader subscription and the previous user's Tap to Pay
    // eligibility, so the next account doesn't inherit a drawer entry (or a
    // pre-authorized reader) that belongs to someone else. Apple's terms
    // acceptance is deliberately *not* touched: it's a property of the device
    // and the Apple Account, not of our login, and it's read from Apple every
    // time anyway (requirement 1.6).
    TapToPayService.instance.reset();
    // So the next Google sign-in shows the account picker instead of silently
    // reusing the signed-out account. Never throws.
    await SocialAuthService.instance.signOut();
    // Stop push notifications reaching this device — a signed-out phone
    // showing the previous user's "invoice ready" is a privacy bug. Must run
    // while the JWT still exists; best-effort beyond that.
    await unregisterThisDevice();
    // Offline auction data (and any still-unsynced changes) belong to this
    // account — the next sign-in must not inherit them.
    await OfflineSyncService.instance.stopAndClear();
    // Where the last session was browsing is this account's business too —
    // the next sign-in starts at the home page, not someone else's lot.
    await LastPageService.instance.clear();
    // "This phone already declined notifications" was an answer for the
    // previous account, not the next one.
    await PushPromptService.instance.clear();
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
      appVersion: await DeviceIdentity.appVersion(),
      fcmToken: await PushService.instance.currentToken(),
    );
  }

  /// Register or update this device on the backend. [fcmToken] enables push
  /// notifications for this install when present (omitted while null — the
  /// backend keeps whatever it has).
  Future<void> registerDevice({
    required String deviceUuid,
    required String deviceName,
    required String platform,
    required String appVersion,
    String? fcmToken,
  }) async {
    try {
      await _api.dio.post(
        'devices/register/',
        data: {
          'device_uuid': deviceUuid,
          'device_name': deviceName,
          'platform': platform,
          'app_version': appVersion,
          if (fcmToken != null && fcmToken.isNotEmpty) 'fcm_token': fcmToken,
        },
      );
    } on DioException catch (e) {
      // Non-fatal — log and continue.
      _log.w('Device registration failed: ${e.response?.statusCode}');
    }
  }

  /// Clears this device's push token on the backend
  /// (`POST /api/mobile/devices/unregister/`) so no further notifications
  /// reach it. Called during sign-out, before the JWT is dropped.
  /// Best-effort: deployments without the endpoint yet just 404.
  Future<void> unregisterThisDevice() async {
    try {
      await _api.dio.post(
        'devices/unregister/',
        data: {'device_uuid': await DeviceIdentity.uuid()},
      );
    } on DioException catch (e) {
      _log.w('Device unregister failed: ${e.response?.statusCode}');
    } on Object catch (e) {
      _log.w('Device unregister failed: $e');
    }
  }
}
