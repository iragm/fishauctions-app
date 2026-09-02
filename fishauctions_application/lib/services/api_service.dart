import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../config/environment.dart';
import '../utils/secure_storage.dart';

const _keyAccess = 'jwt_access';
const _keyRefresh = 'jwt_refresh';

final _log = Logger();

/// Posts a refresh token to `auth/refresh/`. See [ApiService.postRefresh].
typedef RefreshPoster = Future<Response<dynamic>> Function(String refresh);

/// A clean Dio (no interceptors) with its own timeout, so a hung refresh can't
/// block forever or recurse back through the auth interceptor that triggered
/// it.
Future<Response<dynamic>> _postRefresh(String refresh) =>
    Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    ).post<dynamic>(
      '${EnvironmentConfig.apiBaseUrl}/api/mobile/auth/refresh/',
      data: {'refresh': refresh},
    );

class ApiService {
  ApiService._() {
    _dio = _buildDio();
  }

  static final ApiService instance = ApiService._();

  late final Dio _dio;
  final _storage = secureStorage;

  /// Tracks an in-flight refresh so concurrent 401s share one call.
  Future<bool>? _pendingRefresh;

  /// Invoked when the session dies mid-use: the refresh token was
  /// definitively rejected and the stored tokens wiped. The auth layer sets
  /// this to flip the app to signed-out (which routes back to the login
  /// screen); until then it's null and session death is silent.
  void Function()? onSessionInvalidated;

  // ── Public Dio instance (use for all API calls) ──────────────────────────

  Dio get dio => _dio;

  // ── Token storage ─────────────────────────────────────────────────────────

  Future<void> saveTokens(String access, String refresh) async {
    await Future.wait([
      _storage.write(key: _keyAccess, value: access),
      _storage.write(key: _keyRefresh, value: refresh),
    ]);
  }

  Future<String?> getAccessToken() => _storage.read(key: _keyAccess);
  Future<String?> getRefreshToken() => _storage.read(key: _keyRefresh);

  Future<void> clearTokens() async {
    await Future.wait([
      _storage.delete(key: _keyAccess),
      _storage.delete(key: _keyRefresh),
    ]);
  }

