import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../models/social_provider.dart';
import 'google_sign_in_button.dart';

/// Renders the sign-in button for [provider], each in that vendor's own
/// required style.
///
/// There is deliberately no shared "social button" look. All three vendors
/// publish binding branding rules and all three differ: Apple's Human Interface
/// Guidelines pin its button's shape, colours and the only permitted labels;
/// Google's guidelines pin the fill, stroke, font and mark spacing (which is
/// why [GoogleSignInButton] draws Google's own artwork); Facebook requires its
/// blue, its logo and one of its approved labels. Restyling any of them into a
/// house style is a review risk with no upside.
///
/// [height] keeps them the same size as each other, which Apple's guidelines
/// explicitly ask for — its button must be at least as prominent as the others.
class SocialSignInButton extends StatelessWidget {
  const SocialSignInButton({
    required this.provider,
    required this.onPressed,
    super.key,
    this.height = 52,
  });

  final SocialProvider provider;

  /// Null disables the button: dimmed, no ripple, no tap.
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) => switch (provider) {
    SocialProvider.google => GoogleSignInButton(
      onPressed: onPressed,
      height: height,
    ),
    SocialProvider.apple => _AppleButton(onPressed: onPressed, height: height),
    SocialProvider.facebook => _FacebookButton(
      onPressed: onPressed,
      height: height,
    ),
  };
}

/// Apple's own button, from `sign_in_with_apple` — the package renders the
/// shape, the logo and the type per the Human Interface Guidelines, so we
/// choose only the light/dark variant and the size.
///
/// Never rebuild this by hand. The HIG forbids altering the mark, and the
/// button's exact corner radius, logo size and label are all specified; a
/// lookalike is a documented App Review rejection.
class _AppleButton extends StatelessWidget {
  const _AppleButton({required this.onPressed, required this.height});

  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SizedBox(
        height: height,
        child: SignInWithAppleButton(
          // A no-op when disabled: the widget's callback isn't nullable, and
          // wrapping it in an IgnorePointer instead would keep the button
          // looking live while silently swallowing taps.
          onPressed: onPressed ?? () {},
          height: height,
          // The HIG's two sanctioned labels are "Sign in with Apple" and
          // "Continue with Apple". This screen signs in.
          // ignore: avoid_redundant_argument_values
          text: 'Sign in with Apple',
          style: Theme.of(context).brightness == Brightness.dark
              ? SignInWithAppleButtonStyle.white
              : SignInWithAppleButtonStyle.black,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      ),
    );
  }
}

/// Facebook's login button.
///
/// Built rather than imaged because Facebook's brand guidelines specify the
/// colour (`#1877F2`), the corner treatment and an approved label, but ship the
/// logo separately — see [facebookLogoAsset]. Until that asset is added the
/// button renders text-only in Facebook blue, which is legible and honest;
/// **drawing a substitute "f" mark would not be**, for the same reason the app
/// ships no lookalike Tap to Pay symbol.
class _FacebookButton extends StatelessWidget {
  const _FacebookButton({required this.onPressed, required this.height});

  final VoidCallback? onPressed;
  final double height;

  /// Facebook brand blue, from their brand guidelines. Not themeable — the
  /// guidelines require this exact colour on the primary button.
  static const Color _brandBlue = Color(0xFF1877F2);

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SizedBox(
        height: height,
        child: ElevatedButton.icon(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: _brandBlue,
            foregroundColor: Colors.white,
            disabledBackgroundColor: _brandBlue,
            disabledForegroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(height / 2),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: facebookLogoAsset == null
              ? const SizedBox.shrink()
              : Image.asset(
                  facebookLogoAsset!,
                  height: height * 0.45,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
          // "Continue with Facebook" is Facebook's approved label and the one
          // that stays accurate whether this creates an account or signs in to
          // an existing one.
          label: const Text('Continue with Facebook'),
        ),
      ),
    );
  }
}

/// Path to Facebook's official "f" logo, exported into `assets/facebook/`, or
/// null while it hasn't been added.
///
/// To add it: download the logo from Facebook's brand resources
/// (about.meta.com/brand/resources/facebook/logo), drop the white-on-transparent
/// PNG at `assets/facebook/facebook_logo.png`, declare `assets/facebook/` in
/// `pubspec.yaml`, and set this. Use their file unmodified — the guidelines
/// forbid redrawing or recolouring the mark.
const String? facebookLogoAsset = null;
