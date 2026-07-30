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
import '../models/checkin_models.dart';
import '../models/club_menu_item.dart';
import '../models/label_prefs.dart';
import '../providers/auth_provider.dart';
import '../providers/clubs_provider.dart';
import '../providers/config_provider.dart';
import '../providers/printer_provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/bluetooth_service.dart';
import '../services/checkin_service.dart';
import '../services/download_service.dart';
import '../services/label_prefs_service.dart';
import '../services/label_print_service.dart';
import '../services/last_page_service.dart';
import '../services/location_service.dart';
import '../services/notification_prefs_service.dart';
import '../services/offline_store.dart';
import '../services/offline_sync_service.dart';
import '../services/printer_setup_prompt.dart';
import '../services/push_prompt_service.dart';
import '../services/push_service.dart';
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
  // Set only when a banner is actually shown, so an offer that a redirect stole
  // before the user could read it still gets another chance on the next page.
  bool _locationOffered = false;

  // Bumped on every main-frame load start. Contextual banners (location, push)
  // are decided after a page settles, which involves awaits — and a page that
  // immediately redirects would otherwise get a banner posted onto the *next*
  // page, or shown for the few frames before _onLoadStart hides it again. Every
  // offer captures this value and bails if it has moved on. This is the fix for
  // "the location prompt appears briefly and then hides itself".
  int _navGeneration = 0;

  // The navigation a contextual banner has already claimed. Two of them (say a
  // location offer and a notification offer on the same in-person lot page)
  // would otherwise queue up in the messenger and greet the user one after the
  // other.
  int? _bannerGeneration;

  /// How long a page must stay put before a contextual banner is allowed to
  /// appear over it. Long enough to cover a server redirect or a JS
  /// `location.replace`, short enough that the offer still feels like part of
  /// arriving on the page.
  static const Duration _bannerSettleDelay = Duration(milliseconds: 900);

  /// Cap on how long an offer waits for a still-loading page to finish. Past
  /// this the page is slow or broken and the offer is dropped — it can be made
  /// again on the next navigation.
  static const Duration _bannerSettleTimeout = Duration(seconds: 5);

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

  // When a lot page was opened *from* AR mode (the card's "open lot page"),
  // this remembers the AR origin so the next back press returns to AR and
  // re-beacons the lot — the same intent as the page's "Back to AR" bar. It's
  // consumed on that first back (so a second back does normal web history and
  // there's no AR⇄lot loop) and dropped once the user navigates elsewhere.
  ({String slug, int lotPk})? _arReturn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Home-screen shortcut tapped while the shell is already up → navigate
    // in place. (Cold starts are handled by _initialUrl consuming the pending
    // path instead — see _onShortcutTapped.)
    ShortcutService.instance.pending.addListener(_onShortcutTapped);
    // Notification tap → navigate the WebView there; foreground message →
    // in-app banner. (A cold start from a tap is picked up in
    // _onWebViewCreated once the controller exists.)
    PushService.instance.pendingRoute.addListener(_onPushRoute);
    PushService.instance.foregroundMessage.addListener(_onForegroundPush);
    // Warm the deployment config and pre-initialize the Square SDK off the
    // startup critical path — never blocks first paint (the WebView loads
    // concurrently), so the eventual Tap to Pay is instant.
    unawaited(_warmSquare());
    // Bring up push (FCM) once config is known — inert unless this deployment
    // configured push for this exact build. Off the critical path too.
    unawaited(_warmPush());
    // Keep an offline copy of the operator's last admin auction warm
    // (periodic snapshot pulls), and drain any changes queued while offline.
    // Conflicts the server reports surface as a snackbar.
    OfflineSyncService.instance.newConflicts.addListener(_onOfflineConflicts);
    OfflineSyncService.instance.start();
    // Proximity check-in: report position (only if permission already
    // exists — never prompts) and surface whatever welcome/join/check-in
    // nudges the server decides apply.
    CheckinService.instance.newActions.addListener(_onCheckinActions);
    CheckinService.instance.start();
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

  /// Bring up push (FCM) from the deployment config, then — if a token resulted
  /// — re-register the device so the backend gets the token (the login-time
  /// registration ran before push was ready). Also re-registers on future token
  /// refreshes. Best-effort: push stays inert on failure or when this
  /// deployment/build has no push config.
  ///
  /// This deliberately does **not** ask for the notification permission; that
  /// happens contextually (see _maybeOfferPush). A token only exists here if
  /// the user has already allowed notifications on a previous run.
  Future<void> _warmPush() async {
    try {
      final cfg = await ref.read(configProvider.future);
      PushService.instance.onTokenChanged =
          AuthService.instance.registerThisDevice;
      await PushService.instance.init(cfg);
      if (PushService.instance.token != null) {
        unawaited(AuthService.instance.registerThisDevice());
      }
    } on Object catch (e) {
      debugPrint('Push warm-up skipped: $e');
    }
  }

  /// If the deployment config never loaded (a cold start with no connectivity,
  /// which at an auction hall is routine), everything keyed off it stays broken
  /// for the whole process: Tap to Pay can't initialize, push stays inert, and
  /// the notification offer would tell the user notifications "aren't available
  /// on this device". Riverpod caches the failure, so re-ask on resume — by
  /// which point the user has usually fixed the network themselves.
  Future<void> _rewarmConfigIfFailed() async {
    if (!ref.read(configProvider).hasError) {
      return;
    }
    ref.invalidate(configProvider);
    await _warmSquare();
    await _warmPush();
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
        callback: (_) => _printerStateReconnecting(),
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
      )
      // Notification opt-in, for the pages that know when it's worth asking —
      // notably a lot page in an in-person auction, which the app can't
      // recognize from a URL (BACKEND_SPEC.md Part N).
      //   pushGetState()      → {supported, permitted, prefs_endpoint}
      //   pushPromptOffer(r)  → soft banner, at most once per device; {offered}
      //   pushEnable()        → the full opt-in now, for an explicit button tap
      ..addJavaScriptHandler(
        handlerName: 'pushGetState',
        callback: (_) => _pushState(),
      )
      ..addJavaScriptHandler(
        handlerName: 'pushPromptOffer',
        callback: (args) async {
          final surface = _pushSurfaceFrom(args.firstOrNull);
          final before = _bannerGeneration;
          await _maybeOfferPush(surface, _navGeneration);
          return {'offered': _bannerGeneration != before};
        },
      )
      ..addJavaScriptHandler(
        handlerName: 'pushEnable',
        callback: (args) async {
          await _enablePushFromWeb(_pushSurfaceFrom(args.firstOrNull));
          return _pushState();
        },
      );
    await _applyLocation(prompt: false, fresh: false);
    final initialUrl = await _initialUrl();
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(initialUrl)));
    // A notification that cold-started the app (tapped while terminated) left a
    // pending route during push init; now that the controller exists, honor it.
    _onPushRoute();
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
  /// threaded through the handoff's ?next= when one runs. Failing that, the
  /// page this account was last on comes back (see [LastPageService]): the
  /// app is routinely killed while backgrounded, and returning to the site
  /// root every time loses the user's place mid-auction.
  Future<String> _initialUrl() async {
    final shortcutPath =
        ShortcutService.instance.consume() ?? await _lastPagePath();
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

  /// Where this account was last browsing, if it was recent. Null while the
  /// profile is still restoring — the saved page is user-scoped, so without a
  /// user there is nothing safe to restore.
  Future<String?> _lastPagePath() async {
    final userId = ref.read(authProvider).value?.id;
    return userId == null
        ? null
        : LastPageService.instance.restore(userId: userId);
  }

  /// Remember the page in front of the user, for the next cold start.
  void _rememberPage(Uri url) {
    final userId = ref.read(authProvider).value?.id;
    final path = _pathOf(url);
    if (userId == null || path == null) {
      return;
    }
    unawaited(LastPageService.instance.remember(path, userId: userId));
  }

  @override
  void dispose() {
    ShortcutService.instance.pending.removeListener(_onShortcutTapped);
    PushService.instance.pendingRoute.removeListener(_onPushRoute);
    PushService.instance.foregroundMessage.removeListener(_onForegroundPush);
    OfflineSyncService.instance.newConflicts.removeListener(
      _onOfflineConflicts,
    );
    CheckinService.instance.newActions.removeListener(_onCheckinActions);
    CheckinService.instance.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A sync push came back with rejected ops (lot sold to someone else on the
  /// server, a conflicting user, a closed invoice…). Surface it immediately —
  /// the whole point of conflict handling is that nothing goes out of sync
  /// silently. Details live on the offline screen.
  void _onOfflineConflicts() {
    final conflicts = OfflineSyncService.instance.consumeNewConflicts();
    if (conflicts.isEmpty || !mounted) {
      return;
    }
    final n = conflicts.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          '$n offline change${n == 1 ? '' : 's'} couldn\'t sync — the '
          'server\'s copy was kept',
        ),
        action: SnackBarAction(
          label: 'View',
          onPressed: () => context.push('/offline'),
        ),
      ),
    );
  }

  /// The check-in ping came back with nudges. Surface them one at a time —
  /// realistically there is one (the auction the user just walked into), but
  /// an admin who also hasn't joined could get two.
  void _onCheckinActions() {
    final actions = CheckinService.instance.consumeNewActions();
    if (actions.isEmpty || !mounted) {
      return;
    }
    unawaited(_handleCheckinActions(actions));
  }

  Future<void> _handleCheckinActions(List<CheckinAction> actions) async {
    for (final action in actions) {
      if (!mounted) {
        return;
      }
      switch (action.type) {
        case CheckinActionType.checkedIn:
          // The server already checked the user in — just confirm it.
          _showSnack(action.message);
        case CheckinActionType.joinOffer:
          await _showJoinOffer(action);
        case CheckinActionType.setLocationOffer:
          await _showSetLocationOffer(action);
      }
    }
  }

  /// `Welcome to the <auction>` bottom sheet: Join (joins server-side — no
  /// scroll-through-the-rules — then lands on the rules page) or Read rules
  /// (just opens the rules page; joining stays available there).
  Future<void> _showJoinOffer(CheckinAction action) async {
    final rulesPath = action.rulesUrl ?? '/auctions/${action.auctionSlug}/';
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                action.message.isNotEmpty
                    ? action.message
                    : 'Welcome to ${action.title}.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'join'),
                child: const Text('Join'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.pop(context, 'rules'),
                child: const Text('Read rules'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    switch (choice) {
      case 'join':
        final result = await CheckinService.instance.join(action.auctionSlug);
        if (!mounted) {
          return;
        }
        if (result == null || !result.joined) {
          _showSnack(
            'Couldn\'t join ${action.title} — try again from the '
            'auction page.',
          );
          _loadPath(rulesPath);
          return;
        }
        _showSnack(
          result.checkedIn
              ? 'You\'ve joined ${action.title} and you\'re checked in!'
              : 'You\'ve joined ${action.title}!',
        );
        _loadPath(result.rulesUrl ?? rulesPath);
      case 'rules':
        _loadPath(rulesPath);
    }
  }

  /// Admin nudge: the auction has no exact location pinned and this phone is
  /// at (or near) the venue — offer to use its position as the auction's
  /// location.
  Future<void> _showSetLocationOffer(CheckinAction action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Set location for ${action.title}?'),
        content: Text(
          action.message.isNotEmpty
              ? action.message
              : 'Use this phone\'s current position as the auction\'s '
                    'location so attendees get accurate directions and '
                    'welcome check-in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Set location'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final ok = await CheckinService.instance.setAuctionLocation(
      action.auctionSlug,
    );
    if (mounted) {
      _showSnack(
        ok
            ? 'Location set for ${action.title}.'
            : 'Couldn\'t set the location — check that location is still '
                  'available and try again.',
      );
    }
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

  /// A notification tapped while the shell is up (or backgrounded) → navigate
  /// the WebView. A tap that cold-starts the app from the terminated state is
  /// handled in _onWebViewCreated once the controller exists.
  void _onPushRoute() {
    if (_controller == null ||
        PushService.instance.pendingRoute.value == null) {
      return;
    }
    final route = PushService.instance.consumeRoute();
    if (route != null) {
      _openPushUrl(route);
    }
  }

  /// A message arrived while foregrounded (FCM displays nothing then) → a brief
  /// in-app banner with a "View" action that opens its target.
  void _onForegroundPush() {
    final message = PushService.instance.foregroundMessage.value;
    PushService.instance.foregroundMessage.value = null;
    if (message == null || !mounted) {
      return;
    }
    final text = message.title.isNotEmpty ? message.title : message.body;
    if (text.isEmpty) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        action: message.url.isEmpty
            ? null
            : SnackBarAction(
                label: 'View',
                onPressed: () => _openPushUrl(message.url),
              ),
      ),
    );
  }

  /// Opens a push target in the WebView: an absolute URL is loaded as-is, a
  /// site-relative path is resolved against the deployment base.
  void _openPushUrl(String target) {
    final url = target.startsWith('http')
        ? target
        : '${EnvironmentConfig.webBaseUrl}$target';
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh the location cookies silently when the app returns to the
    // foreground — the user may have moved. The server reads them per request,
    // so the next navigation/XHR picks up the newest position; no reload (that
    // would be jarring mid-browse). Never prompts here.
    if (state == AppLifecycleState.resumed) {
      _applyLocation(prompt: false);
      // The offline snapshot may be minutes stale — refresh it (and drain any
      // queued changes) now that we're likely back on a network.
      OfflineSyncService.instance.onAppResumed();
      // The user may have just walked into the auction hall.
      CheckinService.instance.onAppResumed();
      unawaited(_rewarmConfigIfFailed());
    }
    // Going into the background is the moment before the process may be
    // reclaimed — take a last reading of where the user is, in case the page
    // moved without a full load (in-page history) since onLoadStop.
    if (state == AppLifecycleState.paused) {
      unawaited(_rememberCurrentPage());
    }
  }

  Future<void> _rememberCurrentPage() async {
    final url = await _controller?.getUrl();
    final webHost = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    if (url != null && url.host == webHost) {
      _rememberPage(url);
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

  /// Whether a banner queued during navigation [generation] may still be shown:
  /// the page has to have stayed put for [_bannerSettleDelay] and no other
  /// contextual banner may have claimed the same navigation.
  ///
  /// Without this a page that settles and then redirects (a login bounce, a
  /// slug canonicalization, a `location.replace`) shows a banner for a few
  /// frames before `_onLoadStart` hides it — a prompt that flashes and
  /// disappears, which is worse than no prompt: the user sees that they were
  /// asked something and has no way to answer it.
  Future<bool> _claimBanner(int generation) async {
    await Future<void>.delayed(_bannerSettleDelay);
    // A page that queues an offer from its own JS (the `pushPromptOffer`
    // bridge, fired on DOMContentLoaded) gets here before onLoadStop, so
    // "still loading" has to mean *wait*, not *give up*. Bounded, because a
    // page whose sub-resources never finish must not hold the offer forever.
    final deadline = DateTime.now().add(_bannerSettleTimeout);
    while (mounted &&
        _loading &&
        _navGeneration == generation &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!mounted || _navGeneration != generation || _loading) {
      return false;
    }
    if (_bannerGeneration == generation) {
      return false;
    }
    _bannerGeneration = generation;
    return true;
  }

  /// The first time the user lands on a location-aware screen without location
  /// set, offer a soft, dismissible banner. Runs at most once per app session.
  /// If location is already granted we just refresh the cookies silently; if it
  /// was permanently denied we stay quiet (the banner couldn't re-prompt).
  Future<void> _maybeOfferLocation(String path, int generation) async {
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
    if (!await _claimBanner(generation)) {
      return; // superseded by a redirect or another offer — try the next page
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

  // ── Notification opt-in ───────────────────────────────────────────────────
  //
  // The OS notification dialog used to fire from PushService.init at shell
  // mount — seconds after launch, before the user knew what they'd be notified
  // about. It's now raised only from the two places where the answer means
  // something: the preferences page (the notification settings screen, whose
  // "app instead of email" checkbox the server disables until this phone has a
  // live token) and a lot page in an in-person auction ("tell me when this is
  // about to sell"). Both run the identical opt-in — see PushPromptService.

  /// The web notification settings page. Matched app-side so the offer works
  /// with no web change; the in-person lot page can't be recognized from a URL
  /// and arrives through the `pushPromptOffer` JS bridge instead.
  static bool _isPreferencesPath(String path) =>
      path == '/preferences/' || path == '/preferences';

  /// What the `pushGetState` / `pushEnable` bridge handlers resolve with, so a
  /// page can render "notifications are on for this phone" without guessing.
  Future<Map<String, Object?>> _pushState() async => {
    'supported': PushService.instance.isConfigured,
    'permitted': await PushService.instance.hasPermission(),
    // False on a deployment without notifications/prefs/ — the page then owns
    // the toggles and the app only handles the OS permission.
    'prefs_endpoint': NotificationPrefsService.instance.isAvailable,
  };

  /// Maps the bridge's reason string onto a surface. Anything unrecognized (a
  /// newer template, a typo) falls back to the lot wording, which is the only
  /// surface the web has a reason to drive.
  static PushPromptSurface _pushSurfaceFrom(Object? raw) =>
      '$raw' == 'preferences'
      ? PushPromptSurface.preferences
      : PushPromptSurface.lotSellingSoon;

  /// A web button asking for notifications outright — the user tapped "notify
  /// me", so run the opt-in rather than asking them again in a banner.
  Future<void> _enablePushFromWeb(PushPromptSurface surface) async {
    await PushPromptService.instance.markOffered(surface);
    await _enablePushFromBanner(surface);
  }

  Future<void> _maybeOfferPushForPath(String path, int generation) async {
    if (!_isPreferencesPath(path)) {
      return;
    }
    await _maybeOfferPush(PushPromptSurface.preferences, generation);
  }

  Future<void> _maybeOfferPush(
    PushPromptSurface surface,
    int generation,
  ) async {
    if (!await PushPromptService.instance.shouldOffer(surface)) {
      return;
    }
    if (!await _claimBanner(generation)) {
      return;
    }
    await PushPromptService.instance.markOffered(surface);
    _showPushBanner(surface);
  }

  void _showPushBanner(PushPromptSurface surface) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.notifications_none),
        content: Text(switch (surface) {
          PushPromptSurface.preferences =>
            'Get notifications on this phone instead of emails?',
          PushPromptSurface.lotSellingSoon =>
            'Get notified when lots you\'re watching are about to sell?',
        }),
        actions: [
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => unawaited(_enablePushFromBanner(surface)),
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  /// Runs the opt-in and reports the outcome. A decline is a dead end unless we
  /// say where the switch lives (iOS never re-prompts), and a grant the server
  /// couldn't record needs the same signpost — so both point at
  /// `/preferences/`, except when that's already the page underneath.
  Future<void> _enablePushFromBanner(PushPromptSurface surface) async {
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    }
    final outcome = await PushPromptService.instance.enable();
    if (!mounted) {
      return;
    }
    final onPreferences = surface == PushPromptSurface.preferences;
    switch (outcome.result) {
      case PushEnableResult.enabled when outcome.prefsWritten:
        // The preferences page renders these very checkboxes — reload so it
        // shows what just changed rather than a stale unchecked box.
        if (onPreferences) {
          await _controller?.reload();
        }
        _showSnack('Notifications are on for this phone.');
      case PushEnableResult.enabled:
        _showPushFollowUp(
          'Notifications are allowed. Finish turning them on in your '
          'preferences.',
          onPreferences: onPreferences,
        );
      case PushEnableResult.denied:
        _showPushFollowUp(
          'Notifications are turned off for this app. You can turn them on in '
          'your phone\'s settings.',
          onPreferences: true, // the fix is in system settings, not on the page
          settingsAction: true,
        );
      case PushEnableResult.unavailable:
        _showSnack('Notifications aren\'t available on this device yet.');
    }
  }

  void _showPushFollowUp(
    String message, {
    required bool onPreferences,
    bool settingsAction = false,
  }) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 8),
        action: settingsAction
            ? SnackBarAction(
                label: 'Settings',
                onPressed: () => unawaited(openAppSettings()),
              )
            : onPreferences
            ? null
            : SnackBarAction(
                label: 'Preferences',
                onPressed: () => _loadPath('/preferences/'),
              ),
      ),
    );
  }

  void _onLoadStart(InAppWebViewController controller, WebUri? url) {
    // A new page load supersedes any contextual banner the user hasn't acted
    // on, so it doesn't float over an unrelated screen — and invalidates any
    // offer still settling for the page we're leaving (see _claimBanner).
    _navGeneration++;
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
      setState(() => _loading = true);
    }
  }

  /// A main-frame page failed to load — usually no connectivity. Offer the
  /// native offline fallback when there's offline auction data to fall back
  /// on; otherwise just offer a retry. This is the "connection lost mid-
  /// auction" entry point into offline mode.
  Future<void> _onLoadError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) async {
    if (!(request.isForMainFrame ?? true) || !mounted) {
      return;
    }
    setState(() => _loading = false);
    // `hasData` is a synchronous read of an asynchronously-loaded cache, so ask
    // for the load first. It matters in exactly the case this banner exists
    // for: launching in airplane mode fails the first page instantly — faster
    // than OfflineSyncService's own ensureLoaded — and without this the
    // "Offline mode" button would be missing precisely when it's needed.
    await OfflineStore.instance.ensureLoaded();
    if (!mounted) {
      return;
    }
    final hasOffline = OfflineStore.instance.hasData;
    final messenger = ScaffoldMessenger.of(context)
      ..hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.cloud_off),
        content: Text(
          hasOffline
              ? 'Can\'t reach the server. You can keep running your auction '
                    'offline — changes sync back automatically.'
              : 'Can\'t reach the server.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              _controller?.reload();
            },
            child: const Text('Retry'),
          ),
          if (hasOffline)
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
                context.push('/offline');
              },
              child: const Text('Offline mode'),
            ),
        ],
      ),
    );
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
    // Contextual permission offers, each gated on the page settling first
    // (_claimBanner) so nothing flashes on a redirect: location on the
    // auctions/lots screens, notifications on the preferences page. The home
    // page and everything else triggers neither.
    final generation = _navGeneration;
    unawaited(_maybeOfferLocation(url.path, generation));
    unawaited(_maybeOfferPushForPath(url.path, generation));
    if (url.host == Uri.parse(EnvironmentConfig.webBaseUrl).host) {
      _rememberPage(url);
    }
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
    // Backing out of an AR-opened lot returns to AR (once), mirroring the
    // page's "Back to AR" bar, as long as we're still on that src=ar page.
    final arReturn = _arReturn;
    if (arReturn != null) {
      final current = await controller?.getUrl();
      if (current != null && current.queryParameters['src'] == 'ar') {
        _arReturn = null; // consume: a second back is normal web history
        await _launchAr(arReturn.slug, '${arReturn.lotPk}');
        return;
      }
      _arReturn = null; // navigated away from the AR lot page — drop it
    }
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

  /// Prints [lotPks] by the method the user picked on the `/printing/` page.
  ///
  /// Bluetooth deliberately has **no screen**: the user already tapped print,
  /// so there is nothing to confirm before and nothing to acknowledge after.
  /// The job runs over whatever page they were on, showing a progress message
  /// and otherwise staying out of the way — only a failure interrupts. The
  /// PDF and System methods still push `PrintLabelScreen`, where the PDF (and
  /// the OS dialog it feeds) is the actual deliverable.
  Future<void> _launchPrint(List<int> lotPks, {LabelPrefs? prefs}) async {
    if (lotPks.isEmpty) {
      return;
    }
    final resolved = prefs ?? await LabelPrefsService.instance.fetch();
    if (!mounted) {
      return;
    }
    if (resolved?.printMethod == PrintMethod.bluetooth) {
      await _printNatively(lotPks, prefs: resolved);
      return;
    }
    if (lotPks.length == 1) {
      unawaited(context.push('/print/${lotPks.first}', extra: resolved));
      return;
    }
    // A batch link is only emitted for the Bluetooth method, so getting one
    // on any other method means the page was rendered before the method
    // changed. Reload it and the page renders its own PDF button, which is
    // the right answer for those methods.
    _showSnack('Your label print method changed — reloading this page.');
    unawaited(_controller?.reload());
  }

  /// Runs a Bluetooth print job and reports only what's worth reporting.
  Future<void> _printNatively(List<int> lotPks, {LabelPrefs? prefs}) async {
    if (LabelPrintService.instance.isBusy) {
      // One BLE link, one job at a time — a second tap can't interleave.
      _showSnack('Still printing — one moment.');
      return;
    }
    final messenger = ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(_printingSnack(lotPks.length));
    final result = await LabelPrintService.instance.printLots(
      lotPks,
      ref: ref,
      prefs: prefs,
    );
    messenger.hideCurrentSnackBar();
    if (!mounted) {
      return;
    }
    switch (result.status) {
      case LabelPrintStatus.sent:
        _reportPrinted(result);
      case LabelPrintStatus.noPrinter:
        await _offerPrinterSetup();
      case LabelPrintStatus.failed:
        // Retry the labels that *didn't* print, not the whole batch — the
        // printed ones are already stuck on boxes. They go out in order, so
        // the remainder is everything past the printed count.
        final remaining = lotPks.sublist(
          result.printed.clamp(0, lotPks.length),
        );
        _showSnack(
          _failureText(result),
          actionLabel: result.fixInSettings ? 'Settings' : 'Retry',
          onAction: result.fixInSettings
              ? () => unawaited(openAppSettings())
              : () => unawaited(_printNatively(remaining, prefs: prefs)),
        );
      case LabelPrintStatus.busy:
        break;
    }
  }

  /// The non-blocking "printing" message: a live count over whatever page the
  /// user was on, with a way to stop a long batch. It runs until the job hides
  /// it rather than on a timer, since a hundred labels take minutes.
  SnackBar _printingSnack(int total) => SnackBar(
    duration: const Duration(hours: 1),
    content: ValueListenableBuilder<LabelPrintProgress?>(
      valueListenable: LabelPrintService.instance.progress,
      builder: (context, progress, _) => Text(
        progress?.message ??
            (total > 1 ? 'Printing $total labels…' : 'Printing label…'),
      ),
    ),
    action: total > 1
        ? SnackBarAction(
            label: 'Stop',
            onPressed: LabelPrintService.instance.cancel,
          )
        : null,
  );

  /// What a failed job says. Mid-batch, how far it got is the first thing the
  /// user needs — which labels to re-print depends on it.
  String _failureText(LabelPrintResult result) {
    final detail =
        result.message ?? 'Printing failed. Check the printer and try again.';
    if (result.total > 1 && result.printed > 0) {
      return 'Printed ${result.printed} of ${result.total} labels, then '
          'stopped: $detail';
    }
    return detail;
  }

  /// A label that printed is its own confirmation — it's in the user's hand.
  /// So: say nothing for a clean single label, and speak up only for a soft
  /// problem the printer reported, a batch that ended early, or a batch big
  /// enough that "did all of those go?" is a real question.
  void _reportPrinted(LabelPrintResult result) {
    if (result.message != null) {
      _showSnack(result.message!);
    } else if (result.printed < result.total) {
      _showSnack('Stopped after ${result.printed} of ${result.total} labels.');
    } else if (result.total > 1) {
      _showSnack('Sent ${result.total} labels to the printer.');
    }
  }

  /// Nothing is paired. The first time that happens, take the user to the
  /// `/printing/` page — "no printer is set up" isn't something they can act
  /// on from the page they're on, and pairing lives there. Every time after,
  /// they've seen that page and chose not to finish, so nudge with a way back
  /// instead of yanking them off what they were doing.
  Future<void> _offerPrinterSetup() async {
    final firstRun = await PrinterSetupPrompt.instance.consumeFirstRun();
    if (!mounted) {
      return;
    }
    if (firstRun) {
      _loadPath('/printing/');
      _showSnack('Connect your label printer here, then print again.');
      return;
    }
    _showSnack(
      'No printer connected.',
      actionLabel: 'Set up',
      onAction: () => _loadPath('/printing/'),
    );
  }

  void _showSnack(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
  }

  /// The state object the printer JS handlers resolve with — what the
  /// `/printing/` page's Bluetooth card renders. `labelSize` is the size the
  /// printer itself reported (profiles that can read it); the page offers to
  /// adopt it into the user's label prefs.
  /// How long the `/printing/` page waits for a saved printer to come back
  /// before rendering. Short on purpose: the page must not hang behind a
  /// printer that is switched off or in another room.
  static const _printerReconnectTimeout = Duration(seconds: 6);

  /// [_printerState], but first gives a remembered printer a chance to be
  /// *actually* connected.
  ///
  /// There is no live BLE link on a fresh launch — a saved printer is only
  /// remembered — and nothing used to re-open one until the moment of a print.
  /// So the Bluetooth card said "disconnected" every time the user opened the
  /// page, even with the printer sitting there powered on, and the only way to
  /// make it say otherwise was to print something. Reconnecting here is
  /// cheap (the printing page is exactly where a user checks their printer)
  /// and makes the card's state honest.
  ///
  /// Failure is silent by design: this is a status read, not a print. If the
  /// printer is off, the card correctly shows disconnected, and printing still
  /// reconnects on its own later.
  Future<Map<String, dynamic>> _printerStateReconnecting() async {
    final printer = await ref.read(printerProvider.future);
    if (printer != null &&
        !BluetoothService.instance.isConnectedTo(printer.address)) {
      try {
        await ref
            .read(printerProvider.notifier)
            .ensureConnected()
            .timeout(_printerReconnectTimeout);
      } on Object {
        // Off, out of range, or Bluetooth disabled — report it as disconnected.
      }
    }
    return _printerState();
  }

  Map<String, dynamic> _printerState() {
    final printer = ref.read(printerProvider).value;
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
    if (ref.read(authProvider).value != null) {
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
    final b = ref.watch(configProvider).value?.brandName;
    return (b == null || b.isEmpty) ? AppConstants.appName : b;
  }

  void _onTitleTap() => showCommandPalette(
    context,
    _loadPath,
    // AR is a native screen, not a web path — the palette's locally injected
    // AR entry routes through the same push+return flow as the deep link.
    onOpenAr: (slug) => unawaited(_launchAr(slug, null)),
  );

  // ── Navigation, downloads, permissions, bridges ───────────────────────────

  /// The website's single-lot label PDF (`SingleLotLabelView`, Django's
  /// `lots/print/<int:pk>/`).
  static final _singleLotLabelPath = RegExp(r'^/lots/print/(\d+)/?$');

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

    // The website's own single-lot label link. Only the lot detail page knows
    // to emit `fishauctions://print/<pk>` instead; every other route to a
    // label — the users table's per-bidder links, the command palette, a
    // bookmarked URL — goes through this path and would hand a Bluetooth user
    // a PDF to share. Catch it here so *any* single-lot label prints natively,
    // rather than gating each template on the print method one by one.
    final labelLotPk = int.tryParse(
      _singleLotLabelPath.firstMatch(uri.path)?.group(1) ?? '',
    );
    if (labelLotPk != null && action.isForMainFrame) {
      // Only pay for the prefs lookup once the path has already matched.
      final prefs = await LabelPrefsService.instance.fetch();
      if (prefs?.printMethod == PrintMethod.bluetooth && mounted) {
        unawaited(_launchPrint([labelLotPk], prefs: prefs));
        return NavigationActionPolicy.CANCEL;
      }
    }

    // A logout link on our host — an in-page web sign-out — means sign out
    // everywhere: the two sessions stay in lockstep, so run the full native
    // sign-out (which also POSTs the web logout and wipes cookies) instead of
    // letting the page navigate. Skip if already signed out so our own menu
    // logout doesn't double-fire.
    if (uri.path == '/logout/' && ref.read(authProvider).value != null) {
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
    PermissionStatus status;
    try {
      status = await Permission.camera.request();
    } on Object catch (e) {
      debugPrint('WebView camera permission request failed: $e');
      status = PermissionStatus.denied;
    }
    if (!status.isGranted) {
      // Denying leaves the page's scanner dark with no explanation —
      // getUserMedia just rejects, and the check-in page can't tell a decline
      // from a device with no camera. Say what happened, and offer the only
      // actual fix once the OS has stopped asking.
      _showSnack(
        'Camera access is off for this app, so the barcode scanner can\'t '
        'start.',
        actionLabel: status.isPermanentlyDenied ? 'Settings' : null,
        onAction: status.isPermanentlyDenied
            ? () => unawaited(openAppSettings())
            : null,
      );
    }
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
    // A declined calendar permission (or a phone with no calendar app) makes
    // this return false or throw, and the web button has already switched to
    // "added" by then — so a silent failure reads as "the app added it and
    // lost it". Tell the user, and point at the download that still works.
    bool added;
    try {
      added = await Add2Calendar.addEvent2Cal(
        Event(
          title: '${data['title'] ?? ''}',
          description: '${data['details'] ?? ''}',
          location: '${data['location'] ?? ''}',
          startDate: start,
          endDate: end,
        ),
      );
    } on Object catch (e) {
      debugPrint('Add to calendar failed: $e');
      added = false;
    }
    if (!added) {
      _showSnack(
        'Couldn\'t add that to your calendar. Check that this app is allowed '
        'to access your calendar.',
        actionLabel: 'Settings',
        onAction: () => unawaited(openAppSettings()),
      );
    }
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
        // fishauctions://print/<lot_pk> — one label; ?lots=1,2,3 — a batch
        // (the bulk label buttons, on the Bluetooth method). Without any
        // parseable pk (e.g. a bare "set up printing" link) fall back to the
        // /printing/ page, the one place printing is configured.
        final lotPks = lotPksFromPrintLink(uri);
        if (lotPks.isEmpty) {
          _loadPath('/printing/');
        } else {
          unawaited(_launchPrint(lotPks));
        }
      case 'ar':
        // fishauctions://ar/<auction_slug>[?locate=<lot_pk>] — AR lot mode
        // (auction rules page button; lot pages add ?locate to aim at one
        // lot). A missing slug means a malformed link; ignore it.
        final slug = uri.pathSegments.firstOrNull;
        if (slug != null && slug.isNotEmpty) {
          unawaited(_launchAr(slug, uri.queryParameters['locate']));
        }
    }
  }

  /// Push the AR screen and, when it pops with a web path (the card's "open
  /// lot page" button, carrying `?src=ar` so the page-view beacon records the
  /// scan), load that page in the shell — same await-then-act shape as
  /// [_launchPayment].
  Future<void> _launchAr(String auctionSlug, String? locateLotPk) async {
    final locate = int.tryParse(locateLotPk ?? '');
    final query = locate == null ? '' : '?locate=$locate';
    final result = await context.push(
      '/ar/${Uri.encodeComponent(auctionSlug)}$query',
    );
    if (result is String && mounted) {
      // Remember the AR origin so a hardware/web back from this lot page
      // returns to AR (the deep link's `?src=ar` already tells the backend to
      // render its own "Back to AR" bar too).
      final lotPk = _lotPkFromPath(result);
      _arReturn = lotPk == null ? null : (slug: auctionSlug, lotPk: lotPk);
      _loadPath(result);
    }
  }

  /// The lot pk in a `/lots/<pk>/…` path, or null if it isn't a lot page.
  static int? _lotPkFromPath(String path) {
    final match = RegExp(r'/lots/(\d+)/').firstMatch(path);
    return match == null ? null : int.tryParse(match.group(1)!);
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
                _offlineModeTile(ctx),
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

  /// The drawer's "Offline mode" entry — the native users/lots/set-winners
  /// screens that keep an in-person auction running with no connection.
  /// Only shown once a snapshot of the operator's last admin auction exists
  /// (non-admins never see it). Rebuilds live because the first snapshot can
  /// land while the drawer is open.
  Widget _offlineModeTile(BuildContext ctx) => ListenableBuilder(
    listenable: OfflineStore.instance,
    builder: (_, _) {
      if (!OfflineStore.instance.hasData) {
        return const SizedBox.shrink();
      }
      return ListTile(
        leading: const Icon(Icons.cloud_off),
        title: const Text('Offline mode'),
        onTap: () {
          Navigator.of(ctx).pop();
          context.push('/offline');
        },
      );
    },
  );

  /// The drawer's "Clubs" entry. Signed in with memberships → an expandable
  /// menu ("Find a club" + each club, admin ones badged), rebuilding the web
  /// navbar's Clubs dropdown. Otherwise (signed out, no clubs, still loading,
  /// or the fetch failed) → the plain browse link, matching the web navbar's
  /// bare "Clubs" link for users with no clubs.
  Widget _clubsTile(BuildContext ctx) {
    final clubs = ref.watch(myClubsProvider).value ?? const <ClubMenuItem>[];
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
            // It fills the whole area — including behind the system nav bar —
            // so the reserved-inset strip below the web content is dark, not
            // blank.
            const ColoredBox(
              color: AppTheme.scaffoldBackground,
              child: SizedBox.expand(),
            ),
            // Reserve the (edge-to-edge) system nav-bar inset so web page
            // content — bottom action bars especially — never sits under the
            // translucent nav buttons. The AppBar already handles the top.
            SafeArea(
              top: false,
              child: InAppWebView(
                initialSettings: _webViewSettings,
                onWebViewCreated: (c) => unawaited(_onWebViewCreated(c)),
                onLoadStart: _onLoadStart,
                onLoadStop: (c, url) => unawaited(_onLoadStop(c, url)),
                onReceivedError: _onLoadError,
                shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
                onCreateWindow: _onCreateWindow,
                onDownloadStarting: _onDownloadStart,
                onPermissionRequest: _onPermissionRequest,
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 3),
          ],
        ),
      ),
    );
  }
}
