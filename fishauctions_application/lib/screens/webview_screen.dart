import 'dart:async';
import 'dart:io' show Platform;

import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:dio/dio.dart';
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
import '../models/club_menu_item.dart';
import '../models/label_prefs.dart';
import '../providers/auth_provider.dart';
import '../providers/clubs_provider.dart';
import '../providers/config_provider.dart';
import '../providers/printer_provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/bluetooth_service.dart';
import '../services/download_service.dart';
import '../services/label_prefs_service.dart';
import '../services/location_service.dart';
import '../services/shortcut_service.dart';
import '../services/square_payment_service.dart';
import '../utils/platform_bridge.dart';
import '../widgets/payment_sheet.dart';
import '../widgets/printer_connect_sheet.dart';
import 'command_palette_screen.dart';

class WebViewScreen extends ConsumerStatefulWidget {
  const WebViewScreen({super.key});

  @override
  ConsumerState<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends ConsumerState<WebViewScreen>
    with WidgetsBindingObserver {
  static final InAppWebViewSettings _webViewSettings = InAppWebViewSettings(
    userAgent: AppConstants.userAgent,
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
  // The router only mounts this screen for a signed-in native session, and a
  // fresh sign-in always mounts a fresh instance — so bridging that session
  // into the WebView's Django cookie session happens in exactly two places:
  // the first load boots through the backend handoff when the WebView has no
  // session cookie yet (see _initialUrl), and _reconcileWebSession repairs a
  // lapsed session when the server bounces a page to /login/. The
  // repair is bounded to one attempt per screen lifetime so a failed/looping
  // handoff can't spin.
  int _handoffAttempts = 0;

  // Invoice pk of the payment sheet currently being launched/shown, or null.
  // Guards against a double tap of the "Tap to Pay" button (or a repeated deep
  // link) opening overlapping sheets.
  int? _activePaymentPk;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Home-screen shortcut tapped while the shell is already up → navigate
    // in place. (Cold starts are handled by _initialUrl consuming the pending
    // path instead — see _onShortcutTapped.)
    ShortcutService.instance.pending.addListener(_onShortcutTapped);
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
        await PlatformBridge.initializeSquare(cfg.squareApplicationId);
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
  Future<void> _onWebViewCreated(InAppWebViewController controller) async {
    _controller = controller;
    // Register the JS bridges before the first load so page scripts find
    // them. addToCalendar: the calendar bridge (location_fragment_short.html).
    // printerGetState/Connect/Unpair: the /printing/ page's Bluetooth card
    // (BACKEND_SPEC.md §1.2) — the page JS lives in the Django template so the
    // card's UX iterates server-side; the app only exposes state + the native
    // connect/unpair flows. Each printer handler resolves with the current
    // state object.
    controller
      ..addJavaScriptHandler(
        handlerName: 'addToCalendar',
        callback: _onAddToCalendar,
      )
      ..addJavaScriptHandler(
        handlerName: 'printerGetState',
        callback: (_) => _printerState(),
      )
      ..addJavaScriptHandler(
        handlerName: 'printerConnect',
        callback: (_) async {
          if (mounted) {
            // Bottom sheet over the page — the user never leaves /printing/.
            await PrinterConnectSheet.show(context);
          }
          return _printerState();
        },
      )
      ..addJavaScriptHandler(
        handlerName: 'printerUnpair',
        callback: (_) async {
          await ref.read(printerProvider.notifier).forget();
          return _printerState();
        },
      );
    await _applyLocation(prompt: false, fresh: false);
    final initialUrl = await _initialUrl();
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(initialUrl)));
  }

