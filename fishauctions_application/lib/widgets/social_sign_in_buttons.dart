import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../models/social_provider.dart';
import 'google_sign_in_button.dart';

/// Renders the sign-in button for [provider], each in that vendor's own
/// required style.
///
/// There is deliberately no shared "social button" look. Both vendors publish
/// binding branding rules and the two differ: Apple's Human Interface
/// Guidelines pin its button's shape, colours and the only permitted labels;
/// Google's guidelines pin the fill, stroke, font and mark spacing (which is
/// why [GoogleSignInButton] draws Google's own artwork). Restyling either into
/// a house style is a review risk with no upside.
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
