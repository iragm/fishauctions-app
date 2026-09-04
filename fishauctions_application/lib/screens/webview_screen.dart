import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert' show jsonEncode;
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
import '../models/ar_models.dart';
import '../models/checkin_models.dart';
import '../models/club_menu_item.dart';
import '../models/drawer_menu.dart';
import '../models/label_prefs.dart';
import '../models/tap_to_pay_status.dart';
import '../providers/auth_provider.dart';
import '../providers/clubs_provider.dart';
import '../providers/config_provider.dart';
import '../providers/printer_provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/bluetooth_service.dart';
import '../services/checkin_service.dart';
import '../services/config_service.dart';
import '../services/connect_flow_service.dart';
import '../services/deep_link_service.dart';
import '../services/dictation_service.dart';
import '../services/download_service.dart';
import '../services/label_prefs_service.dart';
import '../services/label_print_service.dart';
import '../services/last_page_service.dart';
import '../services/local_notification_service.dart';
import '../services/location_service.dart';
import '../services/menu_store.dart';
import '../services/notification_prefs_service.dart';
import '../services/offline_store.dart';
import '../services/offline_sync_service.dart';
import '../services/printer_setup_prompt.dart';
import '../services/push_prompt_service.dart';
import '../services/push_service.dart';
import '../services/remote_print_service.dart';
import '../services/shortcut_service.dart';
import '../services/tap_to_pay_service.dart';
import '../services/voice_command_service.dart';
import '../utils/bi_icons.dart';
import '../utils/connect_flows.dart';
import '../utils/external_links.dart';
import '../utils/platform_bridge.dart';
import '../widgets/payment_sheet.dart';
import '../widgets/printer_connect_sheet.dart';
import '../widgets/tap_to_pay_awareness.dart';
import '../widgets/tap_to_pay_branding.dart';
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

  /// Whether the last main-frame load failed, so the resume handler knows to
  /// try again. Set in [_onLoadError] and cleared in `_onLoadStart` rather than
  /// on load *stop*: the engine can report a stop after an error, and clearing
  /// it there would leave a failed page looking successful.
  bool _loadFailed = false;
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
  // repair is bounded so a failed/looping handoff can't spin: one attempt per
  // run of consecutive /login/ landings, reset by any page that renders (see
  // _reconcileWebSession) and by a returning connect flow.
  int _handoffAttempts = 0;

  // Check-in nudges that could not be delivered as a tray notification (the
  // OS won't show one for this app yet) and so still owe the user in-app UI.
  // They wait here until the shell is the visible route — see
  // _drainDeferredCheckin.
  final List<CheckinAction> _deferredCheckin = [];

  // Invoice pk of the payment sheet currently being launched/shown, or null.
  // Guards against a double tap of the "Tap to Pay" button (or a repeated deep
  // link) opening overlapping sheets.
  int? _activePaymentPk;

  // When a lot page was opened *from* AR mode (the card's "open lot page"),
  // this remembers the AR origin so the next back press returns to AR and
  // re-beacons the lot — the same intent as the page's "Back to AR" bar. It's
  // consumed on that first back (so a second back does normal web history and
  // there's no AR⇄lot loop) and dropped once the user navigates elsewhere.
  ({String slug, int lotPk, String path})? _arReturn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Home-screen shortcut tapped while the shell is already up → navigate
    // in place. (Cold starts are handled by _initialUrl consuming the pending
    // path instead — see _onShortcutTapped.)
    ShortcutService.instance.pending.addListener(_onShortcutTapped);
    DeepLinkService.instance.pending.addListener(_onDeepLink);
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
    // Apply the deployment's voice grammar, so the set-winners page's
    // voiceGetState answers with this deployment's settings rather than the
    // bundled defaults.
    unawaited(_warmVoice());
    // Load the drawer's menu — the persisted copy first, then the server's.
    unawaited(_warmMenu());
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
    // Check-in nudges are delivered as tray notifications rather than drawn
    // over whatever is on screen (see _handleCheckinActions); this is the
    // return path for a tap, including one that launched the app from cold.
    LocalNotificationService.instance.pendingPayload.addListener(
      _onNotificationTapped,
    );
    unawaited(LocalNotificationService.instance.init());
    // Printing from a computer to this phone's printer (BACKEND_SPEC.md Part
    // R). The heartbeat is what lets the website say "your phone was last seen
    // 2 minutes ago" instead of offering a feature that silently won't work;
    // the data-message channel is how a job actually arrives.
    PushService.instance.dataMessage.addListener(_onPushData);
    RemotePrintService.instance.start(ref);
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
      // Apple's requirement 1.5: "at the launch of your app or when it comes to
      // the foreground, your app must trigger the initial preparation and
      // warming-up of Tap to Pay on an iPhone". Initializing the SDK isn't that
      // — the reader only starts preparing once the SDK is *authorized*, which
      // until now happened per invoice, at the moment the cashier pressed the
      // button. That is also the only way to hit requirement 5.6 (the Tap to
      // Pay UI must appear within one second, 90% of the time).
      //
      // Self-disables on a deployment without the eligibility endpoint, in
      // which case the charge path authorizes per invoice exactly as before.
      await TapToPayService.instance.prepare(
        applicationId: cfg.hasSquare ? cfg.squareApplicationId : null,
      );
    } on Object catch (e) {
      debugPrint('Square SDK warm-up skipped: $e');
    }
  }

  /// Shows the Tap to Pay awareness moment once per device, to merchants who
  /// can actually use it.
  ///
  /// Apple mandates at least one in-app awareness moment for all eligible users
  /// (checklist 3.1/3.3, marketing 6.2), with a full-screen modal as the named
  /// best practice (3.2). Gated on the backend's eligibility answer because the
  /// same guide says to limit the feature to the appropriate user type in an
  /// app with a mixed consumer/merchant base — which this very much is, since
  /// nearly everyone here is a bidder, not an auctioneer.
  ///
  /// **Only a page asks for this.** The single caller is the `tapToPayOffer`
  /// bridge handler, which `auction_ribbon.html` calls when
  /// `Auction.offers_tap_to_pay` is true — this admin's auction has a Square
  /// account that is connected *and* in-person capable, i.e. exactly the page
  /// where the website is about to show its own Square card. The app used to
  /// ask the question itself on every page load, from a URL prefix
  /// (`/auctions/…`) plus a live credential; that is an approximation of "is
  /// the site offering card payments here?" and it put the modal in front of
  /// organizers on unrelated pages. There is no app-side fallback on purpose:
  /// guessing is what the guess got wrong, and an older deployment whose ribbon
  /// never calls the handler shows no unprompted modal at all, which is the
  /// right failure.
  ///
  /// Runs behind the same settle-and-claim discipline as the location and
  /// notification offers, so it can't flash over a page that's about to
  /// redirect.
  Future<void> _maybeOfferTapToPay(int generation) async {
    // Every gate below is silent by design and several are invisible from
    // outside the app — "already shown on this device" lives in the keychain
    // and survives reinstalls, and losing the single banner slot to the
    // location or notification offer looks identical to being ineligible. From
    // a phone that is all one symptom: nothing happens. Read these over USB
    // with `idevicesyslog`.
    void skip(String why) =>
        debugPrint('Tap to Pay awareness not offered: $why');
    final service = TapToPayService.instance;
    if (!service.isApplePlatform) {
      skip('not an Apple platform');
      return;
    }
    final eligibility = service.eligibility.value;
    // **`canCharge`, not `eligible`.** `eligible` is only "administers some
    // auction or club", which is true of every organizer on the site including
    // the ones with no Square account at all — and an announcement about taking
    // card payments is noise to someone who has nothing to take them into.
    // `canCharge` is the backend saying it has issued live seller credentials:
    // Square connected, in-person scope, token good. That is precisely "the
    // account is connected and ready, and the only thing missing is this
    // phone", which is the one state this modal has anything to say about.
    //
    // Kept even though the page has now answered the same question better,
    // because it answers a different half of it: the ribbon knows the auction
    // can take a card, this knows *this device's* operator was issued live
    // credentials. A null here is usually a race — the warm-up fetch hasn't
    // landed yet on a cold start straight onto an auction page — and it costs
    // one impression, not the feature: nothing is claimed, the ribbon fires on
    // every admin auction page, and the next one offers.
    if (eligibility == null || !eligibility.canCharge) {
      skip(
        eligibility == null
            ? 'eligibility not fetched yet (warm-up race on a cold start)'
            : 'backend says canCharge=false (no live seller credentials)',
      );
      return;
    }
    if (await TapToPayAwarenessSheet.alreadyShown()) {
      skip('already shown on this device (keychain flag, survives reinstall)');
      return;
    }
    // Nothing to announce to someone who already set it up, or whose iPhone
    // can't do it at all.
    if (!(await service.unsupportedReason()).isSupported) {
      skip('this iPhone cannot do Tap to Pay');
      return;
    }
    if (await service.isEnabled()) {
      skip('already set up on this device');
      return;
    }
    if (!await _claimBanner(generation)) {
      // Not fatal and deliberately not marked shown: the banner slot is one per
      // page load, so the location or notification offer having taken it means
      // this simply tries again on the next auction page — by which time those
      // two are spent for the session.
      skip('lost the banner slot for this page load');
      return;
    }
    if (!mounted) {
      return;
    }
    if (!mounted) {
      return;
    }
    final wantsSetup = await TapToPayAwarenessSheet.show(context);
    // Marked on *acknowledgement*, not on delivery — the way a notification
    // clears when you act on it rather than when it arrives. This used to mark
    // before presenting, on the theory that a merchant who force-quits
    // mid-modal has still seen it; but Apple's requirement 3.3 is that the
    // announcement is *seen*, and a modal that existed for 200 ms before the
    // process died was not. Worse, it made every way of failing to present
    // permanent. Dismissal is the user saying so, and the failure mode is
    // bounded and self-correcting: it comes back next time, they dismiss it,
    // done.
    await TapToPayAwarenessSheet.markShown();
    if (wantsSetup && mounted) {
      await context.push('/tap-to-pay');
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
  /// Hand the deployment's `voice` block to the grammar before any page can
  /// ask `voiceGetState`. Cheap and synchronous once config is in hand — no
  /// permission, no microphone, nothing started; the served block only decides
  /// which words are listened for and whether voice is offered at all.
  Future<void> _warmVoice() async {
    try {
      final cfg = await ref.read(configProvider.future);
      VoiceCommandService.instance.applyConfig(cfg.voice);
    } on Object catch (e) {
      debugPrint('Voice config warm-up skipped: $e');
    }
  }

  /// Bring up the navigation drawer's menu: the last-good payload off disk
  /// first — so an offline cold start still gets this deployment's drawer
  /// rather than the bundled six links — then whatever the server says.
  ///
  /// Deliberately not `configProvider`: the `menu` block is the one per-user
  /// part of the config response, and [ConfigService.loadForCurrentUser] is
  /// what stops a copy fetched by the signed-out login screen from being this
  /// session's menu. Nothing here is on the critical path — the drawer isn't
  /// on screen at launch and rebuilds itself when the payload lands.
  Future<void> _warmMenu() async {
    await MenuStore.instance.ensureLoaded();
    try {
      final cfg = await ConfigService.instance.loadForCurrentUser();
      // **Only adopt a menu the server built for this user.** The config
      // endpoint reads the bearer token optionally: a missing or stale one is
      // answered with 200 and the *signed-out* menu, not a 401. Adopting that
      // would overwrite a perfectly good drawer — and persist it — leaving a
      // signed-in user with signed-out chrome and nothing to retry, since
      // nothing failed. `loadForCurrentUser` re-fetches on the next warm-up,
      // by which point the token has usually been refreshed.
      if (ConfigService.instance.configIsForCurrentUser) {
        await MenuStore.instance.adopt(cfg.menu);
      } else {
        debugPrint('Config came back signed out; keeping the previous menu');
      }
    } on Object catch (e) {
      debugPrint('Drawer menu warm-up skipped: $e');
    }
  }

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
  ///
  /// Also re-asks for the *menu* when config loaded fine but anonymously; see
  /// the second branch.
  Future<void> _rewarmConfigIfFailed() async {
    if (ref.read(configProvider).hasError) {
      ref.invalidate(configProvider);
      await _warmSquare();
      await _warmPush();
      await _warmVoice();
      await _warmMenu();
      return;
    }
    // The other way config can be wrong is subtler and doesn't look like a
    // failure at all: `/api/mobile/config/` reads the bearer token optionally,
    // so a fetch made with a stale one came back 200 with the **signed-out**
    // menu. Nothing errored, so the branch above never fires and the drawer
    // would stay signed-out for the life of the process. `_warmMenu` refreshes
    // the access token before re-asking (`ConfigService._fetch`), which is the
    // whole point of doing this on resume rather than on a timer: by now the
    // user has usually fixed whatever the network was doing.
    if (!ConfigService.instance.configIsForCurrentUser) {
      await _warmMenu();
    }
  }

  /// The first argument of a `callHandler(name, arg)` call, or null when the
  /// page passed none.
  ///
  /// **Never reach for `args.firstOrNull` in a handler, and always declare the
  /// parameter as `List<dynamic>`.** `addJavaScriptHandler`'s `callback` is
  /// typed as a bare `Function`, so an inferred lambda parameter is `dynamic`
  /// and every member access on it becomes a *dynamic* invocation — which
  /// never finds an extension method. `firstOrNull` is `package:collection`'s
  /// extension on `Iterable`, not a member of `List`, so the call compiled
  /// with no import and threw `NoSuchMethodError` the moment a page used it.
  /// The plugin turns a throwing handler into a **rejected** `callHandler`
  /// promise, which pages read as "this app build has no such handler": that
  /// is what made set-winners answer a tap on Listen with "Voice is not
  /// available on this phone" — instantly, with no microphone prompt — while
  /// `voiceGetState`, which ignores its arguments, worked fine and revealed
  /// the button. `pushPromptOffer`/`pushEnable` broke the same way.
  ///
  /// Declaring the type is the real guard: a missing member is then a compile
  /// error instead of a runtime one.
  static Object? _firstArg(List<dynamic> args) =>
      args.isEmpty ? null : args.first as Object?;

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
      // The website's own sign-out button, caught at submit time by
      // `_webLogoutHook` so the JWT pair dies with the cookie session. Never
      // fired by a mere visit to /logout/ — that URL is a confirmation page.
      ..addJavaScriptHandler(
        handlerName: 'webLogout',
        callback: (List<dynamic> args) {
          if (ref.read(authProvider).value != null) {
            unawaited(_signOut());
          }
          return {'ok': true};
        },
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
        callback: (List<dynamic> args) async {
          final surface = _pushSurfaceFrom(_firstArg(args));
          final before = _bannerGeneration;
          await _maybeOfferPush(surface, _navGeneration);
          return {'offered': _bannerGeneration != before};
        },
      )
      // Tap to Pay's awareness moment, offered from the page that knows it is
      // worth offering — the auction ribbon's Square card, which is the only
      // place that can tell "this user runs this auction and its Square account
      // is connected" (`Auction.offers_tap_to_pay`). This is the only caller;
      // the app no longer guesses from the URL.
      //   tapToPayOffer() → {offered}
      ..addJavaScriptHandler(
        handlerName: 'tapToPayOffer',
        callback: (List<dynamic> args) async {
          final before = _bannerGeneration;
          await _maybeOfferTapToPay(_navGeneration);
          return {'offered': _bannerGeneration != before};
        },
      )
      // Warm the reader ahead of the pay button, asked for by the page that
      // renders one (quick checkout, a single invoice). Never throws — a
      // rejected promise reads to the page as "this build has no handler".
      //   tapToPayWarm() → {warmed}
      ..addJavaScriptHandler(
        handlerName: 'tapToPayWarm',
        callback: (List<dynamic> args) async {
          try {
            return {'warmed': await _warmTapToPayFromPage()};
          } on Object catch (e) {
            debugPrint('Tap to Pay warm-up from page failed: $e');
            return {'warmed': false, 'error': '$e'};
          }
        },
      )
      ..addJavaScriptHandler(
        handlerName: 'pushEnable',
        callback: (List<dynamic> args) async {
          await _enablePushFromWeb(_pushSurfaceFrom(_firstArg(args)));
          return _pushState();
        },
      )
      // Voice-driven set winners (VOICE.md). The microphone is native because
      // iOS WKWebView has no Web Speech API and _onPermissionRequest denies
      // the page's own mic request; everything else — the button, the field
      // writes, the submit — stays on the page.
      //   voiceGetState()   → {supported, listening, permission, backend, …}
      //   voiceStart({auction}) → begins; events arrive on the receiver below
      //   voiceStop()       → {listening: false}
      ..addJavaScriptHandler(
        handlerName: 'voiceGetState',
        callback: (_) => _voiceState(),
      )
      ..addJavaScriptHandler(
        handlerName: 'voiceStart',
        callback: (List<dynamic> args) => _startVoice(_firstArg(args)),
      )
      ..addJavaScriptHandler(
        handlerName: 'voiceStop',
        callback: (_) async {
          try {
            await VoiceCommandService.instance.stop();
          } on Object catch (e) {
            debugPrint('voiceStop failed: $e');
          }
          return _voiceState();
        },
      )
      // The operator's own tuning, held on this device (VOICE.md §5.1):
      //   voiceGetSettings()      → {settings, settings_range, bias_supported}
      //   voiceSetSettings({...}) → stores, answers with what's now in force
      // Merged field by field, so the panel can send one control's value.
      ..addJavaScriptHandler(
        handlerName: 'voiceGetSettings',
        callback: (_) => _voiceSettings(),
      )
      ..addJavaScriptHandler(
        handlerName: 'voiceSetSettings',
        callback: (List<dynamic> args) => _voiceSettings(_firstArg(args)),
      )
      // Plain dictation, for any page that wants a field filled by talking —
      // the command palette's microphone first. Native for the same reason
      // voice set-winners is: `window.SpeechRecognition` exists in neither of
      // the app's engines, so the page's own implementation of this silently
      // never appears in the app.
      //   dictateGetState() → {supported, listening, permission}
      //   dictateStart()    → begins; transcripts arrive on the receiver below
      //   dictateStop()     → {listening: false}
      ..addJavaScriptHandler(
        handlerName: 'dictateGetState',
        callback: (_) => _dictationState(),
      )
      ..addJavaScriptHandler(
        handlerName: 'dictateStart',
        callback: (_) => _startDictation(),
      )
      ..addJavaScriptHandler(
        handlerName: 'dictateStop',
        callback: (_) async {
          try {
            await DictationService.instance.stop();
          } on Object catch (e) {
            debugPrint('dictateStop failed: $e');
          }
          return _dictationState();
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
    // A deep link outranks a quick action, which outranks the remembered
    // page: each is a more specific statement of where the user meant to go.
    final shortcutPath =
        DeepLinkService.instance.consume() ??
        ShortcutService.instance.consume() ??
        await _lastPagePath();
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
    DeepLinkService.instance.pending.removeListener(_onDeepLink);
    PushService.instance.pendingRoute.removeListener(_onPushRoute);
    PushService.instance.foregroundMessage.removeListener(_onForegroundPush);
    OfflineSyncService.instance.newConflicts.removeListener(
      _onOfflineConflicts,
    );
    CheckinService.instance.newActions.removeListener(_onCheckinActions);
    CheckinService.instance.stop();
    LocalNotificationService.instance.pendingPayload.removeListener(
      _onNotificationTapped,
    );
    PushService.instance.dataMessage.removeListener(_onPushData);
    RemotePrintService.instance.stop();
    // The shell going away is the last chance to close the microphone: the
    // page that owns the stop button is gone with it.
    _stopVoiceOnNavigation();
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

  /// A nudge arrives on the ping loop's schedule, not the user's, so the first
  /// choice is always a tray notification: it waits for them, it survives the
  /// app being backgrounded, and — for a check-in — it keeps the bidder number
  /// readable instead of expiring with a snackbar.
  ///
  /// Only when the OS won't display one (permission never asked for, which is
  /// the common case here — nothing in this app prompts for notifications at
  /// launch) does it fall back to in-app UI, and even then not immediately:
  /// [_deferredCheckin] holds it until the shell is the visible route, so a
  /// join prompt can never land on top of the lot-scanning camera.
  Future<void> _handleCheckinActions(List<CheckinAction> actions) async {
    for (final action in actions) {
      if (!mounted) {
        return;
      }
      final shown = await LocalNotificationService.instance.show(
        id: action.notificationId,
        title: _checkinNotificationTitle(action),
        body: _checkinNotificationBody(action),
        payload: action.notificationPayload,
      );
      if (!shown) {
        _deferredCheckin.add(action);
      }
    }
    _drainDeferredCheckin();
  }

  String _checkinNotificationTitle(CheckinAction action) =>
      switch (action.type) {
        CheckinActionType.setLocationOffer =>
          'Set the location for ${action.title}?',
        _ => action.title.isEmpty ? 'auction.fish' : action.title,
      };

  /// The server owns the copy (it composes the welcome line and the bidder
  /// number); the app only adds the affordance that a notification needs and a
  /// snackbar didn't — what tapping it will do.
  String _checkinNotificationBody(CheckinAction action) {
    final message = action.message.trim();
    final hint = switch (action.type) {
      CheckinActionType.joinOffer => 'Tap to join.',
      CheckinActionType.setLocationOffer =>
        'Tap to use this phone\'s '
            'position.',
      // Nothing to do — this one is the news itself.
      CheckinActionType.checkedIn => '',
    };
    if (message.isEmpty) {
      return hint;
    }
    return hint.isEmpty ? message : '$message $hint';
  }

  /// The user tapped one of the notifications above (possibly long after it
  /// was posted, possibly into a cold start). Acting on it is what they asked
  /// for, so it runs immediately rather than going through
  /// [_drainDeferredCheckin].
  void _onNotificationTapped() {
    final payload = LocalNotificationService.instance.consumePayload();
    if (payload == null || !mounted) {
      return;
    }
    final action = CheckinAction.fromNotificationPayload(payload);
    if (action != null) {
      unawaited(_runCheckinAction(action));
    }
  }

  /// Shows the in-app UI for [action] — the join sheet, the admin dialog, or
  /// (for a check-in that had nowhere else to go) a long snackbar.
  Future<void> _runCheckinAction(CheckinAction action) async {
    switch (action.type) {
      case CheckinActionType.checkedIn:
        // The server's message carries the bidder number, so this gets the
        // long duration: on this path there is nowhere to look it up again.
        _showSnack(action.message, duration: _bidderNumberSnackDuration);
      case CheckinActionType.joinOffer:
        await _showJoinOffer(action);
      case CheckinActionType.setLocationOffer:
        await _showSetLocationOffer(action);
    }
  }

  /// Runs the nudges that couldn't be delivered as notifications, but only
  /// while the shell is the route on screen. AR lot scanning and the payment
  /// sheet both push over this screen, and a modal drawn from underneath them
  /// is exactly the interruption this whole path exists to avoid — so they
  /// wait, and the next resume or return from AR drains them.
  void _drainDeferredCheckin() {
    if (!mounted || _deferredCheckin.isEmpty) {
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    final pending = List<CheckinAction>.of(_deferredCheckin);
    _deferredCheckin.clear();
    unawaited(() async {
      for (final action in pending) {
        if (!mounted) {
          return;
        }
        await _runCheckinAction(action);
      }
    }());
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
        // The bidder number is the one thing the user actually needs from
        // this, and there is nowhere else in the app or on the site for a
        // just-arrived bidder to look it up — the rules page they're about to
        // land on doesn't render it. So it goes in the message, and the
        // message gets long enough to write down.
        final bidder = result.bidderNumber;
        _showSnack(switch ((result.checkedIn, bidder)) {
          (true, final String number) =>
            'You\'ve joined ${action.title} and you\'re checked in. '
                'Your bidder number is $number.',
          (true, _) =>
            'You\'ve joined ${action.title} and you\'re '
                'checked in!',
          (false, final String number) =>
            'You\'ve joined ${action.title}. Your bidder number is '
                '$number.',
          (false, _) => 'You\'ve joined ${action.title}!',
        }, duration: bidder == null ? null : _bidderNumberSnackDuration);
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
            : 'Couldn\'t get an accurate position. Step outside or turn on '
                  'precise location, then try again from the auction page.',
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

  /// An `https://auction.fish/…` link opened from another app while the shell
  /// already exists. Same discipline as [_onShortcutTapped]: before the
  /// WebView is created the path stays pending so _initialUrl can use it as
  /// the landing page.
  void _onDeepLink() {
    if (_controller == null || DeepLinkService.instance.pending.value == null) {
      return;
    }
    final path = DeepLinkService.instance.consume();
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
      // A nudge that had to fall back to in-app UI may have been waiting for
      // this screen to be visible again.
      _drainDeferredCheckin();
      // Tell the backend this phone is awake again, so the website's "print
      // from my computer" state is right the moment the user looks at it.
      RemotePrintService.instance.onAppResumed(ref);
      unawaited(_rewarmConfigIfFailed());
      // A page that failed while the user was away is almost always a page
      // that failed because the network was down — and fixing the network
      // means leaving the app for Settings or Control Center, so coming back
      // is exactly the moment to try again. Without this the user returns to
      // the same dead banner and has to notice the Retry button; with it the
      // app is simply working when they look at it.
      if (_loadFailed) {
        ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
        unawaited(_controller?.reload() ?? Future<void>.value());
      }
      // Apple's requirement 1.5 asks for Tap to Pay to be prepared "at the
      // launch of your app **or when it comes to the foreground**". Both, here:
      // iOS tears the reader down while backgrounded, so a cashier who
      // switches away and comes back would otherwise be back to a cold
      // authorize at the moment they press the button. `prepare` no-ops when
      // the seller hasn't changed and the SDK is already authorized.
      unawaited(_warmSquare());
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

  /// What `voiceGetState` answers with — and the shape every voice handler
  /// resolves with, including the failures.
  ///
  /// **None of the voice handlers may ever throw.** A rejected `callHandler`
  /// promise is indistinguishable, on the page, from an app build that has no
  /// voice handlers at all: its catch says "Voice is not available on this
  /// phone", which is both wrong and unactionable. Anything that goes wrong
  /// here has to come back as a state map carrying an `error` the page can
  /// print instead.
  Future<Map<String, dynamic>> _voiceState({String? error}) async {
    try {
      final state = await VoiceCommandService.instance.state();
      return {...state, 'error': ?error};
    } on Object catch (e) {
      debugPrint('voiceGetState failed: $e');
      // Supported, because the failure was ours rather than the device's, and
      // a hidden button can't be retried.
      return {
        'supported': true,
        'listening': false,
        'error': error ?? 'Voice could not start. Try again.',
      };
    }
  }

  /// Read, or write then read, the operator's device-local voice settings.
  ///
  /// One method for both handlers because the answer is the same either way —
  /// what is now in force — and because a panel that had to reconcile a write
  /// response against a separate read would drift the moment one of them
  /// failed. Passing null reads; passing a map writes those fields and reads.
  ///
  /// Cannot throw, for the reason [_voiceState] gives: a rejected promise is
  /// read by the page as "this build has no voice handlers", which would hide
  /// the microphone button over a failed settings read.
  Future<Map<String, dynamic>> _voiceSettings([Object? changes]) async {
    try {
      return changes == null
          ? VoiceCommandService.instance.settingsState()
          : await VoiceCommandService.instance.updateSettings(changes);
    } on Object catch (e) {
      debugPrint('voiceSettings failed: $e');
      return {'error': 'Voice settings could not be saved.'};
    }
  }

  /// Begin a voice set-winners session for the auction the page names.
  ///
  /// The slug has to come from the page rather than being parsed out of the
  /// URL: the app would be guessing which auction a path belongs to, and the
  /// vocabulary it fetches decides which bidder numbers are legal answers.
  Future<Map<String, dynamic>> _startVoice(Object? args) async {
    final slug = _voiceSlugFrom(args);
    if (slug == null) {
      return _voiceState(error: 'This page didn\'t say which auction to use.');
    }
    try {
      await VoiceCommandService.instance.start(
        auctionSlug: slug,
        sink: _sendVoiceEvent,
      );
    } on Object catch (e) {
      debugPrint('voiceStart failed: $e');
      return _voiceState(error: 'Voice could not start. Try again.');
    }
    return _voiceState();
  }

  static String? _voiceSlugFrom(Object? args) {
    final slug = args is Map ? args['auction'] : args;
    final text = slug is String ? slug.trim() : '';
    return text.isEmpty ? null : text;
  }

  /// Push one event to the page's receiver.
  ///
  /// A push rather than a poll because the interesting events — a level meter
  /// at ~10 Hz, a partial transcript — are a stream, and because the page
  /// should be free to ignore what it doesn't understand. A missing receiver
  /// is not an error: it means the operator navigated away mid-session, which
  /// [_stopVoiceOnNavigation] then tidies up.
  void _sendVoiceEvent(Map<String, dynamic> event) {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    unawaited(
      controller
          .evaluateJavascript(
            source:
                'window.fishauctionsVoice && '
                'window.fishauctionsVoice.onEvent && '
                'window.fishauctionsVoice.onEvent(${jsonEncode(event)});',
          )
          .catchError((Object e) {
            debugPrint('Voice event delivery failed: $e');
            return null;
          }),
    );
  }

  /// Listening must not outlive the page that started it. The microphone stays
  /// open otherwise — with no visible control anywhere, since the button that
  /// would stop it just navigated away.
  void _stopVoiceOnNavigation() {
    if (VoiceCommandService.instance.isListening) {
      unawaited(VoiceCommandService.instance.stop());
    }
    if (DictationService.instance.isListening) {
      unawaited(DictationService.instance.stop());
    }
  }

  // ── Dictation bridge ──────────────────────────────────────────────────────

  /// The state map every dictation handler resolves with, failures included —
  /// same rule as [_voiceState]: a rejected `callHandler` promise is
  /// indistinguishable from a build with no dictation handlers at all, so the
  /// page would hide its microphone rather than say what went wrong.
  Future<Map<String, dynamic>> _dictationState({String? error}) async {
    try {
      final state = await DictationService.instance.state();
      return {...state, 'error': ?error};
    } on Object catch (e) {
      debugPrint('dictateGetState failed: $e');
      return {
        'supported': true,
        'listening': false,
        'error': error ?? 'Dictation could not start. Try again.',
      };
    }
  }

  Future<Map<String, dynamic>> _startDictation() async {
    try {
      await DictationService.instance.start(sink: _sendDictationEvent);
    } on Object catch (e) {
      debugPrint('dictateStart failed: $e');
      return _dictationState(error: 'Dictation could not start. Try again.');
    }
    return _dictationState();
  }

  /// Push one dictation event to the page's receiver. Deliberately a separate
  /// global from `fishauctionsVoice`: the command palette is a modal that
  /// opens *over* the set-winners page, so one receiver would mean the
  /// palette's transcripts arriving at the code that fills in bidder numbers.
  void _sendDictationEvent(Map<String, dynamic> event) {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    unawaited(
      controller
          .evaluateJavascript(
            source:
                'window.fishauctionsDictate && '
                'window.fishauctionsDictate.onEvent && '
                'window.fishauctionsDictate.onEvent(${jsonEncode(event)});',
          )
          .catchError((Object e) {
            debugPrint('Dictation event delivery failed: $e');
            return null;
          }),
    );
  }

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

  /// Warms Tap to Pay's reader because a page said it is about to be needed.
  ///
  /// Apple's 1.5 asks for the warm-up at launch/foreground and 5.6 wants the
  /// prompt on screen within a second; a resume can be hours before the charge,
  /// so the page that renders the pay button is the last honest moment. Which
  /// pages those are is the *server's* question — same rule as `tapToPayOffer`.
  ///
  /// Throttled because `prepare` re-fetches eligibility on every call and a
  /// page may call this on each HTMX re-render. Mount and resume are not
  /// throttled, which is what requirement 1.5 actually asks for.
  Future<bool> _warmTapToPayFromPage() async {
    final last = _lastPageWarm;
    final now = DateTime.now();
    if (last != null && now.difference(last) < _pageWarmInterval) {
      return false;
    }
    _lastPageWarm = now;
    await _warmSquare();
    return true;
  }

  /// When [_warmTapToPayFromPage] last ran, so a burst costs one warm-up.
  DateTime? _lastPageWarm;

  /// How long a page-triggered warm-up suppresses the next one. Comfortably
  /// longer than walking between invoices, far shorter than a checkout queue.
  static const _pageWarmInterval = Duration(minutes: 2);

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
    _loadFailed = false;
    _stopVoiceOnNavigation();
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
    _loadFailed = true;
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
              // Without offline data there is nothing to offer *instead*, so
              // the copy has to at least say where to look. "Can't reach the
              // server" on its own reads as "the site is down" and sends nobody
              // to their own Wi-Fi, which is the actual cause almost every
              // time. This is the state an ordinary bidder lands in — offline
              // snapshots only exist for an operator's own auction — so it is
              // the common case, not the edge one.
              : 'Can\'t reach the server. Check this phone\'s Wi-Fi or mobile '
                    'data, then try again.',
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
      if (current != null && current.path == arReturn.path) {
        // Consume first: a second back from the same page is normal web
        // history, and _launchAr sets this again if the user opens another lot.
        setState(() => _arReturn = null);
        await _launchAr(arReturn.slug, '${arReturn.lotPk}');
        return;
      }
      // Navigated away from the lot page lot scanning opened — drop it.
      setState(() => _arReturn = null);
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
      //
      // The message distinguishes "your iOS is too old" from "this iPhone will
      // never work", which is Apple's requirement 1.4: below the Tap to Pay
      // floor the app must tell the user to update iOS. Square reports both as
      // a single incapable-device answer, so the reason is resolved separately.
      TapToPayUnsupportedReason reason;
      try {
        reason = await TapToPayService.instance.unsupportedReason();
      } on Object {
        reason = TapToPayUnsupportedReason.device;
      }
      if (!reason.isSupported) {
        _showSnack(switch (reason) {
          TapToPayUnsupportedReason.osVersion =>
            'Update your iPhone to the latest version of iOS to use '
                '$tapToPayName (it needs an iPhone XS or later).',
          _ when Platform.isIOS => '$tapToPayName needs an iPhone XS or newer.',
          _ =>
            'This device can\'t take Tap to Pay — it needs NFC and Android 12 '
                'or newer.',
        });
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
    final method = resolved?.printMethod;
    if (method == PrintMethod.bluetooth) {
      await _printNatively(lotPks, prefs: resolved);
      return;
    }
    // A *batch* link exists only because the server rendered
    // `label_bluetooth_redirect.html`, which it does only for a user whose
    // `print_method` is bluetooth (`LotLabelView`'s
    // `bluetooth_deep_link_response`).
    // So when we couldn't read prefs at all — an offline or failed
    // `labels/prefs/` fetch — the server's answer is the better one. Reloading
    // on a null would be a loop, not a recovery: the page re-renders the same
    // handoff, its script clicks the same link, and the prefs fetch fails
    // again.
    if (method == null && lotPks.length > 1) {
      await _printNatively(lotPks, prefs: resolved);
      return;
    }
    if (lotPks.length == 1) {
      unawaited(context.push('/print/${lotPks.first}', extra: resolved));
      return;
    }
    // Prefs we *did* read say some other method, so the page was rendered
    // before the method changed. Reload it and the page renders its own PDF
    // button, which is the right answer for those methods — and this time the
    // server agrees, so there is no loop.
    _showSnack('Your label print method changed — reloading this page.');
    unawaited(_controller?.reload());
  }

  /// A data-only push arrived. Today that is only a remote print job; anything
  /// else is ignored rather than drawn, since a data message deliberately
  /// carries no notification block and has nothing to show.
  void _onPushData() {
    final data = PushService.instance.consumeDataMessage();
    if (data == null || !mounted) {
      return;
    }
    unawaited(
      RemotePrintService.instance.handlePushData(
        data,
        print: _printForRemoteJob,
      ),
    );
  }

  /// The phone half of a job started from a computer. Deliberately the same
  /// progress snackbar as a local print: someone standing next to the printer
  /// should be able to see why it started moving, and be able to stop it.
  ///
  /// Unlike `_printNatively` this reports *nothing* on completion — the person
  /// who asked for these labels is at the computer, watching the page, and
  /// `RemotePrintService` is already sending them the outcome. A second copy
  /// on the phone would be talking to the wrong room.
  Future<LabelPrintResult> _printForRemoteJob(List<int> lotPks) async {
    if (LabelPrintService.instance.isBusy) {
      return const LabelPrintResult(LabelPrintStatus.busy);
    }
    final messenger = ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(_printingSnack(lotPks.length));
    try {
      return await LabelPrintService.instance.printLots(lotPks, ref: ref);
    } finally {
      messenger.hideCurrentSnackBar();
    }
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
    Duration? duration,
  }) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
  }

  /// How long a message carrying a bidder number stays up. The default four
  /// seconds is a notification; this one is a thing to read off the screen and
  /// remember, in a noisy room, and it cannot be recalled once it goes.
  static const _bidderNumberSnackDuration = Duration(seconds: 12);

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
    if (uri.host != webHost) {
      return;
    }
    if (uri.path != '/login/') {
      // A page that rendered is proof the cookie session works, so the next
      // lapse is a new event rather than the same failed handoff looping.
      // Without this reset the repair below is a once-per-screen-lifetime
      // affair, and a shell that has been up for hours — through an OAuth
      // detour, a suspend, a network change — would sit showing the web login
      // form inside a signed-in app the second time a session lapsed.
      _handoffAttempts = 0;
      return;
    }
    // **Landing on /login/ is never a sign-out.** The JWT pair and the Django
    // session cookie are independent: the cookie can lapse (it expired, it was
    // cleared, this is a fresh WebView) while the native session is perfectly
    // alive. So re-mint the handoff and resume the page the user was actually
    // asking for; the web login form is never shown in-app, because a web-form
    // login would create a cookie session with no JWT behind it.
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

  void _onTitleTap() => unawaited(_openCommandPalette());

  /// Open the command palette — the website's own, if the page in the WebView
  /// has it.
  ///
  /// The web palette is the real one: natural-language assist with a language
  /// model behind it, streamed progress, a confirm countdown, clarifying
  /// questions and the telemetry that feeds the analytics page. Re-implementing
  /// that natively would be a second copy of a feature that changes weekly, and
  /// it would drift — which is the general rule in this app: business logic
  /// lives on the web side, the app supplies the hardware (here, the
  /// microphone, over the `dictate*` bridge).
  ///
  /// [showCommandPalette] stays as the fallback and is not dead code: the JS
  /// returns false whenever the palette isn't there — a deployment that hasn't
  /// un-hidden it yet, a page that failed to load, offline — and the native
  /// palette works in all of those, since it goes over the JWT API rather than
  /// the page.
  Future<void> _openCommandPalette() async {
    if (await _showWebCommandPalette()) {
      return;
    }
    if (!mounted) {
      return;
    }
    await showCommandPalette(
      context,
      _loadPath,
      // AR is a native screen, not a web path — the palette's locally injected
      // AR entry routes through the same push+return flow as the deep link.
      onOpenAr: (slug) => unawaited(_launchAr(slug, null)),
      // Likewise native. This is also the one route to Tap to Pay setup that
      // works before the backend serves `payments/authorization/` — the drawer
      // tile and the awareness modal both wait on that answer.
      onOpenTapToPay: () => unawaited(context.push('/tap-to-pay')),
    );
  }

  /// Show the page's own palette modal, reporting whether it was there.
  ///
  /// Bootstrap is what the site already uses for this modal, and the keyboard
  /// shortcut that normally opens it (Ctrl+K) is unreachable on a phone — so
  /// the app bar's title is the app's equivalent, and it has to reach the same
  /// modal rather than a copy of it.
  Future<bool> _showWebCommandPalette() async {
    final controller = _controller;
    if (controller == null) {
      return false;
    }
    try {
      final shown = await controller.evaluateJavascript(
        source:
            '(function () {'
            '  var el = document.getElementById("command-palette-modal");'
            '  if (!el || !window.bootstrap) { return false; }'
            '  bootstrap.Modal.getOrCreateInstance(el).show();'
            '  return true;'
            '})();',
      );
      // Both platforms have been known to hand back the string "true" rather
      // than a bool, depending on how the engine serializes the result.
      return shown == true || shown == 'true';
    } on Object catch (e) {
      debugPrint('Web command palette unavailable: $e');
      return false;
    }
  }

  // ── Navigation, downloads, permissions, bridges ───────────────────────────

  /// Remove the Web Speech API from every page, at document start.
  ///
  /// **Android's System WebView defines `webkitSpeechRecognition` and cannot
  /// use it.** The binding is part of Blink so it's exposed, but WebView never
  /// wires it to a recognition service, and [_onPermissionRequest] denies the
  /// page's microphone outright besides — so `start()` fires an immediate
  /// `error` and nothing else ever happens. The object exists; the feature does
  /// not.
  ///
  /// That broke the command palette's microphone in exactly the way a stub
  /// does: the page feature-detects `window.SpeechRecognition ||
  /// window.webkitSpeechRecognition`, finds it, believes it, and never reaches
  /// the `dictate*` bridge that actually works here. The button appeared and
  /// tapping it did nothing — no prompt, no transcript, no error text, because
  /// a failed `start()` only un-presses the button.
  ///
  /// Deleting the globals makes the app's environment *honest*, so that
  /// feature detection reaches the right answer with no app-specific knowledge:
  /// any page asking "does this browser do speech recognition?" is now
  /// correctly told no, and can fall back — to the bridge, to a typed input, to
  /// whatever it likes. Fixing only the palette's branch order would leave the
  /// next page that asks the same question with the same broken answer.
  ///
  /// iOS is unaffected — `WKWebView` has never shipped the API, so this is a
  /// no-op there and the fallback path was always taken.
  static final _hideWebSpeechApi = UserScript(
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    source: '''
(function () {
  ['SpeechRecognition', 'webkitSpeechRecognition',
   'SpeechGrammarList', 'webkitSpeechGrammarList'].forEach(function (name) {
    try {
      delete window[name];
      if (window[name]) {
        // Non-configurable on some builds; shadow it instead.
        Object.defineProperty(window, name, {value: undefined, configurable: true});
      }
    } catch (e) { /* nothing else to try; the page falls back either way */ }
  });
})();
''',
  );

  /// Catch the website's own sign-out **submission**, at document start.
  ///
  /// The two sessions have to stay in lockstep: a web sign-out that left the
  /// JWT pair alive would leave the app signed in, and the shell would
  /// cheerfully re-mint a web session on the next `/login/` bounce and sign the
  /// user straight back in.
  ///
  /// It has to be the submission and not the URL, though. `/logout/` on a GET
  /// is allauth's *confirmation page*, so treating a navigation there as a
  /// sign-out signs people out for merely visiting the URL — and everything
  /// that ends up there by accident (a stale link, a redirect chain, a
  /// mistyped path) becomes a sign-out. The POST is the user actually saying
  /// yes, and it is what both the navbar's button and that confirmation page
  /// submit.
  ///
  /// In JS rather than in `shouldOverrideUrlLoading` because Android's WebView
  /// makes no promise about surfacing a POST navigation there at all; the
  /// native check remains as a fallback for the case where this script didn't
  /// run.
  static final _webLogoutHook = UserScript(
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    source: '''
(function () {
  function isLogout(form) {
    try {
      var action = form.getAttribute('action') || window.location.href;
      return new URL(action, window.location.href).pathname === '/logout/';
    } catch (e) { return false; }
  }
  document.addEventListener('submit', function (e) {
    var form = e.target;
    if (!form || form.tagName !== 'FORM' || !isLogout(form)) { return; }
    e.preventDefault();
    e.stopPropagation();
    try {
      window.flutter_inappwebview.callHandler('webLogout');
    } catch (err) {
      // No bridge (an older build): let the form go through, so the web half
      // signs out even if the native half can't be told.
      form.submit();
    }
  }, true);
})();
''',
  );

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

    // mailto:/tel:/sms: aren't navigations — they're handoffs to the mail,
    // phone or messaging app, and a browser honours them. Cancelling them
    // along with everything non-http is what made every "Email" button on the
    // site (auction contact, club contact, "Email all users", the speaker
    // panel) do nothing at all when tapped.
    if (isHandoffScheme(uri)) {
      await _openExternally(uri);
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
      // Not awaited: this navigation is cancelled either way, and a connect
      // flow keeps `_openExternally` on the stack for as long as the user is
      // in the authentication session — minutes, on an OAuth consent screen.
      // WKWebView holds its decision handler open until this returns.
      unawaited(_openExternally(uri));
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

    // A connect flow's launcher (/square/connect/, /paypal/connect/,
    // /mailchimp/connect/<club>/, /google-calendar/connect/<club>/) never
    // renders anything: it stashes the club slug and a CSRF nonce in the
    // Django session and 302s to the provider. Letting it run here is the bug
    // — the state lands in the *shell's* session while the provider's callback
    // comes back into the authentication session's, so the callback dies on
    // "your connection session expired" no matter who is signed in. Divert it
    // before it navigates, so one session holds the whole round trip.
    if (startsConnectFlowInShell(uri) && action.isForMainFrame) {
      unawaited(_openExternally(uri));
      return NavigationActionPolicy.CANCEL;
    }

    // **A GET of /logout/ is not a sign-out.** allauth renders a confirmation
    // page there, so intercepting the GET signed people out for merely
    // visiting the URL — a link, a redirect, a mistyped path. The real signal
    // is the POST that page (and the navbar's own sign-out button) submits,
    // which `_webLogoutHook` catches in JS on both platforms; this is the
    // native belt to that braces, for a POST navigation that reaches here
    // without the script having run.
    if (uri.path == '/logout/') {
      final isPost = (action.request.method ?? 'GET').toUpperCase() == 'POST';
      if (isPost && ref.read(authProvider).value != null) {
        unawaited(_signOut());
        return NavigationActionPolicy.CANCEL;
      }
      return NavigationActionPolicy.ALLOW;
    }

    // Account deletion is the other real sign-out signal. It ends by logging
    // the web session out server-side and redirecting through /logout/ to this
    // page, so arriving here still natively signed in means the deletion POST
    // went through — and leaving the app sitting on a signed-in shell for an
    // account on its way out is exactly what the backend's redirect is asking
    // us to prevent. Safe to key on because it is a terminal confirmation page
    // with nothing linking to it: unlike /logout/, you do not pass through it
    // by accident. The navigation is allowed so it renders for the moment
    // before the router swaps the screen out.
    final deleted = uri.path == '/account/deleted/';
    if (deleted && ref.read(authProvider).value != null) {
      unawaited(_signOut());
      return NavigationActionPolicy.ALLOW;
    }

    return NavigationActionPolicy.ALLOW;
  }

  /// `target="_blank"` / `window.open` — routed out of the shell rather than
  /// opened as a nested WebView window. Connect flows go to the authentication
  /// session (the Discord bot invite arrives here, and so do the seller-connect
  /// banners that carry target="_blank" precisely to escape a WebView that
  /// cannot run the provider's login); everything else — the Google Wallet
  /// save URL, map links — goes to the system browser. Returning false tells
  /// the engine not to create the window.
  Future<bool> _onCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    final uri = action.request.url;
    if (uri != null) {
      // Not awaited — see the note in _shouldOverrideUrlLoading. The engine
      // needs its answer now; a connect flow finishes whenever the user does.
      unawaited(_openExternally(uri));
    }
    return false;
  }

  Future<void> _openExternally(Uri uri) async {
    // A connect flow — Square, PayPal, Mailchimp, Google Calendar, Discord —
    // is the one kind of off-host trip that must not leave the app, and must
    // not leave the app's session behind either. `ConnectFlowService` opens it
    // in an authentication session with a freshly minted Django session
    // already inside; `utils/connect_flows.dart` explains why both halves are
    // necessary. Everything else still goes to the system browser: map links,
    // the Google Wallet save URL, arbitrary links in user-authored lot
    // descriptions.
    final isConnect = runsInAuthSession(uri);
    // Resolved once, up front: the handoff minted here is reused by the
    // browser-view fallback below rather than re-minted, because the first
    // token was never consumed and burning a second would be pointless.
    final target = isConnect
        ? await ConnectFlowService.instance.resolve(uri)
        : uri;
    if (isConnect && await _runConnectFlow(target)) {
      return;
    }
    // Apple's Tap to Pay review guide requires a merchant to be able to
    // onboard "without needing other apps" (General Requirements) and calls
    // for "a fully digital onboarding experience within the app ... fully
    // completed on an iPhone" (requirement 2.2), so a connect flow that could
    // not run in the authentication session falls back to an in-app browser
    // view rather than Safari. That view shares Safari's cookie jar, so a
    // merchant whose Square login is "Sign in with Google" still works —
    // Google blocks its sign-in inside embedded WebViews, which is why this is
    // never the shell's own WebView.
    final mode = isConnect
        ? LaunchMode.inAppBrowserView
        : LaunchMode.externalApplication;
    try {
      final launched = await launchUrl(target, mode: mode);
      if (!launched) {
        _showSnack('Couldn\'t open the link.');
      }
    } on Object {
      _showSnack('Couldn\'t open the link.');
    }
  }

  /// Runs a connect round trip in the authentication session, returning
  /// whether it handled the flow.
  ///
  /// `ASWebAuthenticationSession` (Chrome's Auth Tab on Android) is what an
  /// OAuth round trip is supposed to use: it presents a Safari-backed view —
  /// same cookie jar, so a provider login that goes through Google SSO still
  /// works — and *dismisses itself* when the redirect matches the callback
  /// scheme. A plain browser view can do neither.
  ///
  /// **A dismissal is not a failure and is never reported as one.** Only
  /// Square currently ends with a `fishauctions-oauth://` redirect; Mailchimp,
  /// PayPal and Google Calendar succeed and then leave the user on one of our
  /// web pages with the sheet open, which they close with Done — and the
  /// platform reports that to us as a user cancellation. It cannot be told
  /// apart from a genuine mid-flow back-out, and both mean the same thing: the
  /// user
  /// has returned and only the server knows whether anything changed. So both
  /// endings do the same thing — reload the page behind and re-warm the
  /// reader — and say nothing.
  ///
  /// Returns false only when the session could not start at all (an older
  /// platform, a build without the plugin), leaving the caller to fall through
  /// to the browser view.
  Future<bool> _runConnectFlow(Uri resolvedUrl) async {
    final outcome = await ConnectFlowService.instance.openResolved(resolvedUrl);
    if (outcome == ConnectFlowOutcome.unavailable) {
      return false;
    }
    if (!mounted) {
      return true;
    }
    // A connect flow can outlive the 60-minute access token, and it ends in a
    // burst of API calls; letting the shell re-mint its web session lets a
    // page that comes back at /login/ be repaired rather than sat on.
    _handoffAttempts = 0;
    // The merchant may have just connected Square, so the page behind this is
    // stale and the reader's credentials may be new.
    unawaited(_warmSquare());
    unawaited(_controller?.reload() ?? Future<void>.value());
    return true;
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
      case 'tap-to-pay':
        // fishauctions://tap-to-pay — the native setup/education screen. It
        // exists as a link so the website's command palette can offer it: the
        // palette runs in the WebView now (it is where the language model and
        // the assist UI live), and a native screen is not something the server
        // can hand back as a URL. Same reason `ar` is a link rather than a
        // path.
        //
        // iOS only, and the guard is load-bearing rather than tidy. That
        // screen is Apple's flow end to end — its terms sheet, its education
        // sheet, and copy that says "Tap to Pay on iPhone" throughout — which
        // is why the drawer tile and the app's own palette row are both gated
        // on `isApplePlatform`. This entry point wasn't, and the server offers
        // the row to any mobile client (it varies only the label), so tapping
        // it on Android opened an iPhone setup screen that then asked an
        // uninitialized Square SDK for its authorization state and killed the
        // process. Android takes cards from the invoice page's own button; it
        // has no terms to accept and nothing to set up here.
        if (TapToPayService.instance.isApplePlatform) {
          unawaited(context.push('/tap-to-pay'));
        } else {
          _showSnack(
            'Open the invoice you want to collect and use the card button '
            'there to take a payment on this phone.',
          );
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
    if (result is ArLotPageRequest && mounted) {
      // Remember the AR origin so a back from this lot page returns to lot
      // scanning, aimed at this lot (the page's own "Back to scanning" bar
      // does the same thing by deep link).
      //
      // Keyed on the *path* we are about to load, not on the `?src=ar` marker
      // that put it there: `base_page_view.html` runs a `history.replaceState`
      // on every page load that strips `src` (and `uid`) from the URL, so by
      // the time the user can press anything the marker is gone. Matching on
      // it meant this whole path was dead in practice and back went wherever
      // the user had been before lot scanning.
      setState(
        () => _arReturn = (
          slug: auctionSlug,
          lotPk: result.lotPk,
          path: Uri.parse(result.path).path,
        ),
      );
      _loadPath(result.path);
    }
    // Back on the shell: anything a nudge couldn't put in the notification
    // tray has been waiting for exactly this.
    _drainDeferredCheckin();
  }

  // The router only mounts this screen for a signed-in session, so the drawer
  // always shows the full account menu — there is no signed-out variant
  // (signed-out users live on the login/signup screens).
  //
  // The rows themselves are **the server's**, from the `menu` block of
  // `/api/mobile/config/` (BACKEND_SPEC.md Part MENU). This used to be a
  // hand-written mirror of base.html's navbar, which meant every navbar change
  // needed an app release to follow — fifteen of them in the last year — and
  // the copy was lossy anyway, missing the superuser Admin menu and "About
  // site" because who may see those is a server question. `MenuStore` resolves
  // server payload > last-good persisted payload > bundled skeleton, and is a
  // ChangeNotifier because config is fetched off the startup critical path and
  // routinely lands after the drawer has already been built.
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
            child: ListenableBuilder(
              listenable: MenuStore.instance,
              builder: (_, _) => ListView(
                padding: EdgeInsets.zero,
                children: _drawerRows(ctx, MenuStore.instance.menu),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  /// The whole drawer body: the server's sections with the app's own rows
  /// merged in at their anchors (see [DrawerMenu.withNativeRows]).
  List<Widget> _drawerRows(BuildContext ctx, DrawerMenu menu) {
    final rows = <Widget>[];
    final sections = menu.withNativeRows();
    for (var i = 0; i < sections.length; i++) {
      final section = sections[i];
      if (i > 0) {
        rows.add(const Divider());
      }
      if (section.collapsed) {
        // The navbar's dropdowns (About, and the superuser Admin menu, which
        // is a dozen links) — collapsed here too, or they bury everything.
        rows.add(
          ExpansionTile(
            leading: section.icon.isEmpty ? null : Icon(biIcon(section.icon)),
            title: Text(section.title),
            childrenPadding: EdgeInsets.zero,
            children: [
              for (final entry in section.entries)
                _drawerEntry(ctx, entry, indent: true),
            ],
          ),
        );
        continue;
      }
      if (section.title.isNotEmpty) {
        rows.add(_sectionHeader(ctx, section.title));
      }
      for (final entry in section.entries) {
        rows.add(_drawerEntry(ctx, entry));
      }
    }
    return rows;
  }

  /// One merged row. A native entry hands off to the widget that owns it —
  /// each of those does its own gating and its own live rebuilding, which is
  /// exactly why the server can neither send nor position them.
  Widget _drawerEntry(
    BuildContext ctx,
    DrawerEntry entry, {
    bool indent = false,
  }) => switch (entry) {
    DrawerLinkEntry(:final item) => _navTile(
      ctx,
      // An indented sub-row deliberately keeps no icon even when the payload
      // names one: it sits under its section's icon, and a second column of
      // glyphs inside an expanded tile reads as noise.
      indent || item.icon.isEmpty ? null : biIcon(item.icon),
      item.title,
      item.path,
      indent: indent,
    ),
    DrawerNativeEntry(:final row) => switch (row) {
      DrawerNativeRow.offlineMode => _offlineModeTile(ctx),
      DrawerNativeRow.clubs => _clubsTile(ctx),
      DrawerNativeRow.tapToPay => _tapToPayTile(ctx),
      DrawerNativeRow.signOut => _signOutTile(ctx),
    },
  };

  /// Sign out is app-owned and unconditional. It tears down a native session
  /// — the JWT pair, the WebView cookie jar, the cached profile, the offline
  /// files, the persisted drawer menu and the Square authorization — so it is
  /// never a row the server sends, and never a row a bad payload can remove.
  Widget _signOutTile(BuildContext ctx) => ListTile(
    leading: const Icon(Icons.logout),
    title: const Text('Sign out'),
    onTap: () {
      Navigator.of(ctx).pop();
      unawaited(_signOut());
    },
  );

  /// The drawer's Tap to Pay entry — setup, status and merchant education.
  ///
  /// Apple's review guide requires both that enablement be reachable outside
  /// the awareness and checkout flows ("such as through your app settings",
  /// requirement 3.6) and that merchant education live somewhere permanent
  /// like Settings or Help (4.3). This tile is that route.
  ///
  /// iOS-only, and hidden for users the backend says aren't merchants — the
  /// guide's own advice for an app with a mixed consumer/merchant user base is
  /// to limit the feature to the appropriate user type. Bidders (nearly all of
  /// this app's users) never see it. While eligibility is still unknown the
  /// tile stays hidden rather than flickering in: the shell fetches it at
  /// mount, so "unknown" here means the answer is seconds away or the
  /// deployment doesn't serve it at all.
  Widget _tapToPayTile(BuildContext ctx) {
    if (!TapToPayService.instance.isApplePlatform) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<TapToPayEligibility?>(
      valueListenable: TapToPayService.instance.eligibility,
      builder: (_, eligibility, _) {
        if (eligibility == null || !eligibility.eligible) {
          return const SizedBox.shrink();
        }
        return ListTile(
          // Deliberately not a contactless glyph: requirement 5.5 allows only
          // SF Symbols' wave.3.right.circle on a Tap to Pay control, and the
          // marketing rules forbid any icon depicting the capability, so a
          // Material lookalike beside this label is exactly what they bar. A
          // storefront reads as "merchant tools" and depicts nothing. See
          // tap_to_pay_branding.dart.
          leading: const Icon(Icons.storefront_outlined),
          title: const Text(tapToPayName),
          onTap: () {
            Navigator.of(ctx).pop();
            context.push('/tap-to-pay');
          },
        );
      },
    );
  }

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
        // `secondary`, not `primary`: the latter is the web's btn-primary fill
        // and is unreadable as ink on the page background. See AppTheme.
        color: Theme.of(ctx).colorScheme.secondary,
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
          leading: (_canGoBack || _arReturn != null)
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
                initialUserScripts: UnmodifiableListView([
                  _hideWebSpeechApi,
                  _webLogoutHook,
                ]),
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
