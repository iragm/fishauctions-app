import 'package:flutter/material.dart';

/// Google's official "Sign in with Google" button, drawn from the artwork
/// Google ships in its sign-in branding kit (`signin-assets.zip`,
/// developers.google.com/identity/branding-guidelines).
///
/// It's an image rather than a hand-built row on purpose: the guidelines pin
/// the fill, the 1px stroke, the label font (Google Sans Medium — a font we
/// don't bundle) and the paddings around the "G", and forbid recoloring the
/// mark, showing it without the button boundary and text, or distorting it.
/// Scaling Google's own asset proportionally keeps every one of those true, so
/// the only knob here is [height].
///
/// The bundled PNGs are the 4x Android/Web pill assets (720×160 for a natural
/// 180×40 button), decoded at exactly the size they're drawn at, so the button
/// stays sharp at any [height] on any display density.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    required this.onPressed,
    super.key,
    this.height = 52,
  });

  /// Null disables the button: dimmed, no ripple, no tap.
  final VoidCallback? onPressed;

  /// Drawn height in logical pixels. Google's natural size is 40; the width
  /// follows from the asset's aspect ratio — it is never stretched.
  final double height;

  /// Natural size of Google's pill asset, in logical pixels.
  static const double _naturalWidth = 180;
  static const double _naturalHeight = 40;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final width = height * (_naturalWidth / _naturalHeight);
    final devicePixels = (height * MediaQuery.devicePixelRatioOf(context))
        .round();

    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Sign in with Google',
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.asset(
                  dark
                      ? 'assets/google/sign_in_with_google_dark.png'
                      : 'assets/google/sign_in_with_google_light.png',
                  fit: BoxFit.contain,
                  cacheHeight: devicePixels,
                ),
              ),
              // The ink ripple has to sit above the artwork, not behind it —
              // the button image is opaque.
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(height / 2),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(onTap: onPressed),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
