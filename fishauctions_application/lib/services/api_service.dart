import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

import '../config/environment.dart';
import '../utils/secure_storage.dart';

const _keyAccess = 'jwt_access';
const _keyRefresh = 'jwt_refresh';

final _log = Logger();

class ApiService {
  ApiService._() {
    _dio = _buildDio();
  }

  static final ApiService instance = ApiService._();

  late final Dio _dio;
  final _storage = secureStorage;

  /// Tracks an in-flight refresh so concurrent 401s share one call.
  Future<bool>? _pendingRefresh;

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
  /// Single-flight: concurrent 401s all await the same refresh. Without this,
  /// each parallel request would post the same refresh token; with rotation
  /// enabled the backend blacklists it after the first call, so the rest fail
  /// and wipe the session — logging the user out mid-session.
  Future<bool> refreshTokens() =>
      _pendingRefresh ??= _performRefresh().whenComplete(() {
        _pendingRefresh = null;
      });

  Future<bool> _performRefresh() async {
    final refresh = await getRefreshToken();
    if (refresh == null) {
      return false;
    }

    try {
      // A clean Dio (no interceptors) with its own timeout so a hung refresh
      // can't block forever or recurse through the auth interceptor.
      final res =
          await Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
            ),
          ).post(
            '${EnvironmentConfig.apiBaseUrl}/api/mobile/auth/refresh/',
            data: {'refresh': refresh},
          );
      final data = res.data;
      final access = data is Map ? data['access'] : null;
      final newRefresh = data is Map ? data['refresh'] : null;
      if (access is! String || newRefresh is! String) {
        // A 200 with no tokens is a server-side anomaly, not a rejected
        // credential — keep the refresh token so a later attempt can recover.
        _log.w('Token refresh returned an unexpected payload');
        return false;
      }
      await saveTokens(access, newRefresh);
      return true;
    } on DioException catch (e) {
      // Only a definitive rejection of the refresh token (expired, blacklisted
      // after rotation, or malformed) should end the session. Transient
      // failures — timeouts, offline, 5xx — must NOT wipe the tokens, or a
      // flaky network would silently log the user out.
      final status = e.response?.statusCode;
      if (status == 400 || status == 401 || status == 403) {
        _log.w('Refresh token rejected ($status); clearing session');
        await clearTokens();
      } else {
        _log.w('Token refresh failed transiently: $e');
      }
      return false;
    }
  }

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
