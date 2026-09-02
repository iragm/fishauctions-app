import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/secure_storage.dart';
import 'tap_to_pay_branding.dart';

/// The in-app awareness moment for Tap to Pay on iPhone — a full-screen modal
/// telling an eligible merchant the capability exists and offering setup.
///
/// Apple mandates this. From the review guide: *"Apple mandates that any app on
/// the public App Store include at least one in-app awareness moment for all
/// eligible users"*, with a full-screen modal named as the best practice. It
/// covers checklist items **3.1** (highly visible, easily discoverable
/// communication), **3.2** (full-screen modal splash screen), **3.3** (shown to
/// all eligible users at least once) and marketing item **6.2** (an in-app
/// splash screen visible to all eligible users at least once).
///
/// **The artwork and final copy must come from Apple's toolkit.** The guide is
/// unambiguous that developers "may not develop your own customized marketing
/// and communications content, images or videos" for Tap to Pay on iPhone, and
/// that only the Apple-approved templates (with light customization — brand
/// colours, fonts, logo) may be used. So this renders type only: no drawing of
/// an iPhone, no depiction of the Tap to Pay interface, no stock imagery.
/// Dropping in the toolkit's "Hero in-app banner" is the remaining step before
/// launch marketing — see `TAPTOPAY.md`.
///
/// Shown at most once per install, and only to users the backend says are
/// eligible. "Once" is the floor Apple asks for; it is deliberately not
/// repeated, because a merchant who dismissed it can always reach the same
/// setup from the drawer (requirement 3.6).
class TapToPayAwarenessSheet extends StatelessWidget {
  const TapToPayAwarenessSheet({super.key});

  static const _seenKey = 'tap_to_pay_awareness_shown';

  /// A marker file in the app documents directory, **not** secure storage.
  ///
  /// Device-local rather than server-side because the thing being announced is
  /// device-local too: Tap to Pay is set up per iPhone, so the same merchant
  /// picking up a second phone genuinely does need telling again.
  ///
  /// But this used to live in `flutter_secure_storage`, i.e. the iOS Keychain —
  /// **which survives app deletion.** Combined with `markShown()` being called
  /// *before* the modal is presented (deliberately: a merchant who force-quits
  /// mid-modal has still seen it), that made a once-ever flag that no
  /// reinstall, no sign-out and no UI could reset, on a modal with no other
  /// trigger. A failed impression was therefore permanent and, from outside,
  /// indistinguishable from being ineligible. The documents directory *is*
  /// cleared on uninstall, so "once per device" becomes "once per install" —
  /// still comfortably Apple's 3.3 floor of "at least once", and testable.
  static Future<File> _marker() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/$_seenKey');

  /// Whether this install has already shown the awareness moment.
  ///
  /// Fails **open** — an unreadable marker reports "not shown". Showing an
  /// announcement twice is a far smaller harm than never showing the one Apple
  /// requires.
  static Future<bool> alreadyShown() async {
    try {
      return (await _marker()).existsSync();
    } on Object {
      return false;
    }
  }

  static Future<void> markShown() async {
    try {
      await (await _marker()).writeAsString('1', flush: true);
      // Retire the Keychain entry this used to live in, so a device that
      // already carries one isn't left with a stale secret forever.
      await secureStorage.delete(key: _seenKey);
    } on Object {
      // Never worth failing the modal over.
    }
  }

  /// Forgets that the modal was shown, so it fires again on the next eligible
  /// auction page. For re-recording Apple's onboarding video without a
  /// reinstall; see `TapToPayService.resetForRecording`.
  static Future<void> clearShown() async {
    try {
      final marker = await _marker();
      if (marker.existsSync()) {
        await marker.delete();
      }
    } on Object {
      // Best effort — the fallback is deleting the app.
    }
  }

  /// Presents the modal. Resolves true when the merchant chose to set it up, so
  /// the caller can route them to the settings screen.
  static Future<bool> show(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        // Full-screen and deliberately dismissible: Apple asks for the moment
        // to be *shown*, not forced. The guide says enablement need not be
        // mandatory, only offered as soon as possible.
        builder: (_) =>
            const Dialog.fullscreen(child: TapToPayAwarenessSheet()),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const TapToPaySymbol(size: 56),
                      if (tapToPaySymbolAsset != null)
                        const SizedBox(height: 20),
                      Text(
                        'Accept payments with $tapToPayName',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'You can now take contactless payments at your '
                        'auctions right on this iPhone — contactless cards, '
                        'Apple Pay, and other digital wallets. No extra '
                        'terminal, no card reader to carry, no cables.',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Setting it up takes about a minute and you only do it '
                        'once on this iPhone.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Set up $tapToPayName'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}
