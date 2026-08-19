import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// OS notifications the *app itself* posts, as opposed to the ones FCM
/// delivers (`PushService`).
///
/// It exists for one job: the proximity check-in nudges. Those are produced by
/// a background timer (`CheckinService` pings on mount, on resume, and every
/// ten minutes), so the moment they arrive has nothing to do with what the
/// user is looking at — and drawing a modal sheet at that moment put a "join
/// this auction?" prompt over whatever screen happened to be up, the lot
/// scanning camera very much included. A tray notification is the right shape
/// for news that arrives on someone else's schedule: it waits, it survives the
/// app being backgrounded, and the user opens it when they choose.
///
/// It also solves the bidder-number problem properly. A check-in snackbar
/// carried the number for twelve seconds and then it was gone with nowhere to
/// look it up; a notification stays in the shade until it's swiped away.
///
/// **Never prompts.** Initialization asks for nothing on either platform
/// (`requestAlertPermission: false` and friends), and [show] simply reports
/// `false` when the OS won't display anything — the caller falls back to
/// in-app UI. Notification permission is asked for in exactly the two places
/// `PushPromptService` documents, and arriving at an auction is not one of
/// them.
class LocalNotificationService {
  LocalNotificationService._();
  static final LocalNotificationService instance = LocalNotificationService._();

  /// The Android channel these land on. Separate from push so a user can mute
  /// one without the other.
  static const String channelId = 'checkin';
  static const String _channelName = 'Auction check-in';
  static const String _channelDescription =
      'Welcome and check-in nudges when you arrive at an auction.';

  /// Payload of a notification the user tapped, for the shell to act on.
  /// Mirrors `PushService.pendingRoute` / `ShortcutService.pending`.
  final ValueNotifier<String?> pendingPayload = ValueNotifier<String?>(null);

  @visibleForTesting
  FlutterLocalNotificationsPlugin? plugin;

  bool _initialized = false;
  bool _available = false;

  /// Idempotent, silent, and safe to call on every shell mount. Leaves
  /// [_available] false on any failure, which turns [show] into a no-op that
  /// reports `false` — i.e. the caller's in-app fallback.
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    final instance = plugin ??= FlutterLocalNotificationsPlugin();
    try {
      await instance.initialize(
        settings: const InitializationSettings(
          // The same white-on-transparent silhouette FCM uses: Android draws a
          // notification icon as a mask, so the launcher artwork renders as a
          // white square.
          android: AndroidInitializationSettings('@drawable/ic_notification'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _onResponse,
      );
      _available = true;
      // A tap that launched the app from cold isn't on the callback — it's
      // here, exactly like FirebaseMessaging.getInitialMessage.
      final launch = await instance.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _deliver(launch?.notificationResponse?.payload);
      }
    } on Object catch (e) {
      debugPrint('Local notifications unavailable: $e');
    }
  }

  void _onResponse(NotificationResponse response) => _deliver(response.payload);

  void _deliver(String? payload) {
    if (payload != null && payload.isNotEmpty) {
      pendingPayload.value = payload;
    }
  }

  /// Returns and clears [pendingPayload].
  String? consumePayload() {
    final payload = pendingPayload.value;
    pendingPayload.value = null;
    return payload;
  }

  /// Whether the OS will actually display what we post. Never prompts, so a
  /// user who has never been asked reads as `false` — which is correct: the
  /// notification would go nowhere.
  Future<bool> isPermitted() async {
    final instance = plugin;
    if (!_available || instance == null) {
      return false;
    }
    try {
      final android = instance
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        return await android.areNotificationsEnabled() ?? false;
      }
      final ios = instance
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        return (await ios.checkPermissions())?.isEnabled ?? false;
      }
    } on Object catch (e) {
      debugPrint('Reading notification permission failed: $e');
    }
    return false;
  }

  /// Posts a notification and reports whether it will be seen.
  ///
  /// `false` means *nothing was displayed* — no permission, no plugin, or the
  /// post threw — and the caller owns the fallback. It deliberately does not
  /// throw: every caller here is a nudge, and a nudge that crashes the ping
  /// loop is worse than a nudge that doesn't appear.
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    final instance = plugin;
    if (!_available || instance == null || !await isPermitted()) {
      return false;
    }
    try {
      await instance.show(
        id: id,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            _channelName,
            channelDescription: _channelDescription,
            // Heads-up: the user has just walked into the venue and the thing
            // being offered (a bidder number) is time-sensitive.
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
      return true;
    } on Object catch (e) {
      debugPrint('Posting notification $id failed: $e');
      return false;
    }
  }

  @visibleForTesting
  void reset() {
    _initialized = false;
    _available = false;
    plugin = null;
    pendingPayload.value = null;
  }
}
