import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/environment.dart';
import '../config/theme.dart';
import '../constants/app_constants.dart';

/// Hosts a single django-allauth account flow (signup or password reset) in a
/// restricted WebView, so those flows stay exactly the server's — reCAPTCHA,
/// email verification, throttling and all — without a native re-implementation.
///
/// The app requires an account (there is no anonymous browsing), so this
/// screen is part of the login trap: navigation is confined to the site's
/// account pages. In-scope steps (signup → "verify your email", reset →
/// "email sent") load in place; a link to the web login form returns to the
/// native login screen instead (the native sign-in is the one front door — a
/// web-form login would create a cookie session with no JWT); any other link
/// opens in the system browser so the user can never browse the site in here.
///
/// The site mounts allauth at the root (`/login/`, `/signup/`,
/// `/password/reset/`), not under `/accounts/` — django-allauth's default
/// prefix, which this used to assume and 404'd on every path.
class AllauthWebScreen extends StatefulWidget {
  const AllauthWebScreen.signup({super.key})
    : title = 'Create account',
      initialPath = '/signup/';

  const AllauthWebScreen.passwordReset({super.key})
    : title = 'Reset password',
      initialPath = '/password/reset/';

  final String title;
  final String initialPath;

  @override
  State<AllauthWebScreen> createState() => _AllauthWebScreenState();
}

class _AllauthWebScreenState extends State<AllauthWebScreen> {
  static final InAppWebViewSettings _settings = InAppWebViewSettings(
    userAgent: AppConstants.userAgent,
    useShouldOverrideUrlLoading: true,
    // target="_blank" (e.g. the terms link) → onCreateWindow → system browser.
    supportMultipleWindows: true,
    javaScriptCanOpenWindowsAutomatically: true,
    transparentBackground: true,
  );

  bool _loading = true;

  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) {
      return NavigationActionPolicy.ALLOW;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return NavigationActionPolicy.CANCEL;
    }
    // Sub-frames (the reCAPTCHA iframe lives off-host) must load in place.
    if (!action.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }
    final webHost = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    // Allauth is mounted at the site root here (no shared `/accounts/`
    // prefix to key off), so the trap allow-lists this screen's own flow —
    // its start page plus the handful of pages allauth redirects through —
    // rather than every root-level path, which would let the user wander off
    // into the rest of the site (nav links share the same templates).
    const inFlowPaths = {
      '/signup/',
      '/password/reset/',
      '/password/reset/done/',
      '/confirm-email/',
      '/email/',
    };
    if (uri.host == webHost &&
        (uri.path == widget.initialPath || inFlowPaths.contains(uri.path))) {
      return NavigationActionPolicy.ALLOW;
    }
    if (uri.host == webHost && uri.path == '/login/') {
      // "Already have an account? Sign in" — route to the native login.
      if (mounted) {
        context.go('/login');
      }
      return NavigationActionPolicy.CANCEL;
    }
    // Everything else leaves the account flow — open it outside the trap.
    await _openExternally(uri);
    return NavigationActionPolicy.CANCEL;
  }

  Future<bool> _onCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    final uri = action.request.url;
    if (uri != null) {
      await _openExternally(uri);
    }
    return false;
  }

  Future<void> _openExternally(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // Nothing useful to do — the link just doesn't open.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Stack(
      children: [
        const ColoredBox(
          color: AppTheme.scaffoldBackground,
          child: SizedBox.expand(),
        ),
        InAppWebView(
          initialSettings: _settings,
          initialUrlRequest: URLRequest(
            url: WebUri('${EnvironmentConfig.webBaseUrl}${widget.initialPath}'),
          ),
          onLoadStart: (c, url) {
            if (mounted) {
              setState(() => _loading = true);
            }
          },
          onLoadStop: (c, url) {
            if (mounted) {
              setState(() => _loading = false);
            }
          },
          shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
          onCreateWindow: _onCreateWindow,
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 3),
      ],
    ),
  );
}
