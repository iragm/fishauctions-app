import '../models/app_config.dart';
import 'api_service.dart';

/// Fetches and caches the deployment's `GET /api/mobile/config/`.
///
/// The endpoint is public (no auth *required*), so this is safe to call before
/// sign-in — e.g. warming it at startup to pre-initialize the Square SDK. The
/// result is cached for the process; repeated [load] calls are free, and
/// concurrent callers share one in-flight request (same single-flight pattern
/// as [ApiService.refreshTokens]).
///
/// **The bearer token is read optionally, which makes staleness silent.** A
/// missing, expired or malformed token does not fail: it returns 200 with the
/// *signed-out* payload — including the signed-out `menu`. Nothing errors, so
/// nothing retries, and the app would spend the whole process rendering
/// signed-out chrome around a live session. Hence two rules here: refresh the
/// access token before asking ([ApiService.ensureFreshAccessToken]), and
/// record whether the answer can be trusted to describe the current user
/// ([configIsForCurrentUser]) so a caller can decline to act on one that
/// can't.
class ConfigService {
  ConfigService._();
  static final ConfigService instance = ConfigService._();

  AppConfig? _cached;
  Future<AppConfig>? _pending;
  bool _cachedForCurrentUser = false;

  /// The last loaded config, or null if [load] hasn't completed yet. Lets
  /// callers read config synchronously when they know it's already warm
  /// without awaiting.
  AppConfig? get cached => _cached;

  /// Whether [cached] describes the user who is signed in right now.
  ///
  /// False when the fetch went out anonymously — either there was no session,
  /// or there was one but the access token could not be refreshed in time
  /// (offline, throttled), in which case the server answered as if for a
  /// stranger. Everything in the response except `menu` is deployment-wide and
  /// unaffected; `menu` is the one per-user block, so the drawer's store is the
  /// caller that has to check this.
  bool get configIsForCurrentUser => _cachedForCurrentUser;

  Future<AppConfig> load() async {
    final cached = _cached;
    if (cached != null) {
      return cached;
    }
    return _pending ??= _fetch().whenComplete(() {
      _pending = null;
    });
  }

  /// Like [load], but re-fetches when the cached copy doesn't belong to the
  /// signed-in user.
  ///
  /// Almost all of `/api/mobile/config/` is deployment-wide, which is why it
  /// is a public endpoint and why caching it for the process is fine. The
  /// `menu` block is the exception: it is built for the requesting user, and
  /// staff get an admin section nobody else does. The login screen warms this
  /// endpoint *before* there is a session (it decides which social buttons to
  /// draw), so on a fresh sign-in the process cache holds the anonymous
  /// answer — and without this the drawer would spend the whole session
  /// showing a menu belonging to nobody. The same applies to a copy fetched
  /// while the access token was stale, which is indistinguishable on the wire.
  ///
  /// Costs nothing in the common case: a cold start with a session already
  /// present fetches authenticated the first time, and this returns that.
  Future<AppConfig> loadForCurrentUser() async {
    final config = await load();
    if (_cachedForCurrentUser || !await ApiService.instance.hasTokens) {
      return config;
    }
    _cached = null;
    return load();
  }

  Future<AppConfig> _fetch() async {
    final api = ApiService.instance;
    // Refresh *before* asking, not after: this endpoint answers a stale token
    // with a 200 and the signed-out payload, so there is no 401 for the auth
    // interceptor to catch and no failure for anything to retry. A token with
    // life left in it makes no extra network call.
    final signedIn = await api.hasTokens;
    final fresh = signedIn && await api.ensureFreshAccessToken();
    final res = await api.dio.get<Map<String, dynamic>>('config/');
    final data = res.data;
    if (data == null) {
      throw const FormatException('empty config response');
    }
    final config = AppConfig.fromJson(data);
    _cached = config;
    _cachedForCurrentUser = fresh;
    return config;
  }
}
