import 'package:flutter/material.dart';

/// Theme for the app's native chrome (app bar, drawer, login / payment /
/// printer screens, progress bars).
///
/// The web UI the WebView loads is forced-dark — `data-bs-theme="dark"`,
/// Bootswatch "Darkly" — so the native shell around it must be dark too.
/// Otherwise a light app bar and the white first-paint flash frame an otherwise
/// dark page. The colors below mirror the site's CSS variables (from
/// bootstrap.min.css + auction_site.css) so the native/web seam is invisible.
///
/// **`_primary` is a *background* color, and Material spends it as ink.**
/// Darkly's `btn-primary` is `#375A7F` — a dark navy that carries white text
/// perfectly well and is unreadable *on* the body background (2.2:1, below even
/// the 3:1 floor for large text). Material 3 doesn't make that distinction: it
/// paints `TextButton`/`OutlinedButton` labels, `ExpansionTile` titles when
/// expanded and the text cursor in `colorScheme.primary` straight onto the
/// surface. So every one of those is overridden below to the
/// site's *link* color (`_accent`), which is the web's own answer to the same
/// question, and a section header that reaches for `colorScheme.primary` should
/// use `colorScheme.secondary` instead.
///
/// **Roles left unset don't fall back to something sensible, they fall back to
/// the role they're a variant of** — `ColorScheme.surfaceContainerHighest`
/// resolves to plain `surface` and `secondaryContainer` to `secondary`. That's
/// how the "subtle raised block" behind the login offline notice, the printer
/// characterization summary and the Tap to Pay status cards became invisible
/// (identical to the page behind them), and how `FilledButton.tonal` ended up
/// white-on-`#2FA4E7` at 2.8:1. The whole surface ladder and every container
/// pair is therefore spelled out, even where the fallback happened to be right.
///
/// `test/config/theme_test.dart` holds the contrast ratios to the WCAG floors,
/// so a future palette edit can't quietly reintroduce either failure.
class AppTheme {
  const AppTheme._();

  // ── Web palette (Bootswatch Darkly + site link override) ──────────────────
  static const Color _bodyBg = Color(0xFF222222); // --bs-body-bg
  static const Color _surface = Color(0xFF303030); // --bs-secondary-bg
  static const Color _bodyText = Color(0xFFDEE2E6); // --bs-body-color
  static const Color _mutedText = Color(0xFFADB5BD); // --bs-secondary-color
  static const Color _primary = Color(0xFF375A7F); // --bs-primary / btn-primary
  static const Color _accent = Color(0xFF2FA4E7); // link color (a { color })
  static const Color _danger = Color(0xFFE74C3C); // --bs-danger
  static const Color _border = Color(0xFF444444); // --bs-border-color
  static const Color _outline = Color(0xFF6C757D); // --bs-gray-600

  /// The surface ladder Material 3 paints its containers from, in the site's
  /// greys: dialogs, menus and the drawer sit on `_surface` — the site's own
  /// card color — with bottom sheets a step below and an inset block a step
  /// above. The steps are deliberately small. A raised block still has to
  /// carry a `TextButton` at 4.5:1, and the link blue runs out of contrast
  /// somewhere around `#343434`, so a livelier ladder would buy separation
  /// with the legibility of the buttons sitting on it.
  static const Color _surfaceLowest = Color(0xFF1A1A1A);
  static const Color _surfaceLow = Color(0xFF2A2A2A);
  static const Color _surfaceMid = Color(0xFF2C2C2C);
  static const Color _surfaceRaised = Color(0xFF323232);
  static const Color _surfaceBright = Color(0xFF3A3A3A);

  /// Tonal (`FilledButton.tonal`, `secondaryContainer`) surfaces: the link
  /// color mixed down into the background rather than used at full strength,
  /// so body text sits on it at 8:1 instead of white-on-bright-blue at 2.8:1.
  static const Color _accentSurface = Color(0xFF254253);

  /// A danger *block* (`errorContainer`), as distinct from danger *ink*.
  /// Bootstrap draws its dark-theme alerts the same way — a desaturated, very
  /// dark red panel with light red text — because `--bs-danger` behind white
  /// text is only 3.8:1, and these panels carry sentences, not headlines.
  static const Color _dangerSurface = Color(0xFF452927);
  static const Color _dangerInk = Color(0xFFF5B7B1);

  /// `--bs-warning` / `--bs-success` from the same Darkly palette. Native
  /// overlays that mean "warning"/"success" (AR's watched and recommended
  /// markers) use these so they read as the same semantic colors the web UI
  /// uses for the same things.
  static const Color warning = Color(0xFFF39C12);
  static const Color success = Color(0xFF00BC8C);

  /// The page background, reused for the WebView's own background so the
  /// pre-paint window matches the loaded page instead of flashing white.
  static const Color scaffoldBackground = _bodyBg;

  /// The color to use for anything drawn *on* the page background that would
  /// otherwise reach for [ColorScheme.primary] — button labels, section
  /// headers, links. Exposed as `colorScheme.secondary` too; named here so the
  /// reason is greppable from the call sites.
  static const Color inkAccent = _accent;

  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: _primary,
    onPrimary: Colors.white,
    primaryContainer: _primary,
    onPrimaryContainer: Colors.white,
    secondary: _accent,
    onSecondary: Colors.white,
    secondaryContainer: _accentSurface,
    onSecondaryContainer: _bodyText,
    surface: _bodyBg,
    onSurface: _bodyText,
    onSurfaceVariant: _mutedText,
    surfaceDim: _bodyBg,
    surfaceBright: _surfaceBright,
    surfaceContainerLowest: _surfaceLowest,
    surfaceContainerLow: _surfaceLow,
    surfaceContainer: _surfaceMid,
    surfaceContainerHigh: _surface,
    surfaceContainerHighest: _surfaceRaised,
    error: _danger,
    onError: Colors.white,
    errorContainer: _dangerSurface,
    onErrorContainer: _dangerInk,
    outline: _outline,
    outlineVariant: _border,
  );

  /// Disabled ink, matching Material's own 38% treatment. Passed explicitly
  /// because `styleFrom(foregroundColor:)` alone applies that color in *every*
  /// state — a disabled button would otherwise look pressable.
  static final Color _disabledInk = _bodyText.withValues(alpha: 0.38);

  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: darkScheme,
    scaffoldBackgroundColor: _bodyBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: _surface,
      foregroundColor: _bodyText,
      elevation: 0,
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: _surface),
    dividerTheme: const DividerThemeData(color: _border),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: _accent),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: _accent,
        disabledForegroundColor: _disabledInk,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: _accent,
        disabledForegroundColor: _disabledInk,
      ),
    ),
    // Collapsed, an ExpansionTile is an ordinary list row; expanded, Material
    // tints its title and chevron with `primary` — which is the navy above.
    expansionTileTheme: const ExpansionTileThemeData(
      textColor: _accent,
      iconColor: _accent,
      collapsedTextColor: _bodyText,
      collapsedIconColor: _mutedText,
    ),
    // The text cursor, which Material also paints in `primary` — a two-pixel
    // navy line on `#222222`. The *focus ring* is deliberately left alone:
    // an `InputDecorationTheme.focusedBorder` outranks a field's own
    // `border: InputBorder.none` (`InputDecorator` picks the state border
    // first and only falls back to the decoration's), so setting one here
    // would draw a box around the command palette's borderless search field
    // the moment it takes focus — which is always, it autofocuses.
    textSelectionTheme: const TextSelectionThemeData(cursorColor: _accent),
  );
}
