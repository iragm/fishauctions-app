import 'package:flutter/material.dart';

/// Theme for the app's native chrome (app bar, drawer, login / payment /
/// printer screens, progress bars).
///
/// The web UI the WebView loads is forced-dark — `data-bs-theme="dark"`,
/// Bootswatch "Darkly" — so the native shell around it must be dark too.
/// Otherwise a light app bar and the white first-paint flash frame an otherwise
/// dark page. The colors below mirror the site's CSS variables (from
/// bootstrap.min.css + auction_site.css) so the native/web seam is invisible.
class AppTheme {
  const AppTheme._();

  // ── Web palette (Bootswatch Darkly + site link override) ──────────────────
  static const Color _bodyBg = Color(0xFF222222); // --bs-body-bg
  static const Color _surface = Color(0xFF303030); // --bs-secondary-bg
  static const Color _bodyText = Color(0xFFDEE2E6); // --bs-body-color
  static const Color _primary = Color(0xFF375A7F); // --bs-primary / btn-primary
  static const Color _accent = Color(0xFF2FA4E7); // link color (a { color })
  static const Color _danger = Color(0xFFE74C3C); // --bs-danger
  static const Color _border = Color(0xFF444444); // --bs-border-color

  /// The page background, reused for the WebView's own background so the
  /// pre-paint window matches the loaded page instead of flashing white.
  static const Color scaffoldBackground = _bodyBg;

  static ThemeData get dark {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _primary,
      onPrimary: Colors.white,
      secondary: _accent,
      onSecondary: Colors.white,
      surface: _bodyBg,
      onSurface: _bodyText,
      error: _danger,
      onError: Colors.white,
      outline: _border,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: _bodyBg,
      appBarTheme: const AppBarTheme(
        backgroundColor: _surface,
        foregroundColor: _bodyText,
        elevation: 0,
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: _surface),
      dividerTheme: const DividerThemeData(color: _border),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: _accent),
    );
  }
}
