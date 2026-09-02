import 'package:fishauctions_application/config/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contrast floors for the native chrome.
///
/// The app's palette is copied from the website's Bootswatch "Darkly" theme so
/// the native/web seam is invisible, and that import brings one trap with it:
/// `--bs-primary` (`#375A7F`) is a *fill* color there — it only ever appears
/// behind white button text — while Material 3 happily uses
/// `colorScheme.primary` as **ink** for `TextButton`/`OutlinedButton` labels
/// and `ExpansionTile` titles. Painted onto `--bs-body-bg` that is 2.2:1:
/// legible on a bright desk, invisible on a phone at an auction.
///
/// The same import has a second trap: a `ColorScheme` role left unset falls
/// back to the role it varies, so `surfaceContainerHighest` silently *was*
/// `surface` and every "subtle raised block" in the app was the same color as
/// the page behind it.
///
/// These are cheap arithmetic checks on a const `ColorScheme`, so they cost a
/// few milliseconds and catch both classes of mistake the next time the
/// palette is touched.
void main() {
  const scheme = AppTheme.darkScheme;

  /// WCAG 2.1 contrast ratio.
  double ratio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final (hi, lo) = la > lb ? (la, lb) : (lb, la);
    return (hi + 0.05) / (lo + 0.05);
  }

  void expectAtLeast(String what, Color fg, Color bg, double floor) {
    final r = ratio(fg, bg);
    expect(
      r,
      greaterThanOrEqualTo(floor),
      reason:
          '$what is ${r.toStringAsFixed(2)}:1, below the $floor:1 floor '
          '(fg $fg on bg $bg)',
    );
  }

  group('text on its own surface (WCAG AA, 4.5:1)', () {
    test('body text', () {
      expectAtLeast(
        'onSurface on surface',
        scheme.onSurface,
        scheme.surface,
        4.5,
      );
      expectAtLeast(
        'onSurfaceVariant on surface',
        scheme.onSurfaceVariant,
        scheme.surface,
        4.5,
      );
    });

    test('every container carries its own "on" color', () {
      expectAtLeast(
        'onPrimary on primary (FilledButton)',
        scheme.onPrimary,
        scheme.primary,
        4.5,
      );
      expectAtLeast(
        'onPrimaryContainer on primaryContainer',
        scheme.onPrimaryContainer,
        scheme.primaryContainer,
        4.5,
      );
      // FilledButton.tonal — this was white on the bright link blue at 2.8:1
      // for as long as `secondaryContainer` was left to fall back to
      // `secondary`.
      expectAtLeast(
        'onSecondaryContainer on secondaryContainer (tonal buttons)',
        scheme.onSecondaryContainer,
        scheme.secondaryContainer,
        4.5,
      );
      expectAtLeast(
        'onErrorContainer on errorContainer',
        scheme.onErrorContainer,
        scheme.errorContainer,
        4.5,
      );
    });

    test('button ink, on every surface a button sits on', () {
      // What TextButton/OutlinedButton actually resolve to, not just the role
      // they came from — the whole point of the override is that Material's
      // own default (primary) fails here.
      final theme = AppTheme.dark;
      final states = <WidgetState>{};
      final text = theme.textButtonTheme.style!.foregroundColor!.resolve(
        states,
      )!;
      final outlined = theme.outlinedButtonTheme.style!.foregroundColor!
          .resolve(states)!;
      for (final (name, ink) in [
        ('TextButton', text),
        ('OutlinedButton', outlined),
      ]) {
        for (final (where, bg) in [
          ('a page', scheme.surface),
          ('a dialog', scheme.surfaceContainerHigh),
          ('a bottom sheet', scheme.surfaceContainerLow),
          ('a raised block', scheme.surfaceContainerHighest),
        ]) {
          expectAtLeast('$name label on $where', ink, bg, 4.5);
        }
      }
    });

    test('primary is a fill, never ink', () {
      // Documents the trap rather than guarding a value: if this ever passes,
      // the palette moved and the overrides above can be reconsidered.
      expect(
        ratio(scheme.primary, scheme.surface),
        lessThan(4.5),
        reason:
            'primary is now readable on the page background — Darkly\'s '
            'btn-primary fill has changed, so revisit AppTheme\'s ink '
            'overrides.',
      );
    });
  });

  group('non-text contrast (WCAG AA, 3:1)', () {
    test('outline is visible on every surface it borders', () {
      expectAtLeast('outline on surface', scheme.outline, scheme.surface, 3);
      expectAtLeast(
        'outline on a bottom sheet',
        scheme.outline,
        scheme.surfaceContainerLow,
        3,
      );
    });

    test('error ink', () {
      // The site's own `--bs-danger`, kept for the seam: 4.1:1, which clears
      // the 3:1 large-text/icon floor but not 4.5:1. Sentences of error text
      // belong on `errorContainer`/`onErrorContainer` (checked above), which
      // is what the Tap to Pay and payment-sheet panels use.
      expectAtLeast('error on surface', scheme.error, scheme.surface, 3);
    });
  });

  group('the surface ladder is actually a ladder', () {
    test('each step is distinguishable from the page', () {
      for (final (name, c) in [
        ('surfaceContainerLow (sheets)', scheme.surfaceContainerLow),
        ('surfaceContainer', scheme.surfaceContainer),
        ('surfaceContainerHigh (dialogs, drawer)', scheme.surfaceContainerHigh),
        (
          'surfaceContainerHighest (inset blocks)',
          scheme.surfaceContainerHighest,
        ),
      ]) {
        expect(
          c,
          isNot(scheme.surface),
          reason: '$name is the same color as the page behind it',
        );
      }
      // The inset blocks (login offline notice, printer characterization
      // summary, Tap to Pay status cards) have to read as a block.
      expect(
        ratio(scheme.surfaceContainerHighest, scheme.surface),
        greaterThan(1.15),
        reason: 'raised blocks are indistinguishable from the page',
      );
    });
  });
}