  Future<bool> get hasTokens async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }

  // ── Token refresh ─────────────────────────────────────────────────────────

  /// Exchanges the stored refresh token for a new access+refresh pair.
  /// Returns true on success.
  ///
  /// **Single-flight, and it has to be.** The backend runs refresh-token
  /// rotation *with* blacklisting, so a token is valid exactly once: two
  /// concurrent refreshes guarantee that the second is rejected, and a
  /// rejection is the one thing that ends a session. Resuming from a long
  /// excursion — an OAuth detour through the authentication session is the
  /// worst case, since it easily outlives the 60-minute access token — wakes
  /// several callers at once (config, check-in, the reader warm-up, the print
  /// heartbeat), every one of them 401s, and without this they would race each
  /// other into a spurious sign-out. Every 401-triggered request queues behind
  /// the one in-flight refresh and is replayed after it.
  Future<bool> refreshTokens() =>
      _pendingRefresh ??= _performRefresh().whenComplete(() {
        _pendingRefresh = null;
      });

  /// Makes sure the stored access token is good for a little while yet,
  /// refreshing it if not. Returns false when there is no usable session, or
  /// when a needed refresh didn't succeed.
  ///
  /// For the callers that cannot rely on a 401 to tell them anything.
  /// `GET /api/mobile/config/` is the reason this exists: it reads the bearer
  /// token *optionally*, so a stale one doesn't fail — it succeeds, and quietly
  /// answers with the signed-out payload. The drawer would then render
  /// signed-out chrome around a perfectly live session, and no retry would ever
  /// fire because nothing went wrong.
  ///
  /// Costs nothing in the common case: the expiry is read out of the token
  /// itself, so a token with time left makes no network call at all.
  Future<bool> ensureFreshAccessToken() async {
    final token = await getAccessToken();
    if (token == null || token.isEmpty) {
      return false;
    }
    final expiry = _accessTokenExpiry(token);
    // An unreadable token has no expiry to trust, so treat it as due: a
    // refresh is cheap and being wrong the other way is silent.
    if (expiry != null &&
        expiry.isAfter(DateTime.now().toUtc().add(_expiryMargin))) {
      return true;
    }
    return refreshTokens();
  }

  /// How much life an access token needs left for [ensureFreshAccessToken] to
  /// let it through — enough to cover the request it is about to be used on.
  static const Duration _expiryMargin = Duration(minutes: 2);

  /// The `exp` claim of a JWT, or null if it can't be read. Signature is not
  /// checked and doesn't need to be: this only decides whether to *ask* for a
  /// new token, and the server is the one that validates.
  static DateTime? _accessTokenExpiry(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) {
        return null;
      }
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = jsonDecode(payload);
      final exp = claims is Map ? claims['exp'] : null;
      if (exp is! int) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    } on Object {
      return null;
    }
  }

  /// How many times a throttled refresh is retried before giving up for now.
  static const int _throttleRetries = 3;

  /// Test seam: posts the refresh token and returns the raw response.
  ///
  /// Exists because the interesting half of [_performRefresh] is its reading
  /// of status codes — 401 ends a session, 400/429/5xx/offline must not — and
  /// getting a specific status out of a real server is not something a unit
  /// test can arrange.
  @visibleForTesting
  RefreshPoster postRefresh = _postRefresh;

  Future<bool> _performRefresh() async {
    final refresh = await getRefreshToken();
    if (refresh == null || refresh.isEmpty) {
      return false;
    }

    for (var attempt = 0; ; attempt++) {
      try {
        final res = await postRefresh(refresh);
        final data = res.data;
        final access = data is Map ? data['access'] : null;
        final newRefresh = data is Map ? data['refresh'] : null;
        if (access is! String || newRefresh is! String) {
          // A 200 with no tokens is a server-side anomaly, not a rejected
          // credential — keep the refresh token so a later attempt can
          // recover.
          _log.w('Token refresh returned an unexpected payload');
          return false;
        }
        await saveTokens(access, newRefresh);
        return true;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        // **429 is never a sign-out.** This endpoint is throttled per IP, and
        // an auction hall is a room full of this app's phones behind one
        // NAT — so being throttled says nothing whatever about *this*
        // session's credentials. Back off with jitter (the jitter matters:
        // those phones resume together and would otherwise retry in lockstep)
        // and try again.
        if (status == 429 && attempt < _throttleRetries) {
          await Future<void>.delayed(_throttleBackoff(e.response, attempt));
          continue;
        }
        // **Only a 401 ends a session**, and only when the token we sent is
        // still the stored one. Anything else — a timeout, an offline phone,
        // a 5xx, a throttle, a 400 from a malformed request — leaves the
        // tokens alone, because the cost of being wrong here is signing out a
        // user whose session was fine. If it really is dead, the next attempt
        // says so.
        if (status != 401) {
          _log.w('Token refresh failed without ending the session: $e');
          return false;
        }
        // Rotation makes a *stale* 401 possible: a sign-in or an earlier
        // refresh may have replaced the pair while this request was in
        // flight, in which case the rejection describes a token nobody is
        // using any more and wiping the fresh one would be the bug.
        if (await getRefreshToken() != refresh) {
          _log.w('Refresh token was rotated mid-flight; keeping the session');
          return false;
        }
        _log.w('Refresh token rejected (401); clearing session');
        await clearTokens();
        onSessionInvalidated?.call();
        return false;
      }
    }
  }

  /// Backoff for a throttled refresh: the server's `Retry-After` when it sent
  /// one (capped, so a large value can't park the app), otherwise exponential
  /// from one second — plus up to a second of jitter either way.
  static Duration _throttleBackoff(Response<dynamic>? response, int attempt) {
    final header = response?.headers.value('retry-after');
    final seconds = int.tryParse(header ?? '');
    final base = seconds != null
        ? Duration(seconds: seconds.clamp(1, 30))
        : Duration(milliseconds: 1000 * (1 << attempt));
    return base + Duration(milliseconds: _jitter.nextInt(1000));
  }

  static final Random _jitter = Random();

  // ── Logging ───────────────────────────────────────────────────────────────

  /// Dev-only request logger that never prints secrets. Bodies of auth and
  /// payment calls (passwords, JWTs, Square access tokens) are redacted, and
  /// the Authorization header is masked on every request.
  // Redact everything under auth/ (login/refresh credentials, the Google
  // id_token on auth/google, and the single-use session-handoff token that
  // auth/web-session returns) and all payments/ (Square access tokens, amounts).
  static const _sensitivePaths = ['auth/', 'payments/'];

  static bool _isSensitive(String path) => _sensitivePaths.any(path.contains);

  Interceptor _buildLogInterceptor() => InterceptorsWrapper(
    onRequest: (options, handler) {
      final body = _isSensitive(options.path) ? '<redacted>' : options.data;
      _log.d('→ ${options.method} ${options.uri} $body');
      handler.next(options);
    },
    onResponse: (response, handler) {
      final path = response.requestOptions.path;
      final body = _isSensitive(path) ? '<redacted>' : response.data;
      _log.d('← ${response.statusCode} $path $body');
      handler.next(response);
    },
    onError: (error, handler) {
      final path = error.requestOptions.path;
      final body = _isSensitive(path) ? '<redacted>' : error.response?.data;
      _log.w('✗ ${error.response?.statusCode} $path $body');
      handler.next(error);
    },
  );

  // ── Dio factory ───────────────────────────────────────────────────────────

  Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: '${EnvironmentConfig.apiBaseUrl}/api/mobile/',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Accept': 'application/json'},
      ),
    );

    if (EnvironmentConfig.enableLogging) {
      dio.interceptors.add(_buildLogInterceptor());
    }

    // Attach JWT to every request; auto-refresh on 401.
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await getAccessToken();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          final is401 = error.response?.statusCode == 401;
          // Guard against an infinite loop: only retry a request once.
          final alreadyRetried =
              error.requestOptions.extra['__retried'] == true;
          if (is401 && !alreadyRetried) {
            final refreshed = await refreshTokens();
            if (refreshed) {
              // Retry the original request once with the new token.
              final token = await getAccessToken();
              final opts = error.requestOptions
                ..headers['Authorization'] = 'Bearer $token'
                ..extra['__retried'] = true;
              try {
                final response = await dio.fetch(opts);
                return handler.resolve(response);
              } on DioException catch (_) {
                return handler.next(error);
              }
            }
          }
          handler.next(error);
        },
      ),
    );

    return dio;
  }
}
