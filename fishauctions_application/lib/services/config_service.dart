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
  bool _cachedAuthenticated = false;

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

  /// Like [load], but re-fetches when the cached copy was taken **signed
  /// out**.
  ///
  /// Almost all of `/api/mobile/config/` is deployment-wide, which is why it
  /// is a public endpoint and why caching it for the process is fine. The
  /// `menu` block is the exception: it is built for the requesting user, and
  /// staff get an admin section nobody else does. The login screen warms this
  /// endpoint *before* there is a session (it decides which social buttons to
  /// draw), so on a fresh sign-in the process cache holds the anonymous
  /// answer — and without this the drawer would spend the whole session
  /// showing a menu belonging to nobody.
  ///
  /// Costs nothing in the common case: a cold start with a session already
  /// present fetches authenticated the first time, and this returns that.
  Future<AppConfig> loadForCurrentUser() async {
    final config = await load();
    if (_cachedAuthenticated || !await ApiService.instance.hasTokens) {
      return config;
    }
    _cached = null;
    return load();
  }

  Future<AppConfig> _fetch() async {
    // Read before the request, not after: this is the same question the auth
    // interceptor asks when it decides whether to attach the bearer token.
    final authenticated = await ApiService.instance.hasTokens;
    final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
      'config/',
    );
    final data = res.data;
    if (data == null) {
      throw const FormatException('empty config response');
    }
    final config = AppConfig.fromJson(data);
    _cached = config;
    _cachedAuthenticated = authenticated;
    return config;
  }
}