  /// The first URL to load. The user is always natively signed in when this
  /// screen mounts (the router requires an account), but the WebView's Django
  /// session cookie may not exist yet — right after a fresh sign-in, or after
  /// sign-out cleared the cookies. In that case boot through the backend
  /// session handoff so the very first page renders signed in. When the
  /// persisted cookie is present we load the site directly — no extra round
  /// trip — and _reconcileWebSession repairs it if the server says it lapsed.
  ///
  /// A pending home-screen shortcut (cold start from a quick action, or a tap
  /// that trapped through the login screen first) becomes the landing page —
  /// threaded through the handoff's ?next= when one runs.
  Future<String> _initialUrl() async {
    final shortcutPath = ShortcutService.instance.consume();
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(EnvironmentConfig.webBaseUrl),
      );
      final hasWebSession = cookies.any((c) => c.name == 'sessionid');
      if (!hasWebSession) {
        final handoff = await AuthService.instance.createWebSessionHandoffUrl(
          next: shortcutPath,
        );
        if (handoff != null) {
          return handoff;
        }
      }
    } on Object catch (e) {
      debugPrint('Web session bootstrap skipped: $e');
    }
    return shortcutPath == null
        ? EnvironmentConfig.webBaseUrl
        : '${EnvironmentConfig.webBaseUrl}$shortcutPath';
  }

  @override
  void dispose() {
    ShortcutService.instance.pending.removeListener(_onShortcutTapped);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A quick action fired while this screen exists. Before the WebView is
  /// created the path is deliberately left pending — _initialUrl (about to
  /// run) consumes it as the landing page; taking it here too would double-
  /// navigate or lose it.
  void _onShortcutTapped() {
    if (_controller == null || ShortcutService.instance.pending.value == null) {
      return;
    }
    final path = ShortcutService.instance.consume();
    if (path != null) {
      _loadPath(path);
    }
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
  /// Tap-to-Pay-capable device; otherwise it leaves the web checkout in place.
  /// On a settled charge it reloads the page so it re-renders PAID.
  Future<void> _launchPayment(int invoicePk) async {
    if (_activePaymentPk != null) {
      return;
    }
    _activePaymentPk = invoicePk; // claim synchronously to block re-entrancy
    try {
      // The router only mounts this screen signed in, so tokens are normally
      // present; they vanish only when the session just died, in which case
      // the router is about to trap to the login screen — don't start a
      // charge on top of that.
      if (!await ApiService.instance.hasTokens) {
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
          Platform.isIOS
              ? 'This device can\'t take Tap to Pay — it needs an iPhone XS '
                    'or newer on iOS 16.4+.'
              : 'This device can\'t take Tap to Pay — it needs NFC and '
                    'Android 12 or newer.',
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

  /// The state object the printer JS handlers resolve with — what the
  /// `/printing/` page's Bluetooth card renders. `labelSize` is the size the
  /// printer itself reported (profiles that can read it); the page offers to
  /// adopt it into the user's label prefs.
  Map<String, dynamic> _printerState() {
    final printer = ref.read(printerProvider).valueOrNull;
    final hasSize =
        printer?.labelWidthMm != null && printer?.labelHeightMm != null;
    return {
      'supported': true,
      'connected':
          printer != null &&
          BluetoothService.instance.isConnectedTo(printer.address),
      'name': printer?.name,
      'address': printer?.address,
      'profile': printer?.profileSlug,
      'labelSize': hasSize
          ? {
              'width_mm': printer!.labelWidthMm,
              'height_mm': printer.labelHeightMm,
            }
          : null,
    };
  }

  // ── WebView ↔ native session bridging ─────────────────────────────────────

  /// Repairs session drift on each page load. The web navbar is hidden in-app
  /// (the server detects the app from its User-Agent), so the reliable signal
  /// that the WebView's session has lapsed is the server bouncing an
  /// auth-required page to /login/ (LOGIN_URL — allauth is mounted at the site
  /// root, not /accounts/): run the handoff to re-establish the web session and
  /// resume the intended ?next= destination. The web login form is never shown
  /// in the app — the native login screen is the one front door for both
  /// sessions (a web-form login would create a cookie session with no JWT).
  Future<void> _reconcileWebSession(Uri uri) async {
    final webHost = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    if (uri.path != '/login/' || uri.host != webHost) {
      return;
    }
    if (ref.read(authProvider).valueOrNull != null) {
      await _ensureWebSession(next: uri.queryParameters['next']);
    }
    // Natively signed out only during the brief window before the router
    // traps back to the login screen — nothing to do here.
  }

  /// Logs the WebView into the Django session matching the native JWT, via the
  /// backend handoff. Bounded to one attempt per screen lifetime so a failed
  /// handoff can't loop.
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
  /// landing page. The login bounce page resolves to its ?next= target, not
  /// itself (root-mounted allauth: /login/, not /accounts/login/).
  Future<String?> _currentWebPath() async {
    final current = await _controller?.getUrl();
    if (current == null) {
      return null;
    }
    if (current.path == '/login/') {
      return current.queryParameters['next'];
    }
    return _pathOf(current);
  }

  String? _pathOf(Uri uri) {
    final pathQuery = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    return pathQuery.isEmpty ? null : pathQuery;
  }

  /// Sign out everywhere. Order matters: the web logout POST runs first (it
  /// needs the WebView's cookies), then the cookies are dropped so the WebView
  /// is signed out no matter what, and the native session goes last — flipping
  /// authProvider makes the router swap this screen for the login trap, so
  /// nothing here can run after it.
  ///
  /// Deleting all cookies (not just sessionid) is deliberate: sign-out is the
  /// device-changes-hands moment, and it guarantees the account screens'
  /// WebView can't carry a stale session into the next user's signup. The
  /// location cookies are re-seeded on the next mount.
  Future<void> _signOut() async {
    await _postWebLogout();
    await CookieManager.instance().deleteAllCookies();
    await ref.read(authProvider.notifier).logout();
  }

  /// POSTs the allauth logout (POST + CSRF required) directly with the
  /// WebView's cookies, so the server-side session is invalidated even though
  /// the WebView itself is about to be torn down (an in-page form submit would
  /// race the unmount). Best-effort: the cookie wipe that follows signs the
  /// WebView out regardless.
  Future<void> _postWebLogout() async {
    try {
      final base = WebUri(EnvironmentConfig.webBaseUrl);
      final cookies = await CookieManager.instance().getCookies(url: base);
      final csrf = cookies
          .where((c) => c.name == 'csrftoken')
          .map((c) => '${c.value}')
          .firstOrNull;
      if (csrf == null || !cookies.any((c) => c.name == 'sessionid')) {
        return; // no web session to log out
      }
      final cookieHeader = cookies
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      await Dio().post<void>(
        '${EnvironmentConfig.webBaseUrl}/logout/',
        data: 'csrfmiddlewaretoken=${Uri.encodeQueryComponent(csrf)}',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'Cookie': cookieHeader,
            // Django's CSRF check on HTTPS requires a same-origin Referer.
            'Referer': '${EnvironmentConfig.webBaseUrl}/',
            'User-Agent': AppConstants.userAgent,
          },
          followRedirects: false,
          validateStatus: (_) => true,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
    } on Object catch (e) {
      debugPrint('Web logout POST failed (cookies wiped anyway): $e');
    }
  }

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

  void _onTitleTap() => showCommandPalette(context, _loadPath);

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

    // A logout link on our host — an in-page web sign-out — means sign out
    // everywhere: the two sessions stay in lockstep, so run the full native
    // sign-out (which also POSTs the web logout and wipes cookies) instead of
    // letting the page navigate. Skip if already signed out so our own menu
    // logout doesn't double-fire.
    if (uri.path == '/logout/' && ref.read(authProvider).valueOrNull != null) {
      unawaited(_signOut());
      return NavigationActionPolicy.CANCEL;
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
  ///
  /// PDFs additionally honor the user's print method (the `/printing/`
  /// dropdown): "System printer" routes them into the OS print dialog instead
  /// of the share sheet, so the site's existing print buttons — including the
  /// bulk label sheets — print without any web changes. Bluetooth doesn't
  /// come through here (per-lot buttons deep-link `fishauctions://print/…`);
  /// a PDF downloaded while on the Bluetooth method (e.g. a bulk sheet) falls
  /// back to the normal share flow.
  Future<DownloadStartResponse?> _onDownloadStart(
    InAppWebViewController controller,
    DownloadStartRequest request,
  ) async {
    final prefs = await LabelPrefsService.instance.fetch();
    final error = await DownloadService.instance.handle(
      request,
      userAgent: AppConstants.userAgent,
      printPdfWithSystemDialog: prefs?.printMethod == PrintMethod.system,
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
        // (e.g. a bare "set up printing" link) fall back to the /printing/
        // page, the one place printing is configured.
        final lotPk = int.tryParse(uri.pathSegments.firstOrNull ?? '');
        if (lotPk != null) {
          context.push('/print/$lotPk');
        } else {
          _loadPath('/printing/');
        }
    }
  }

  // The router only mounts this screen for a signed-in session, so the drawer
  // always shows the full account menu — there is no signed-out variant
  // (signed-out users live on the login/signup screens).
  Widget _buildDrawer(BuildContext ctx, String brand) => Drawer(
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
                _navTile(ctx, Icons.gavel, 'Auctions', '/auctions/'),
                _navTile(ctx, Icons.grid_view, 'Lots', '/lots/all/'),
                _clubsTile(ctx),
                // The full account menu, mirroring the website navbar.
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
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Sign out'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(_signOut());
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

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
