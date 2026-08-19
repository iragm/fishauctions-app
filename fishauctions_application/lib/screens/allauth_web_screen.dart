import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/environment.dart';
import '../config/theme.dart';
import '../constants/app_constants.dart';
import '../models/app_config.dart';
import '../providers/config_provider.dart';
import '../utils/external_links.dart';
import '../widgets/legal_links.dart';

/// Hosts a single django-allauth account flow (signup or password reset) in a
/// restricted WebView, so those flows stay exactly the server's — reCAPTCHA,
/// email verification, throttling and all — without a native re-implementation.
/// Also serves the terms/privacy pages the signup screen has to link to, which
/// are read-only pages on the same host and want exactly the same containment.
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
class AllauthWebScreen extends ConsumerStatefulWidget {
  const AllauthWebScreen.signup({super.key})
    : title = 'Create account',
      initialPath = '/signup/',
      showLegalFooter = true,
      completionPath = null;

  const AllauthWebScreen.passwordReset({super.key})
    : title = 'Reset password',
      initialPath = '/password/reset/',
      showLegalFooter = false,
      completionPath = null;

  /// A read-only legal page (terms, privacy policy) reached from the login or
  /// signup screen. [initialPath] comes from `/api/mobile/config/` and is
  /// always same-host and site-relative by then (see `AppConfig`).
  const AllauthWebScreen.legal({
    required this.title,
    required this.initialPath,
    super.key,
  }) : showLegalFooter = false,
       completionPath = null;

  /// Finishing a native social sign-in that couldn't complete on its own —
  /// allauth needs an email address, or needs the one it has confirmed.
  ///
  /// This is allauth's own social-signup / email-confirmation flow, hosted
  /// exactly like signup is, for exactly the same reason: re-implementing it
  /// natively would mean duplicating its rate limiting, its "that address
  /// belongs to another account" rules and its confirmation-link handling, and
  /// getting any of those subtly wrong is an account-takeover bug, not a
  /// cosmetic one.
  ///
  /// Pops `true` once the server redirects to [completionPath]; the caller then
  /// exchanges its pending token for a session.
  const AllauthWebScreen.socialContinue({
    required this.initialPath,
    super.key,
    this.completionPath = defaultSocialCompletionPath,
  }) : title = 'Finish signing in',
       showLegalFooter = true;

  /// Where the backend lands a finished social continuation. Kept in one place
  /// because the app must recognise it exactly — see `BACKEND_SPEC.md`
  /// Part SOCIAL.
  static const String defaultSocialCompletionPath =
      '/api/mobile/auth/social/done/';

  final String title;
  final String initialPath;

  /// When set, reaching this path means the flow succeeded: the screen pops
  /// `true` instead of rendering it. Null for the signup/reset/legal flows,
  /// which have no "and now return to the app" step.
  final String? completionPath;

  /// Whether to draw the terms/privacy links under the page. On the signup
  /// screen they're required — that's where the account is created, and Apple
  /// expects the links at that point — and the Django template doesn't carry
  /// them (BACKEND_SPEC.md Part L covers adding them server-side, at which
  /// point these become a belt-and-braces duplicate rather than the only copy).
  final bool showLegalFooter;

  @override
  ConsumerState<AllauthWebScreen> createState() => _AllauthWebScreenState();
}

class _AllauthWebScreenState extends ConsumerState<AllauthWebScreen> {
  static final InAppWebViewSettings _settings = InAppWebViewSettings(
    userAgent: AppConstants.userAgent,
    useShouldOverrideUrlLoading: true,
    // target="_blank" (e.g. the terms link) → onCreateWindow → system browser.
    supportMultipleWindows: true,
    javaScriptCanOpenWindowsAutomatically: true,
    transparentBackground: true,
  );

  InAppWebViewController? _controller;
  bool _loading = true;

