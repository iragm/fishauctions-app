import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../config/environment.dart';
import '../config/theme.dart';
import '../constants/app_constants.dart';
import '../models/auth_models.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
import 'command_palette_screen.dart';

class WebViewScreen extends ConsumerStatefulWidget {
  const WebViewScreen({super.key});

  @override
  ConsumerState<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends ConsumerState<WebViewScreen>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _loading = true;
  // The soft location banner is offered at most once per app session, the first
  // time the user reaches a location-aware screen. See _maybeOfferLocation.
  bool _locationOffered = false;

  // ── Single sign-on bridging ───────────────────────────────────────────────
  // The native JWT (authProvider) is the source of truth for "signed in". When
  // it flips to signed-in we log the WebView's Django session in too, via the
  // backend handoff, so one sign-in covers both. These guard that bridging:
  //
  // _sawInitialAuth  – skip the first authProvider resolution (session restore
  //                    on launch); the WebView's own persisted cookie usually
  //                    already covers it, and _reconcileWebSession repairs the
  //                    rare case where it doesn't.
  // _lastSignedIn    – the last signed-in state we acted on (edge detection).
  // _handoffAttempts – at most one handoff per signed-in state, reset on every
  //                    auth transition, so a failed/looping handoff can't spin.
  bool _sawInitialAuth = false;
  bool _lastSignedIn = false;
  int _handoffAttempts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Match the loaded page's dark background so the pre-paint window doesn't
      // flash white over the otherwise-dark UI.
      ..setBackgroundColor(AppTheme.scaffoldBackground)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onNavigationRequest: _handleNavigation,
        ),
      )
      ..setUserAgent(
        'FishAuctionsApp/1.0 (Flutter; ${defaultTargetPlatform.name})',
      );
    _enableWebViewCamera();
    _initWebView();
  }

  /// The web check-in screen scans barcodes through the browser camera
  /// (`getUserMedia`). The system WebView denies that by default, so bridge its
  /// permission request to a native runtime prompt: when the page asks for the
  /// camera we request Android's CAMERA permission and grant the WebView only
  /// if the user allows it. Requests we can't satisfy (e.g. the microphone,
  /// which the app declares no permission for) are denied so the page fails
  /// fast rather than hanging on a request that could never succeed.
  ///
  /// Android-only: iOS WKWebView drives its own prompt from the Info.plist
  /// camera usage string, and the iOS flavor isn't wired up yet.
  void _enableWebViewCamera() {
    final platform = _controller.platform;
    if (platform is! AndroidWebViewController) {
      return;
    }
    platform.setOnPlatformPermissionRequest((request) async {
      // Only the camera is something we can satisfy, so handle the lone-camera
      // request and deny anything else (including camera+microphone bundles).
      final wantsOnlyCamera =
          request.types.length == 1 &&
          request.types.contains(WebViewPermissionResourceType.camera);
      if (!wantsOnlyCamera) {
        await request.deny();
        return;
      }
      final status = await Permission.camera.request();
      if (status.isGranted) {
        await request.grant();
      } else {
        await request.deny();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh the location cookies silently when the app returns to the
    // foreground — the user may have moved. The server reads them per request,
    // so the next navigation/XHR picks up the newest position; no reload (that
    // would be jarring mid-browse). Never prompts here.
    if (state == AppLifecycleState.resumed) {
      _applyLocation(prompt: false);
    }
  }

  Future<void> _initWebView() async {
    // The system WebView persists its cookies, so a returning signed-in user is
    // usually still logged in here without any work. We don't block first paint
    // on auth: if the native JWT is present but the web cookie has lapsed,
    // _reconcileWebSession (on page-finished) silently re-establishes it.
    //
    // If location is already granted, seed the cookies from the instant cached
    // fix so distances render on the first page without delaying it. We never
    // prompt at app open — that happens contextually on a location-aware screen
    // (see _maybeOfferLocation).
    await _applyLocation(prompt: false, fresh: false);
    await _controller.loadRequest(Uri.parse(EnvironmentConfig.webBaseUrl));
  }

  /// Reads the device position and, if available, writes the
  /// `latitude`/`longitude` cookies the web UI reads. Returns true when cookies
  /// were written. A denied/unavailable location is a no-op, so listings just
  /// render without distances.
  ///
  /// [prompt] shows the OS permission dialog when undecided; otherwise it reads
  /// silently (null unless already granted). [fresh] is forwarded to the silent
  /// read — false for an instant cached fix (pre-navigation), true for a
  /// current fix (foreground). Prompting always uses a current fix.
  Future<bool> _applyLocation({required bool prompt, bool fresh = true}) async {
    final position = prompt
        ? await LocationService.instance.requestAndGetPosition()
        : await LocationService.instance.positionIfPermitted(fresh: fresh);
    if (position == null) {
      return false;
    }
    await _setLocationCookies(position);
    return true;
  }

  Future<void> _setLocationCookies(Position position) async {
    final host = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    final manager = WebViewCookieManager();
    // Non-HttpOnly, non-sensitive cookies the web UI also sets from JS; path '/'
    // and the site host match what document.cookie writes, so the server reads
    // them the same way whether they came from the browser or from here.
    await manager.setCookie(
      WebViewCookie(
        name: 'latitude',
        value: LocationService.formatCoordinate(position.latitude),
        domain: host,
      ),
    );
    await manager.setCookie(
      WebViewCookie(
        name: 'longitude',
        value: LocationService.formatCoordinate(position.longitude),
        domain: host,
      ),
    );
  }

  /// The first time the user lands on a location-aware screen without location
  /// set, offer a soft, dismissible banner. Runs at most once per app session.
  /// If location is already granted we just refresh the cookies silently; if it
  /// was permanently denied we stay quiet (the banner couldn't re-prompt).
  Future<void> _maybeOfferLocation(String path) async {
    if (_locationOffered || !LocationService.isLocationAwarePath(path)) {
      return;
    }
    if (await LocationService.instance.hasPermission()) {
      _locationOffered = true;
      // Already granted: refine the pre-load cached fix to a current one for
      // subsequent navigations. No reload — the page already rendered.
      await _applyLocation(prompt: false);
      return;
    }
    if (!await LocationService.instance.canPrompt()) {
      _locationOffered = true; // permanently denied — nothing we can offer
      return;
    }
    _locationOffered = true;
    _showLocationBanner();
  }

  void _showLocationBanner() {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.location_on_outlined),
        content: const Text(
          'See auctions near you? Enable location to show the distance to each '
          'one.',
        ),
        actions: [
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: _enableLocationFromBanner,
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  Future<void> _enableLocationFromBanner() async {
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    }
    // Prompt, and on a grant reload so the page in front of the user gains
    // distances immediately. A decline is a no-op — same as a web visitor who
    // declines the browser prompt.
    if (await _applyLocation(prompt: true)) {
      await _controller.reload();
    }
  }

  void _onPageStarted(String url) {
    // A new page load supersedes any location banner the user hasn't acted on,
    // so it doesn't float over an unrelated screen.
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    }
    setState(() => _loading = true);
  }

  Future<void> _onPageFinished(String url) async {
    if (mounted) {
      setState(() => _loading = false);
    }
    final uri = Uri.parse(url);
    // On the auctions/lots screens, offer location in context (once per
    // session). The home page and everything else never triggers this.
    unawaited(_maybeOfferLocation(uri.path));
    await _reconcileWebSession(uri);
  }

  // ── WebView ↔ native session bridging ─────────────────────────────────────

  /// Reacts to the native auth state changing. When the user signs in, log the
  /// WebView's Django session in too (handoff) so one sign-in covers both. The
  /// first resolution (session restore on launch) is skipped — the WebView
  /// usually already holds a valid cookie, and _reconcileWebSession covers the
  /// case it doesn't.
  void _onAuthChanged(
    AsyncValue<AppUser?>? previous,
    AsyncValue<AppUser?> next,
  ) {
    if (next.isLoading) {
      return;
    }
    final signedIn = next.valueOrNull != null;
    if (!_sawInitialAuth) {
      _sawInitialAuth = true;
      _lastSignedIn = signedIn;
      return;
    }
    if (signedIn == _lastSignedIn) {
      return;
    }
    _lastSignedIn = signedIn;
    _handoffAttempts = 0; // a new auth state gets a fresh handoff budget
    if (signedIn) {
      // Land back on the page the user was on, now authenticated.
      _ensureWebSession();
    }
    // Sign-out needs no action here: the logout navigation clears the web
    // session, and the menu follows authProvider.
  }

  /// Repairs session drift on each page load. The web navbar is hidden in-app
  /// (the server detects the app from its User-Agent), so the reliable signal
  /// that the WebView's session has lapsed is the server bouncing an
  /// auth-required page to /accounts/login/:
  ///  • signed in natively → run the handoff to re-establish the web session
  ///    and resume the intended ?next= destination;
  ///  • signed out → funnel sign-in through the native screen (the one front
  ///    door for both sessions) rather than the web login form, which would
  ///    create a web-only session with no JWT.
  Future<void> _reconcileWebSession(Uri uri) async {
    final webHost = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    if (uri.path != '/accounts/login/' || uri.host != webHost) {
      return;
    }
    if (ref.read(authProvider).valueOrNull != null) {
      await _ensureWebSession(next: uri.queryParameters['next']);
    } else if (mounted) {
      unawaited(context.push('/login'));
    }
  }

  /// Logs the WebView into the Django session matching the native JWT, via the
  /// backend handoff. Bounded to one attempt per signed-in state (reset on each
  /// auth transition) so a failed handoff can't loop.
  Future<void> _ensureWebSession({String? next}) async {
    if (_handoffAttempts > 0) {
      return;
    }
    _handoffAttempts++;
    final target = next ?? await _currentWebPath();
    final url = await AuthService.instance.createWebSessionHandoffUrl(
      next: target,
    );
    if (url != null) {
      await _controller.loadRequest(Uri.parse(url));
    }
  }

  /// Path (+query) of the page currently in the WebView, for the post-handoff
  /// landing page. Auth pages resolve to their ?next= target, not themselves.
  Future<String?> _currentWebPath() async {
    final current = await _controller.currentUrl();
    if (current == null) {
      return null;
    }
    final uri = Uri.parse(current);
    if (uri.path.startsWith('/accounts/')) {
      return uri.queryParameters['next'];
    }
    return _pathOf(uri);
  }

  String? _pathOf(Uri uri) {
    final pathQuery = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    return pathQuery.isEmpty ? null : pathQuery;
  }

  /// Sign out everywhere: drop the native JWT (drives the menu, releases
  /// Square) and POST the web logout so Django clears its session cookie.
  /// allauth requires POST + CSRF, so submit a form carrying the csrftoken
  /// cookie rather than navigating by GET.
  Future<void> _signOut() async {
    await ref.read(authProvider.notifier).logout();
    await _controller.runJavaScript(_logoutFormJs);
  }

  // Submits a real POST to the allauth logout view, carrying the CSRF token
  // from the cookie (logout is POST-only; a GET just renders a confirm page).
  static const String _logoutFormJs = '''
(function(){
  var m = document.cookie.match(/(?:^|; )csrftoken=([^;]+)/);
  var f = document.createElement('form');
  f.method = 'POST';
  f.action = '/accounts/logout/';
  if (m) {
    var i = document.createElement('input');
    i.type = 'hidden';
    i.name = 'csrfmiddlewaretoken';
    i.value = decodeURIComponent(m[1]);
    f.appendChild(i);
  }
  document.body.appendChild(f);
  f.submit();
})();
''';

  void _loadPath(String path) {
    _controller.loadRequest(Uri.parse('${EnvironmentConfig.webBaseUrl}$path'));
  }

  void _navigate(BuildContext drawerContext, String path) {
    Navigator.of(drawerContext).pop();
    _loadPath(path);
  }

  void _onTitleTap() {
    // The command palette is backed by the JWT API, so it needs a native
    // sign-in. Prompt for one if missing; otherwise open search.
    final user = ref.read(authProvider).valueOrNull;
    if (user == null) {
      context.push('/login');
      return;
    }
    showCommandPalette(context, _loadPath);
  }

  NavigationDecision _handleNavigation(NavigationRequest request) {
    final uri = Uri.parse(request.url);

    if (uri.scheme == EnvironmentConfig.urlScheme) {
      _handleDeepLink(uri);
      return NavigationDecision.prevent;
    }

    // Only allow standard web navigation. Block javascript:, intent:, file:,
    // and other schemes that injected or remote content could abuse. http(s)
    // stays open so allauth social-login redirects (Google, Discord) work.
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return NavigationDecision.prevent;
    }

    // A logout anywhere — our menu or the in-page web sign-out — must also drop
    // the native JWT so the two sessions stay in lockstep. The server clears
    // the session cookie on its own logout response, so we don't touch WebView
    // cookies here (clearing them would strip the CSRF cookie the POST needs).
    // Scope this to our own host so an external page (e.g. a social-login
    // redirect) that happens to use the same path can't log the user out. Skip
    // if already signed out, so our menu's own logout doesn't double-fire.
    final webHost = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    if (uri.path == '/accounts/logout/' &&
        uri.host == webHost &&
        ref.read(authProvider).valueOrNull != null) {
      ref.read(authProvider.notifier).logout();
    }

    return NavigationDecision.navigate;
  }

  void _handleDeepLink(Uri uri) {
    switch (uri.host) {
      case 'pay':
        final invoicePk = int.tryParse(uri.pathSegments.firstOrNull ?? '');
        if (invoicePk != null) {
          context.push('/pay/$invoicePk');
        }
      case 'print':
        // fishauctions://print/<lot_pk> — print a label. Without a valid pk
        // (e.g. a bare "set up printer" link) fall back to printer settings.
        final lotPk = int.tryParse(uri.pathSegments.firstOrNull ?? '');
        if (lotPk != null) {
          context.push('/print/$lotPk');
        } else {
          context.push('/settings/printer');
        }
    }
  }

  Widget _buildDrawer(BuildContext ctx) {
    // The native JWT is the single source of truth for "signed in": a sign-in
    // (here or via Google) bridges into the web session, so this one flag
    // drives both the account links and the sign-in/out controls. No more
    // drift, and no sign-out button while signed out.
    final signedIn = ref.watch(authProvider).valueOrNull != null;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Text(
                AppConstants.appName,
                style: Theme.of(
                  ctx,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // Browsing is open to everyone — always shown.
                  _navTile(ctx, Icons.gavel, 'Auctions', '/auctions/'),
                  _navTile(ctx, Icons.grid_view, 'Lots', '/lots/all/'),
                  _navTile(ctx, Icons.groups, 'Clubs', '/clubs/'),
                  // The full account menu, mirroring the website navbar.
                  if (signedIn) ...[
                    const Divider(),
                    _sectionHeader(ctx, 'My lots'),
                    _navTile(ctx, Icons.sell, 'Selling', '/selling/'),
                    _navTile(
                      ctx,
                      Icons.favorite_border,
                      'Watched lots',
                      '/lots/watched/',
                    ),
                    _navTile(ctx, Icons.monetization_on, 'Bids', '/bids/'),
                    _navTile(ctx, Icons.emoji_events, 'Won lots', '/lots/won/'),
                    const Divider(),
                    _sectionHeader(ctx, 'Account'),
                    _navTile(
                      ctx,
                      Icons.account_circle,
                      'Account information',
                      '/account/',
                    ),
                    _navTile(ctx, Icons.receipt_long, 'Invoices', '/invoices/'),
                    _navTile(
                      ctx,
                      Icons.chat_bubble_outline,
                      'Messages',
                      '/messages/',
                    ),
                    _navTile(
                      ctx,
                      Icons.contact_phone,
                      'Contact info',
                      '/contact_info/',
                    ),
                    _navTile(ctx, Icons.tune, 'Preferences', '/preferences/'),
                    _navTile(
                      ctx,
                      Icons.label_outline,
                      'Label printing',
                      '/printing/',
                    ),
                    _navTile(ctx, Icons.block, 'Ignore categories', '/ignore/'),
                    _navTile(
                      ctx,
                      Icons.feedback_outlined,
                      'Feedback',
                      '/feedback/',
                    ),
                  ],
                  const Divider(),
                  ExpansionTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('About'),
                    children: [
                      _navTile(ctx, null, 'FAQ', '/faq/', indent: true),
                      _navTile(
                        ctx,
                        null,
                        'Terms & Conditions',
                        '/tos/',
                        indent: true,
                      ),
                    ],
                  ),
                  // Native hardware setup — not a web page.
                  ListTile(
                    leading: const Icon(Icons.print),
                    title: const Text('Printer setup'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      context.push('/settings/printer');
                    },
                  ),
                  const Divider(),
                  if (signedIn)
                    ListTile(
                      leading: const Icon(Icons.logout),
                      title: const Text('Sign out'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        unawaited(_signOut());
                      },
                    )
                  else ...[
                    ListTile(
                      leading: const Icon(Icons.login),
                      title: const Text('Sign in'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        context.push('/login');
                      },
                    ),
                    _navTile(
                      ctx,
                      Icons.person_add,
                      'Create account',
                      '/accounts/signup/',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext ctx, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
        color: Theme.of(ctx).colorScheme.primary,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.8,
      ),
    ),
  );

  ListTile _navTile(
    BuildContext ctx,
    IconData? icon,
    String label,
    String path, {
    bool indent = false,
  }) => ListTile(
    contentPadding: indent
        ? const EdgeInsets.only(left: 56, right: 16)
        : const EdgeInsets.symmetric(horizontal: 16),
    leading: icon != null ? Icon(icon) : null,
    title: Text(label),
    onTap: () => _navigate(ctx, path),
  );

  @override
  Widget build(BuildContext context) {
    // When the native session signs in, bridge it into the WebView's Django
    // session (and reset bridging state on sign-out). See _onAuthChanged.
    ref.listen<AsyncValue<AppUser?>>(authProvider, _onAuthChanged);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: GestureDetector(
          onTap: _onTitleTap,
          child: const Text(AppConstants.appName),
        ),
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu),
              tooltip: 'Menu',
              onPressed: Scaffold.of(ctx).openEndDrawer,
            ),
          ),
        ],
      ),
      endDrawer: Builder(builder: _buildDrawer),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const LinearProgressIndicator(minHeight: 3),
        ],
      ),
    );
  }
}
