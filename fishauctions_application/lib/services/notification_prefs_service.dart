import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// The two `UserData` notification toggles the app can set for the user, from
/// `GET/PATCH /api/mobile/notifications/prefs/` (BACKEND_SPEC.md Part N).
class NotificationPrefs {
  const NotificationPrefs({
    required this.pushInsteadOfEmail,
    required this.pushWhenLotsSell,
  });

  /// `UserData.push_notifications_instead_of_email` — everything that would
  /// have been an email arrives in the app instead.
  final bool pushInsteadOfEmail;

  /// `UserData.push_notifications_when_lots_sell` — at an in-person auction,
  /// a notification when bidding starts on a watched lot.
  final bool pushWhenLotsSell;

  bool get allOn => pushInsteadOfEmail && pushWhenLotsSell;

  static NotificationPrefs? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    return NotificationPrefs(
      pushInsteadOfEmail: raw['push_instead_of_email'] == true,
      pushWhenLotsSell: raw['push_when_lots_sell'] == true,
    );
  }
}

/// Reads and writes the user's push notification preferences.
///
/// The web `/preferences/` page owns these checkboxes; this exists so that
/// "Enable notifications" in the app means the same thing wherever it's offered
/// — allow the OS prompt *and* turn both server-side toggles on — instead of
/// granting a permission that then delivers nothing because the account still
/// prefers email. (The web checkbox for `push_instead_of_email` is disabled
/// until the account has a device with a live FCM token, so a user who only
/// grants the permission can't finish the job on the page either.)
///
/// Degrades like every other optional mobile endpoint: a 404 disables it for
/// the process, and the caller falls back to pointing the user at the web
/// preferences page.
class NotificationPrefsService {
  NotificationPrefsService._();
  static final NotificationPrefsService instance = NotificationPrefsService._();

  bool _available = true;

  /// Whether the endpoint exists on this deployment (as far as we know). False
  /// only after a 404.
  bool get isAvailable => _available;

  /// Current prefs, or null when unavailable/offline.
  Future<NotificationPrefs?> fetch() async {
    if (!_available) {
      return null;
    }
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'notifications/prefs/',
      );
      return NotificationPrefs.tryParse(res.data);
    } on DioException catch (e) {
      _noteUnavailable(e);
      return null;
    }
  }

  /// Turns both push toggles on. Returns the stored prefs on success, or null
  /// when the endpoint is missing or the write failed — in which case the
  /// caller should send the user to the web preferences page rather than claim
  /// success.
  Future<NotificationPrefs?> enableAll() async {
    if (!_available) {
      return null;
    }
    try {
      final res = await ApiService.instance.dio.patch<Map<String, dynamic>>(
        'notifications/prefs/',
        data: {'push_instead_of_email': true, 'push_when_lots_sell': true},
      );
      return NotificationPrefs.tryParse(res.data);
    } on DioException catch (e) {
      _noteUnavailable(e);
      return null;
    }
  }

  void _noteUnavailable(DioException e) {
    if (e.response?.statusCode == 404) {
      _available = false;
      debugPrint(
        'Notification prefs endpoint missing — the app can only ask for the '
        'OS permission; the toggles stay on the web preferences page.',
      );
    }
  }

  @visibleForTesting
  void reset() => _available = true;
}
