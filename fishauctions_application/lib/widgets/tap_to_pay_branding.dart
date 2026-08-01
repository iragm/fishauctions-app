import 'package:flutter/material.dart';

/// Apple's name for the capability, in the long form from the localization
/// table in the *Tap to Pay on iPhone App & Marketing Requirements and Review
/// Guide* (English: long "Tap to Pay on iPhone", short "Tap to Pay").
///
/// Always the long form here. The short form is only sanctioned for a button
/// label that's tight for space, while the guide's marketing rules say to
/// "always refer to Tap to Pay on iPhone" and never shorten it or put "Apple"
/// in the name. One constant so no screen quietly invents its own wording.
const String tapToPayName = 'Tap to Pay on iPhone';

/// Path to Apple's `wave.3.right.circle.fill` SF Symbol, exported as a PNG into
/// `assets/tap_to_pay/`, or null when it hasn't been added to the repo yet.
///
/// **Why this is a nullable constant and not just an asset path.** Requirement
/// 5.5 of Apple's review guide is conditional: *"When using iconography in the
/// button, the symbol must be either `wave.3.right.circle` or
/// `wave.3.right.circle.fill` from SF Symbols."* Any other wave-ish glyph —
/// Material's `Icons.contactless` very much included — fails it, and drawing
/// our own is separately forbidden: the marketing rules bar creating
/// illustrations or icons that depict iPhone or Tap to Pay on iPhone.
///
/// So the app ships with **no icon at all** on its Tap to Pay controls, which
/// makes 5.5 not apply. To add the icon: open the SF Symbols app, export
/// `wave.3.right.circle.fill` unmodified as a PNG into
/// `assets/tap_to_pay/wave_3_right_circle_fill.png`, and set this to that path.
/// Everything below picks it up automatically. Do not substitute a lookalike.
const String? tapToPaySymbolAsset = null;

/// Apple's Tap to Pay symbol, or nothing when [tapToPaySymbolAsset] hasn't been
/// populated. Tinted to the surrounding text colour, which SF Symbols permits
/// (recolouring a monochrome symbol is fine; redrawing it is not).
class TapToPaySymbol extends StatelessWidget {
  const TapToPaySymbol({this.size = 24, this.color, super.key});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (tapToPaySymbolAsset == null) {
      return const SizedBox.shrink();
    }
    return Image.asset(
      tapToPaySymbolAsset!,
      width: size,
      height: size,
      color: color ?? DefaultTextStyle.of(context).style.color,
      // A missing/corrupt export must never break a checkout screen — degrade
      // to the same no-icon layout the app ships with today.
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}

/// The headline block at the top of the Tap to Pay settings screen.
///
/// Text only, by design. Apple's marketing rules allow only assets from the
/// *Tap to Pay on iPhone Marketing Guide and Toolkit* to illustrate the
/// capability — no custom videos, illustrations, photography, or stock imagery,
/// and no self-drawn depictions of an iPhone. Anything visual added here has to
/// come out of that toolkit.
class TapToPayHeader extends StatelessWidget {
  const TapToPayHeader({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const TapToPaySymbol(size: 32),
          if (tapToPaySymbolAsset != null) const SizedBox(width: 10),
          Expanded(
            child: Text(
              tapToPayName,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text(
        'Take contactless payments right on your iPhone — cards, Apple Pay '
        'and other digital wallets — with no extra terminal or hardware.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
      ),
    ],
  );
}
