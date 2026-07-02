import 'dart:async';

import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/environment.dart';
import '../config/theme.dart';
import '../constants/app_constants.dart';
import '../models/auth_models.dart';
import '../models/club_menu_item.dart';
import '../providers/auth_provider.dart';
import '../providers/clubs_provider.dart';
import '../providers/config_provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/download_service.dart';
import '../services/location_service.dart';
import '../services/square_payment_service.dart';
import '../utils/android_platform.dart';
import '../widgets/payment_sheet.dart';
import 'command_palette_screen.dart';

class WebViewScreen extends ConsumerStatefulWidget {
  const WebViewScreen({super.key});

  @override
  ConsumerState<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends ConsumerState<WebViewScreen>
    with WidgetsBindingObserver {
  // User-Agent carrying the FishAuctionsApp token the backend's is_mobile_app
  // middleware keys on to drop web chrome (navbar/footer) and switch to the
  // native bridges. Reused verbatim for authenticated download refetches.
  static final String _userAgent =
      'FishAuctionsApp/1.0 (Flutter; ${defaultTargetPlatform.name})';

  static final InAppWebViewSettings _webViewSettings = InAppWebViewSettings(
    userAgent: _userAgent,
    // Route deep links + external navigations through shouldOverrideUrlLoading.
    useShouldOverrideUrlLoading: true,
    // Intercept file downloads (CSV/PDF/.ics/.pkpass) — the WebView can't fetch
    // them itself; see _onDownloadStart / DownloadService.
    useOnDownloadStart: true,
    // target="_blank" / window.open → onCreateWindow, which opens the system
    // browser instead of a nested WebView window.
    supportMultipleWindows: true,
    javaScriptCanOpenWindowsAutomatically: true,
    // The barcode check-in scanner (getUserMedia) plays inline without a tap.
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    // Let the dark ColoredBox backstop show through until the page paints, so
    // there's no white flash over the otherwise-dark UI.
    transparentBackground: true,
  );

  // Set once the InAppWebView is created (onWebViewCreated). Null before then;
  // callers that run after the first page load can assume it's present, but
  // guard anyway.
  InAppWebViewController? _controller;
  bool _loading = true;
  // Whether the WebView has back-history. Drives the leading back arrow's
  // visibility and is kept in sync after each page settles (see
  // _refreshCanGoBack). The system back button consults canGoBack() live, so it
  // doesn't depend on this.
  bool _canGoBack = false;
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

  // Invoice pk of the payment sheet currently being launched/shown, or null.
  // Guards against a double tap of the "Tap to Pay" button (or a repeated deep
  // link) opening overlapping sheets.
  int? _activePaymentPk;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Warm the deployment config and pre-initialize the Square SDK off the
    // startup critical path — never blocks first paint (the WebView loads
    // concurrently), so the eventual Tap to Pay is instant.
    unawaited(_warmSquare());
  }

  /// Loads `/api/mobile/config/` and initializes the Square SDK with the
  /// deployment's app id, if this deployment has Square. Best-effort: any
  /// failure is swallowed (init is idempotent and the payment flow re-fetches
  /// config and initializes lazily if this didn't run).
  Future<void> _warmSquare() async {
    try {
      final cfg = await ref.read(configProvider.future);
      if (cfg.hasSquare) {
        await AndroidPlatform.initializeSquare(cfg.squareApplicationId);
      }
    } on Object catch (e) {
      debugPrint('Square SDK warm-up skipped: $e');
    }
  }

