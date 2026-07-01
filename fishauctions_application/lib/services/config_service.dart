import '../models/app_config.dart';
import 'api_service.dart';

/// Fetches and caches the deployment's `GET /api/mobile/config/`.
///
/// The endpoint is public (no auth), so this is safe to call before sign-in —
/// e.g. warming it at startup to pre-initialize the Square SDK. The result is
/// cached for the process; repeated [load] calls are free, and concurrent
/// callers share one in-flight request (same single-flight pattern as
/// [ApiService.refreshTokens]).
class ConfigService {
  ConfigService._();
  static final ConfigService instance = ConfigService._();

  AppConfig? _cached;
  Future<AppConfig>? _pending;

  /// The last loaded config, or null if [load] hasn't completed yet. Lets
  /// callers read config synchronously when they know it's already warm without
  /// awaiting.
  AppConfig? get cached => _cached;

  Future<AppConfig> load() async {
    final cached = _cached;
    if (cached != null) {
      return cached;
    }
    return _pending ??= _fetch().whenComplete(() {
      _pending = null;
    });
  }

  Future<AppConfig> _fetch() async {
    final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
      'config/',
    );
    final data = res.data;
    if (data == null) {
      throw const FormatException('empty config response');
    }
    final config = AppConfig.fromJson(data);
    _cached = config;
    return config;
  }
}
