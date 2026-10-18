import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/secure_storage.dart';
import 'tap_to_pay_branding.dart';

/// The toolkit tile, registered in `pubspec.yaml`.
const tapToPayHeroAsset = 'assets/tap_to_pay/hero_card_to_iphone.jpg';

/// The guide's legal disclaimers for the hero tile, word for word.
const tapToPayDisclaimers = [
  (
    '$tapToPayName Requirements',
    '$tapToPayName requires a supported payment app and the latest version '
        'of iOS. Update to the latest version by going to Settings > General > '
        'Software Update. Some contactless cards may not be accepted by your '
        'payment app. Transaction limits may apply. $tapToPayName is not '
        'available in all markets. For $tapToPayName countries and regions, '
        'see https://developer.apple.com/tap-to-pay/regions/.',
  ),
  (
    'Apple Pay',
    'Apple Pay is a service provided by Apple Payments Services LLC, a '
        'subsidiary of Apple Inc. Neither Apple Inc. nor Apple Payments '
        'Services LLC is a bank. Any card used in Apple Pay is offered by the '
        'card issuer.',
  ),
  (
    'Contactless Indicator Mark',
    'The Contactless Indicator mark, consisting of four graduating arcs, is a '
        'trademark owned by and used with permission of EMVCo, LLC.',
  ),
];

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
/// **The artwork and copy come from Apple's toolkit**, which forbids writing
/// your own ("you may not develop your own customized marketing and
/// communications content, images or videos"). The picture is the US toolkit's
/// "Hero in-app banner" tile *Card to iPhone* (9:16), cropped above its
/// "[Your CTA]" placeholder and baked-in "Terms apply." line, both of which are
/// drawn here instead: the toolkit lets a partner supply its own CTA button,
/// and its "Terms apply." has to open the full disclaimer, which a picture
/// can't do. The disclaimers are the ones the guide requires for what the tile
/// shows: the requirements, Apple Pay, and the contactless mark on the card.
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

  /// The full disclaimers behind the tile's "Terms apply.".
  static Future<void> showTerms(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Legal Disclaimers'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (heading, text) in tapToPayDisclaimers) ...[
              Text(heading, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              SelectableText(text),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  // The tile is drawn on white, so the sheet is too, in either theme.
  Widget build(BuildContext context) => Theme(
    data: ThemeData(colorSchemeSeed: Colors.black, useMaterial3: true),
    child: Builder(
      builder: (context) => ColoredBox(
        color: Colors.white,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
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
                  child: Semantics(
                    label:
                        '$tapToPayName. A contactless card held to an '
                        'iPhone. Accept physical debit and credit cards as '
                        'well as Apple Pay and other digital wallets. Right '
                        'on your iPhone.',
                    image: true,
                    child: Image.asset(
                      tapToPayHeroAsset,
                      fit: BoxFit.contain,
                      excludeFromSemantics: true,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Get started with $tapToPayName'),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Not now'),
                ),
                TextButton(
                  onPressed: () => showTerms(context),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.black54,
                    textStyle: Theme.of(context).textTheme.bodySmall,
                  ),
                  child: const Text('Terms apply.'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