  /// Called once the InAppWebView exists. Registers the JS bridges, seeds the
  /// location cookies from an instant cached fix (if already granted) so
  /// distances render on the first page without delaying it, then kicks off the
  /// first load. We never prompt for location at app open — that happens
  /// contextually on a location-aware screen (see _maybeOfferLocation).
  ///
  /// The system WebView persists its cookies, so a returning signed-in user is
  /// usually still logged in here without any work. We don't block first paint
  /// on auth: if the native JWT is present but the web cookie has lapsed,
  /// _reconcileWebSession (on load-stop) silently re-establishes it.
  Future<void> _onWebViewCreated(InAppWebViewController controller) async {
    _controller = controller;
    // Register the calendar bridge before the first load so the page's inline
    // script finds it (location_fragment_short.html calls callHandler).
    controller.addJavaScriptHandler(
      handlerName: 'addToCalendar',
      callback: _onAddToCalendar,
    );
    await _applyLocation(prompt: false, fresh: false);
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(EnvironmentConfig.webBaseUrl)),
    );
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
    final base = WebUri(EnvironmentConfig.webBaseUrl);
    // Non-HttpOnly, non-sensitive cookies the web UI also sets from JS; path '/'
    // and the site host match what document.cookie writes, so the server reads
    // them the same way whether they came from the browser or from here.
    final manager = CookieManager.instance();
    await manager.setCookie(
      url: base,
      name: 'latitude',
      value: LocationService.formatCoordinate(position.latitude),
      domain: base.host,
    );
    await manager.setCookie(
      url: base,
      name: 'longitude',
      value: LocationService.formatCoordinate(position.longitude),
      domain: base.host,
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
      await _controller?.reload();
    }
  }

  void _onLoadStart(InAppWebViewController controller, WebUri? url) {
    // A new page load supersedes any location banner the user hasn't acted on,
    // so it doesn't float over an unrelated screen.
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
      setState(() => _loading = true);
    }
  }

  Future<void> _onLoadStop(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (mounted) {
      setState(() => _loading = false);
    }
    unawaited(_refreshCanGoBack());
    if (url == null) {
      return;
    }
    // On the auctions/lots screens, offer location in context (once per
    // session). The home page and everything else never triggers this.
    unawaited(_maybeOfferLocation(url.path));
    await _reconcileWebSession(url);
  }

  /// Keeps [_canGoBack] in sync with the WebView's history so the leading back
  /// arrow shows only when there's somewhere to go back to. Called after each
  /// page settles — including after a goBack, which re-fires onLoadStop.
  Future<void> _refreshCanGoBack() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    final canGoBack = await controller.canGoBack();
    if (mounted && canGoBack != _canGoBack) {
      setState(() => _canGoBack = canGoBack);
    }
  }

  /// Back navigation shared by the Android system back button/gesture (via the
  /// PopScope in build) and the on-screen arrow: step back through WebView
  /// history if there's any, otherwise this is a real "leave the app" back at
  /// the site root, so exit the task rather than sitting on a dead root page.
  Future<void> _handleBack() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
    } else {
      await SystemNavigator.pop();
    }
  }

  /// Launches Tap to Pay for [invoicePk] when the cashier taps the checkout
  /// page's "Tap to Pay" button (the `fishauctions://pay/<pk>` deep link) — an
  /// explicit tap, since Square's charge takes over the screen with its own
  /// full-screen Activity (there's no in-place card read). Shows the sheet as a
  /// modal over the WebView so the cashier never leaves the page. Requires a
  /// native sign-in (the payment API is JWT-backed) and a Tap-to-Pay-capable
  /// device; otherwise it falls back to sign-in or leaves the web checkout in
  /// place. On a settled charge it reloads the page so it re-renders PAID.
  Future<void> _launchPayment(int invoicePk) async {
    if (_activePaymentPk != null) {
      return;
    }
    _activePaymentPk = invoicePk; // claim synchronously to block re-entrancy
    try {
      // Presence of tokens is enough to enter; the API client refreshes or
      // surfaces a 401 from there. No tokens → sign in first.
      if (!await ApiService.instance.hasTokens) {
        if (mounted) {
          unawaited(context.push('/login'));
        }
        return;
      }
      // Never let a capability-probe failure escape as an unhandled async
      // error (this runs from a nav-delegate callback / deep link); treat any
      // throw as "not capable" and tell the cashier.
      bool capable;
      try {
        capable = await SquarePaymentService.instance.isDeviceCapable();
      } on Object {
        capable = false;
      }
      if (!capable) {
        _showSnack(
          'This device can\'t take Tap to Pay — it needs NFC and Android 12 '
          'or newer.',
        );
        return;
      }
      if (!mounted) {
        return;
      }
      final result = await PaymentSheet.show(context, invoicePk);
      if (result == PaymentResult.paid && mounted) {
        // Refresh so the checkout page re-renders PAID (HTMX-style).
        await _controller?.reload();
      }
    } finally {
      _activePaymentPk = null;
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
      await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  /// Path (+query) of the page currently in the WebView, for the post-handoff
  /// landing page. Auth pages resolve to their ?next= target, not themselves.
  Future<String?> _currentWebPath() async {
    final current = await _controller?.getUrl();
    if (current == null) {
      return null;
    }
    if (current.path.startsWith('/accounts/')) {
      return current.queryParameters['next'];
    }
    return _pathOf(current);
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
    await _controller?.evaluateJavascript(source: _logoutFormJs);
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
    _controller?.loadUrl(
      urlRequest: URLRequest(
        url: WebUri('${EnvironmentConfig.webBaseUrl}$path'),
      ),
    );
  }

  void _navigate(BuildContext drawerContext, String path) {
    Navigator.of(drawerContext).pop();
    _loadPath(path);
  }

  /// Brand for the app-bar title and drawer header. Server-driven via
  /// `GET /api/mobile/config/` (`brand_name`); until that resolves — and for
  /// forks whose config omits it — falls back to the compile-time
  /// [AppConstants.appName]. Watched, so the title updates once config loads.
  String get _brandName {
    final b = ref.watch(configProvider).valueOrNull?.brandName;
    return (b == null || b.isEmpty) ? AppConstants.appName : b;
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

  // ── Navigation, downloads, permissions, bridges ───────────────────────────

  /// Gatekeeps every main-frame navigation. Custom-scheme deep links run the
  /// native flow; links to other sites open in the system browser; everything
  /// on our host loads in place.
  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) {
      return NavigationActionPolicy.ALLOW;
    }

    // fishauctions://pay|print/… — handle natively, don't navigate.
    if (uri.scheme == EnvironmentConfig.urlScheme) {
      _handleDeepLink(uri);
      return NavigationActionPolicy.CANCEL;
    }

    // Only http(s) navigates. Block javascript:, intent:, file:, and other
    // schemes injected or remote content could abuse.
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return NavigationActionPolicy.CANCEL;
    }

    final webHost = Uri.parse(EnvironmentConfig.webBaseUrl).host;

    // Off-site links open in the system browser, not inside the shell: "Get
    // directions" map links, the Google Wallet save URL, and arbitrary URLs in
    // user-authored lot descriptions / reference links (which won't carry
    // target="_blank"). Scope to top-level navigations so embedded third-party
    // iframes still load in place. Nothing we need inline lives off our host —
    // social login is hidden for the app UA, so no OAuth redirect to preserve.
    if (uri.host != webHost && action.isForMainFrame) {
      await _openExternally(uri);
      return NavigationActionPolicy.CANCEL;
    }

    // A logout on our host — the in-page web sign-out — must also drop the
    // native JWT so the two sessions stay in lockstep. Skip if already signed
    // out so our own menu logout doesn't double-fire. Fire-and-forget: the
    // navigation continues while the JWT is cleared.
    if (uri.path == '/accounts/logout/' &&
        ref.read(authProvider).valueOrNull != null) {
      unawaited(ref.read(authProvider.notifier).logout());
    }

    return NavigationActionPolicy.ALLOW;
  }

  /// `target="_blank"` / `window.open` — always route to the system browser
  /// rather than open a nested WebView window. Covers the seller-connect
  /// banners (which link to our own host with target="_blank" precisely to
  /// escape the WebView for the Square/PayPal OAuth the app can't run) and the
  /// Google Wallet save URL. Returning false tells the engine not to create the
  /// window.
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
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        _showSnack('Couldn\'t open the link.');
      }
    } on Object {
      _showSnack('Couldn\'t open the link.');
    }
  }

  /// The WebView can't download files itself, and these Django endpoints are
  /// session-authenticated — DownloadService refetches with the WebView's
  /// cookies and hands the file to the OS (calendar/Wallet importer or the
  /// share sheet). See its doc comment for the MIME routing.
  Future<DownloadStartResponse?> _onDownloadStart(
    InAppWebViewController controller,
    DownloadStartRequest request,
  ) async {
    final error = await DownloadService.instance.handle(
      request,
      userAgent: _userAgent,
    );
    if (error != null) {
      _showSnack(error);
    }
    // We fetched and dispatched the file ourselves — tell the engine it's
    // handled so it doesn't attempt its own (cookie-less) download.
    return DownloadStartResponse(handled: true);
  }

  /// The web check-in screen scans barcodes through the browser camera
  /// (`getUserMedia`). Bridge the WebView's permission request to a native
  /// runtime prompt: grant the lone-camera request iff Android's CAMERA
  /// permission is granted, and deny anything else (e.g. the microphone, which
  /// the app declares no permission for) so the page fails fast rather than
  /// hanging on a request that could never succeed.
  Future<PermissionResponse?> _onPermissionRequest(
    InAppWebViewController controller,
    PermissionRequest request,
  ) async {
    final wantsOnlyCamera =
        request.resources.length == 1 &&
        request.resources.contains(PermissionResourceType.CAMERA);
    if (!wantsOnlyCamera) {
      // DENY is PermissionResponse's default action.
      return PermissionResponse(resources: request.resources);
    }
    final status = await Permission.camera.request();
    return PermissionResponse(
      resources: request.resources,
      action: status.isGranted
          ? PermissionResponseAction.GRANT
          : PermissionResponseAction.DENY,
    );
  }

  /// Native "add to device calendar" bridge. The web
  /// (`location_fragment_short.html`) fetches the pickup event as JSON and
  /// calls `callHandler("addToCalendar", {title, details, start, end,
  /// location})`; we hand it to the OS calendar. If this handler isn't present
  /// the web falls back to the `.ics` download, which DownloadService opens.
  Future<void> _onAddToCalendar(List<dynamic> args) async {
    if (args.isEmpty || args.first is! Map) {
      return;
    }
    final data = args.first as Map;
    final start = DateTime.tryParse('${data['start']}');
    final end = DateTime.tryParse('${data['end']}');
    if (start == null || end == null) {
      return;
    }
    await Add2Calendar.addEvent2Cal(
      Event(
        title: '${data['title'] ?? ''}',
        description: '${data['details'] ?? ''}',
        location: '${data['location'] ?? ''}',
        startDate: start,
        endDate: end,
      ),
    );
  }

  void _handleDeepLink(Uri uri) {
    switch (uri.host) {
      case 'pay':
        // The page's "Tap to Pay with card" button — the sole trigger for the
        // native charge. We don't auto-start on page load: a Square charge
        // takes over the whole screen (its own full-screen Activity), so the
        // cashier opts in with an explicit tap rather than being dropped into
        // it the moment the invoice renders.
        final invoicePk = int.tryParse(uri.pathSegments.firstOrNull ?? '');
        if (invoicePk != null) {
          unawaited(_launchPayment(invoicePk));
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

  Widget _buildDrawer(BuildContext ctx, String brand) {
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
                brand,
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
                  _clubsTile(ctx),
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

  /// The drawer's "Clubs" entry. Signed in with memberships → an expandable
  /// menu ("Find a club" + each club, admin ones badged), rebuilding the web
  /// navbar's Clubs dropdown. Otherwise (signed out, no clubs, still loading,
  /// or the fetch failed) → the plain browse link, matching the web navbar's
  /// bare "Clubs" link for users with no clubs.
  Widget _clubsTile(BuildContext ctx) {
    final clubs =
        ref.watch(myClubsProvider).valueOrNull ?? const <ClubMenuItem>[];
    if (clubs.isEmpty) {
      return _navTile(ctx, Icons.groups, 'Clubs', '/clubs/');
    }
    return ExpansionTile(
      leading: const Icon(Icons.groups),
      title: const Text('Clubs'),
      childrenPadding: EdgeInsets.zero,
      children: [
        _navTile(ctx, null, 'Find a club', '/clubs/', indent: true),
        for (final club in clubs)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 56, right: 16),
            title: Text(club.name),
            subtitle: club.isAdmin ? const Text('Admin') : null,
            onTap: () => _navigate(ctx, club.url),
          ),
      ],
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
    final brand = _brandName;
    // Back navigation lives on the system back button/gesture (below) for
    // Android; canPop stays false so we route it through WebView history first
    // and only leave the app when there's none left.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_handleBack());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          // On-screen back arrow, shown only when there's WebView history to
          // pop. Covers iOS (no hardware back) and discoverability; the brand
          // stays as the title. Falls back to null so the brand sits at the
          // leading edge on the home page, as before.
          leading: _canGoBack
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: () => unawaited(_handleBack()),
                )
              : null,
          title: GestureDetector(onTap: _onTitleTap, child: Text(brand)),
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
        endDrawer: Builder(builder: (ctx) => _buildDrawer(ctx, brand)),
        body: Stack(
          children: [
            // Dark backstop so the pre-paint window doesn't flash white over
            // the otherwise-dark UI (the WebView is transparent until paint).
            const ColoredBox(
              color: AppTheme.scaffoldBackground,
              child: SizedBox.expand(),
            ),
            InAppWebView(
              initialSettings: _webViewSettings,
              onWebViewCreated: (c) => unawaited(_onWebViewCreated(c)),
              onLoadStart: _onLoadStart,
              onLoadStop: (c, url) => unawaited(_onLoadStop(c, url)),
              shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
              onCreateWindow: _onCreateWindow,
              onDownloadStarting: _onDownloadStart,
              onPermissionRequest: _onPermissionRequest,
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 3),
          ],
        ),
      ),
    );
  }
}
