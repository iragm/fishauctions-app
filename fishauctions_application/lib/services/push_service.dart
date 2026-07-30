import 'dart:async';

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

/// The outcome of [PushService.enable] — what to tell the user next.
enum PushEnableResult {
  /// Permission granted and a token is registered: push is live.
  enabled,

  /// The user said no. Re-asking is possible on Android (a second decline is
  /// permanent) but pointless on iOS after the first, so callers point at the
  /// system settings instead of prompting again.
  denied,

  /// This deployment/build has no push config, or Firebase failed to come up —
  /// nothing to enable. The backend keeps emailing.
  unavailable,
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
/// **[init] never prompts.** It brings Firebase and the message listeners up
/// and reads the token only if notification permission *already* exists, so a
/// cold start is silent; the OS dialog is raised by [enable], from a place in
/// the app where the user just asked for notifications (see
/// `PushPromptService`). An install-time prompt for something the user hasn't
/// been offered yet is the single most-dismissed dialog in any app, and a
/// dismissal is permanent on iOS.
///
/// The token is also deliberately withheld until permission exists: the backend
/// treats "has a `MobileDevice` row with an `fcm_token`" as "this user can
/// receive push" (it's what un-disables the preferences toggle), and a token
/// from a phone that will drop every notification makes that read wrong.
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

  /// True once Firebase is up for this build — i.e. push *could* work if the
  /// user allows notifications. False while inert (no config for this
  /// deployment/platform/package, or init failed), in which case there is
  /// nothing to offer and no prompt should ever be shown.
  bool get isConfigured => _initialized;

  /// Set once at startup so a refreshed token re-registers the device. Kept as
  /// a callback (not a direct AuthService call) to avoid an import cycle.
  /// Awaited by [enable] — the backend won't accept the "push instead of email"
  /// preference until the account has a device carrying a token, so the
  /// registration has to land before that write, not race it.
  Future<void> Function()? onTokenChanged;

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

  /// Whether the OS currently allows this app to show notifications. False when
  /// push is inert (nothing has been asked), when the user declined, or when
  /// notifications were switched off in system settings later. Never prompts.
  Future<bool> hasPermission() async {
    if (!_initialized) {
      return false;
    }
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      return _isAllowed(settings.authorizationStatus);
    } on Object catch (e) {
      debugPrint('Push: reading notification settings failed: $e');
      return false;
    }
  }

  /// Raises the OS notification permission dialog (if it hasn't been answered
  /// yet), then picks up the FCM token and hands it to [onTokenChanged] so the
  /// device re-registers. Call this only from a place where the user has just
  /// asked for notifications.
  ///
  /// Safe to call when already granted — no second dialog, and it repairs a
  /// missing token (e.g. permission granted in system settings after launch).
  Future<PushEnableResult> enable() async {
    if (!_initialized) {
      return PushEnableResult.unavailable;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      // Prompts on iOS and Android 13+; a no-op that reports `authorized`
      // below that. A second call after a decline returns the stored answer
      // rather than re-prompting, which is why callers offer system settings.
      final settings = await messaging.requestPermission();
      if (!_isAllowed(settings.authorizationStatus)) {
        return PushEnableResult.denied;
      }
      _token = await messaging.getToken();
      if (_token == null) {
        // Permission is there but FCM has no token yet (an APNs registration
        // that hasn't landed, or Play Services trouble). onTokenRefresh will
        // deliver it and re-register; nothing more to do here.
        debugPrint('Push: permission granted but no token yet.');
      }
      await onTokenChanged?.call();
      return PushEnableResult.enabled;
    } on Object catch (e) {
      debugPrint('Push: enable failed: $e');
      return PushEnableResult.unavailable;
    }
  }

  /// iOS reports `provisional` for quiet-delivery authorization, which does
  /// deliver notifications; both platforms use `authorized` for the normal
  /// case.
  static bool _isAllowed(AuthorizationStatus status) =>
      status == AuthorizationStatus.authorized ||
      status == AuthorizationStatus.provisional;

  /// Idempotent. Initializes Firebase + FCM from [config] when — and only when
  /// — this deployment ships a complete push config for this platform *and*
  /// this build's applicationId/bundle id. Any failure leaves push inert
  /// (email fallback); it never throws.
  ///
  /// Deliberately silent: no permission dialog, and no token unless the OS
  /// already allows notifications. [enable] is what asks.
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
      // Only read the token when the OS is already going to deliver — see the
      // class doc. `enable()` fills it in after a grant.
      if (_isAllowed(
        (await messaging.getNotificationSettings()).authorizationStatus,
      )) {
        _token = await messaging.getToken();
      }
      messaging.onTokenRefresh.listen((refreshed) {
        _token = refreshed;
        unawaited(onTokenChanged?.call() ?? Future<void>.value());
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
