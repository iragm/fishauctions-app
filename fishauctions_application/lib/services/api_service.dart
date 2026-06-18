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
  Future<bool> refreshTokens() async {
    final refresh = await getRefreshToken();
    if (refresh == null) {
      return false;
    }

    try {
      // Use a clean Dio to avoid the interceptor looping.
      final res = await Dio().post(
        '${EnvironmentConfig.apiBaseUrl}/api/mobile/auth/refresh/',
        data: {'refresh': refresh},
      );
      await saveTokens(
        res.data['access'] as String,
        res.data['refresh'] as String,
      );
      return true;
    } on Exception catch (e) {
      _log.w('Token refresh failed: $e');
      await clearTokens();
      return false;
    }
  }

  // ── Dio factory ───────────────────────────────────────────────────────────

  Dio _buildDio() {
    final dio = Dio(BaseOptions(
      baseUrl: '${EnvironmentConfig.apiBaseUrl}/api/mobile/',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept': 'application/json'},
    ));

    if (EnvironmentConfig.enableLogging) {
      dio.interceptors.add(LogInterceptor(
        requestBody: true,
        responseBody: true,
        logPrint: (o) => _log.d(o.toString()),
      ));
    }

    // Attach JWT to every request; auto-refresh on 401.
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await getAccessToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode == 401) {
          final refreshed = await refreshTokens();
          if (refreshed) {
            // Retry the original request with the new token.
            final token = await getAccessToken();
            final opts = error.requestOptions;
            opts.headers['Authorization'] = 'Bearer $token';
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
    ));

    return dio;
  }
}
