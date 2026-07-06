/// Push-notification token source (FCM), for BACKEND_SPEC.md Part 2.
///
/// Not wired yet: real tokens need a Firebase project with the three Android
/// flavor apps registered, per-flavor `google-services.json`, the
/// `firebase_messaging` plugin, and the Android 13+ POST_NOTIFICATIONS
/// runtime prompt. Until then [currentToken] is always null, so device
/// registration simply omits `fcm_token` and the backend keeps emailing.
///
/// The registration/unregistration plumbing around this seam is already live:
/// `AuthService.registerThisDevice` sends the token when one exists, and
/// sign-out calls `devices/unregister/` so a signed-out phone can't keep
/// receiving the previous user's notifications. When Firebase lands, also
/// re-register on `onTokenRefresh`.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  /// The device's current FCM registration token, or null while push isn't
  /// wired up (or the user declined the notification permission).
  Future<String?> currentToken() async => null;
}