  /// Set when the page couldn't load at all — almost always no connectivity,
  /// which is a real first-run case: someone installs the app on hotel wifi
  /// that hasn't logged in yet and taps "Create account". The engine's own
  /// error page is a bare "webpage not available" with no way back, so we
  /// replace it with something that says what happened and offers a retry.
  String? _loadError;

  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) {
      return NavigationActionPolicy.ALLOW;
    }
    // mailto:/tel:/sms: go to the OS, not to the engine — allauth's
    // confirm-address page links the address it is asking about.
    if (isHandoffScheme(uri)) {
      await _openExternally(uri);
      return NavigationActionPolicy.CANCEL;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return NavigationActionPolicy.CANCEL;
    }
    // Sub-frames (the reCAPTCHA iframe lives off-host) must load in place.
    if (!action.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }
    final webHost = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    // The social continuation is finished: hand control back to the caller,
    // which swaps its pending token for a session. Checked before the
    // allow-list, since this path must never render.
    final completionPath = widget.completionPath;
    if (completionPath != null &&
        uri.host == webHost &&
        uri.path == completionPath) {
      if (mounted) {
        Navigator.of(context).pop(true);
      }
      return NavigationActionPolicy.CANCEL;
    }
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
      // allauth's socialaccount signup form — where it asks for the email a
      // provider didn't supply — and the page it bounces to when the chosen
      // address is already taken.
      '/social/signup/',
      '/social/connections/',
    };
    if (uri.host == webHost &&
        (uri.path == widget.initialPath || inFlowPaths.contains(uri.path))) {
      return NavigationActionPolicy.ALLOW;
    }
    // The terms/privacy pages, whether reached from this screen's native footer
    // or from a link the signup template grows later. In place, not in the
    // system browser: bouncing someone out of sign-up to read the terms and
    // back is how you lose a half-filled form.
    if (uri.host == webHost && _isLegalPath(uri.path)) {
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

  /// Whether [path] is one of this deployment's legal pages, per
  /// `/api/mobile/config/` (with the `/tos/` fallback). Read from the provider
  /// rather than hardcoded so a fork's own document paths are allowed too.
  bool _isLegalPath(String path) {
    final config = ref.read(configProvider).value;
    final terms = config?.termsPath ?? AppConfig.defaultTermsPath;
    final privacy = config?.privacyPath ?? '';
    return path == terms || (privacy.isNotEmpty && path == privacy);
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

  /// A main-frame load failure. Signing up is the one flow with no offline
  /// fallback at all (there is no account yet, so nothing is cached), so all we
  /// can offer is an honest explanation and a retry.
  void _onLoadError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    if (!(request.isForMainFrame ?? true) || !mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _loadError =
          'Couldn\'t reach ${Uri.parse(EnvironmentConfig.webBaseUrl).host}. '
          'Check your connection and try again.';
    });
  }

  Future<void> _retry() async {
    setState(() {
      _loadError = null;
      _loading = true;
    });
    final controller = _controller;
    if (controller == null) {
      return;
    }
    await controller.loadUrl(
      urlRequest: URLRequest(
        url: WebUri('${EnvironmentConfig.webBaseUrl}${widget.initialPath}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              const ColoredBox(
                color: AppTheme.scaffoldBackground,
                child: SizedBox.expand(),
              ),
              // Kept mounted underneath the error panel so a retry reuses the
              // same controller (and whatever the user had typed, when the
              // failure was a submit rather than the first load).
              InAppWebView(
                initialSettings: _settings,
                initialUrlRequest: URLRequest(
                  url: WebUri(
                    '${EnvironmentConfig.webBaseUrl}${widget.initialPath}',
                  ),
                ),
                onWebViewCreated: (c) => _controller = c,
                onLoadStart: (c, url) {
                  if (mounted) {
                    setState(() {
                      _loading = true;
                      _loadError = null;
                    });
                  }
                },
                onLoadStop: (c, url) {
                  if (mounted) {
                    setState(() => _loading = false);
                  }
                },
                onReceivedError: _onLoadError,
                shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
                onCreateWindow: _onCreateWindow,
              ),
              if (_loadError case final message?) _errorPanel(message),
              if (_loading) const LinearProgressIndicator(minHeight: 3),
            ],
          ),
        ),
        if (widget.showLegalFooter)
          const SafeArea(top: false, child: LegalLinks()),
      ],
    ),
  );

  Widget _errorPanel(String message) => ColoredBox(
    color: AppTheme.scaffoldBackground,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => unawaited(_retry()),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    ),
  );
}
