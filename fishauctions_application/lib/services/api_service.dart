import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

import '../config/environment.dart';

const _keyAccess = 'jwt_access';
const _keyRefresh = 'jwt_refresh';

final _log = Logger();

class ApiService {
  ApiService._() {
    _dio = _buildDio();
  }

  static final ApiService instance = ApiService._();

  late final Dio _dio;
  final _storage = const FlutterSecureStorage();

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
        _log.w('Token refresh returned an unexpected payload');
        await clearTokens();
        return false;
      }
      await saveTokens(access, newRefresh);
      return true;
    } on Exception catch (e) {
      _log.w('Token refresh failed: $e');
      await clearTokens();
      return false;
    }
  }

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
      dio.interceptors.add(
        LogInterceptor(
          requestBody: true,
          responseBody: true,
          logPrint: (o) => _log.d(o.toString()),
        ),
      );
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
