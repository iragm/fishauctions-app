import '../utils/secure_storage.dart';
import 'notification_prefs_service.dart';
import 'push_service.dart';

/// Where an "enable notifications" offer is being made. The copy differs
/// because the reason the user cares differs; what "Enable" *does* is
/// identical (see [PushPromptService.enable]).
enum PushPromptSurface {
  /// The web `/preferences/` page — the notification settings screen, where
  /// the `push_notifications_instead_of_email` checkbox is disabled until this
  /// phone has a live token, so the page can't finish the job on its own.
  preferences,

  /// A lot page belonging to an in-person auction, where the payoff is
  /// concrete: a notification when this lot is about to sell.
  lotSellingSoon,
}

/// Decides *when* to offer notifications and performs the whole opt-in.
///
/// The OS notification dialog used to fire from `PushService.init` at shell
/// mount, i.e. seconds after launch, before the user had any idea what they'd
/// be notified about. Now nothing prompts until the user is somewhere the offer
/// makes sense, and "Enable" always means the same three things:
///
///  1. the OS notification permission,
///  2. an FCM token registered against this device, and
///  3. both server-side toggles on — `push_notifications_instead_of_email` and
///     `push_notifications_when_lots_sell`.
///
/// Step 3 needs `notifications/prefs/`; without it (older backend) the OS half
/// still completes and the caller points the user at the web preferences page.
///
/// The "already offered" bookkeeping is **device-local** on purpose: an OS
/// notification permission belongs to this install, so the same account on a
/// second phone gets its own first run — the same reasoning as
/// `PrinterSetupPrompt`.
class PushPromptService {
  PushPromptService._();
  static final PushPromptService instance = PushPromptService._();

  static const _storage = secureStorage;
  static const _keyLotOffered = 'push_prompt_lot_offered';

  /// Whether to raise the offer for [surface] right now. False when push can't
  /// work on this build at all, when the OS already allows notifications
  /// (nothing to ask), or when this surface has had its turn.
  ///
  /// [PushPromptSurface.preferences] has no once-only guard: that page *is* the
  /// notification settings screen, so an "enable it on this phone" action is
  /// the control the page is missing, not a nag — and it stops appearing the
  /// moment permission exists.
  Future<bool> shouldOffer(PushPromptSurface surface) async {
    if (!PushService.instance.isConfigured) {
      return false;
    }
    if (await PushService.instance.hasPermission()) {
      return false;
    }
    if (surface == PushPromptSurface.lotSellingSoon) {
      return await _storage.read(key: _keyLotOffered) == null;
    }
    return true;
  }

  /// Records that [surface] made its offer, so a once-only surface doesn't
  /// repeat. Called when the banner is actually shown — not when it's merely
  /// considered — so a banner superseded by a page load still gets another
  /// chance.
  Future<void> markOffered(PushPromptSurface surface) async {
    if (surface == PushPromptSurface.lotSellingSoon) {
      await _storage.write(key: _keyLotOffered, value: '1');
    }
  }

  /// The full opt-in. Returns the OS-permission outcome; `prefsWritten` says
  /// whether the server-side toggles could also be set (false → tell the user
  /// to finish on the preferences page).
  Future<({PushEnableResult result, bool prefsWritten})> enable() async {
    // PushService.enable awaits its onTokenChanged hook, which is the device
    // registration — so by the time it returns, the account has a device
    // carrying a token. That order matters: the backend gates
    // `push_notifications_instead_of_email` on exactly that, so a prefs write
    // that raced ahead of the registration could legitimately be refused.
    final result = await PushService.instance.enable();
    if (result != PushEnableResult.enabled) {
      return (result: result, prefsWritten: false);
    }
    final prefs = await NotificationPrefsService.instance.enableAll();
    return (result: result, prefsWritten: prefs != null);
  }

  /// Forgets the device-local offer bookkeeping. Called on sign-out: the next
  /// account on this phone hasn't been asked anything.
  Future<void> clear() => _storage.delete(key: _keyLotOffered);
}
