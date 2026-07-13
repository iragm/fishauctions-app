import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../models/app_config.dart';
import '../utils/device_identity.dart';

/// A push message surfaced to the UI (for an in-app banner while foregrounded).
class PushMessage {
  const PushMessage({
    required this.title,
    required this.body,
    required this.url,
  });

  final String title;
  final String body;

  /// Where a tap should take the WebView (absolute URL or site-relative path);
  /// may be empty.
  final String url;
}

/// Push notifications (FCM), for BACKEND_SPEC.md Part 2.
///
/// Wired against the runtime Firebase client config from `/api/mobile/config/`
/// (see [AppConfig.firebase]) rather than a bundled `google-services.json`, so
/// one binary serves any deployment. Inert unless [init] finds a **complete**
/// config block **for this exact build** (a dev flavor hitting the staging
/// backend, whose config targets the staging package, gets no push instead of a
/// mismatched registration). When inert, [currentToken] stays null, device
/// registration omits `fcm_token`, and the backend keeps emailing.
///
/// The backend sends a `notification`+`data` message: the OS displays it in the
/// background/terminated states (both platforms), so there is no background
/// isolate here — this only handles the **foreground** banner and **tap
/// routing** (`data.url` → WebView). See `PUSH.md`.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  String? _token;
  bool _initialized = false;

  /// Set once at startup so a refreshed token re-registers the device. Kept as
  /// a callback (not a direct AuthService call) to avoid an import cycle.
  void Function()? onTokenChanged;

  /// A destination for the WebView from a notification **tap** (background or
  /// terminated tap, or the "View" action on a foreground banner). The shell
  /// watches this and navigates, then calls [consumeRoute]. Mirrors
  /// `ShortcutService.pending`.
  final ValueNotifier<String?> pendingRoute = ValueNotifier<String?>(null);

  /// The most recent message received while the app was **foregrounded**, for
  /// an in-app banner (FCM doesn't auto-display in the foreground). The shell
  /// shows it and clears this.
  final ValueNotifier<PushMessage?> foregroundMessage =
      ValueNotifier<PushMessage?>(null);

  /// The device's current FCM token, or null while push is inert.
  Future<String?> currentToken() async => _token;

  /// Synchronous view of the token for callers that just checked [init].
  String? get token => _token;

  /// Returns and clears [pendingRoute].
  String? consumeRoute() {
    final route = pendingRoute.value;
    pendingRoute.value = null;
    return route;
  }

  /// Idempotent. Initializes Firebase + FCM from [config] when — and only when
  /// — this deployment ships a complete push config for this platform *and*
  /// this build's applicationId/bundle id. Any failure leaves push inert
  /// (email fallback); it never throws.
  Future<void> init(AppConfig config) async {
    if (_initialized) {
      return;
    }
    final isIOS = DeviceIdentity.platformTag == 'ios';
    final options = config.firebase?.forPlatform(isIOS: isIOS);
    if (options == null) {
      debugPrint('Push: no Firebase config for this platform; inert.');
      return;
    }
    final running = await DeviceIdentity.packageName();
    if (options.applicationId != running) {
      debugPrint(
        'Push: config targets ${options.applicationId} but this build is '
        '"$running"; inert (email fallback).',
      );
      return;
    }
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: options.apiKey,
          appId: options.appId,
          messagingSenderId: options.messagingSenderId,
          projectId: options.projectId,
        ),
      );
      final messaging = FirebaseMessaging.instance;
      // Prompts on iOS and Android 13+; a no-op (returns authorized) elsewhere.
      await messaging.requestPermission();
      _token = await messaging.getToken();
      messaging.onTokenRefresh.listen((refreshed) {
        _token = refreshed;
        onTokenChanged?.call();
      });
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_routeFrom);
      // Cold start from a tap while terminated: the launching message is here,
      // not on the stream. The shell picks up pendingRoute once its WebView is
      // ready (see WebViewScreen).
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        _routeFrom(initial);
      }
      _initialized = true;
    } on Object catch (e) {
      debugPrint('Push init failed; inert: $e');
    }
  }

  void _onForegroundMessage(RemoteMessage message) {
    foregroundMessage.value = _messageOf(message);
  }

  void _routeFrom(RemoteMessage message) {
    final url = message.data['url'];
    if (url is String && url.isNotEmpty) {
      pendingRoute.value = url;
    }
  }

  PushMessage _messageOf(RemoteMessage message) {
    final notification = message.notification;
    String pick(String? a, Object? b) =>
        (a != null && a.isNotEmpty) ? a : (b?.toString() ?? '');
    return PushMessage(
      title: pick(notification?.title, message.data['title']),
      body: pick(notification?.body, message.data['body']),
      url: message.data['url']?.toString() ?? '',
    );
  }
}
