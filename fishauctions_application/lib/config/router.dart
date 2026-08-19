import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/app_config.dart';
import '../models/label_prefs.dart';
import '../providers/auth_provider.dart';
import '../providers/config_provider.dart';
import '../screens/allauth_web_screen.dart';
import '../screens/ar_lots_screen.dart';
import '../screens/login_screen.dart';
import '../screens/offline_add_lots_screen.dart';
import '../screens/offline_add_user_screen.dart';
import '../screens/offline_set_winners_screen.dart';
import '../screens/offline_users_screen.dart';
import '../screens/print_label_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/tap_to_pay_screen.dart';
import '../screens/webview_screen.dart';
import '../services/deep_link_service.dart';

/// The sign-in gate: the screens an anonymous user is allowed on, and — because
/// they exist only to get an account — the screens a *signed-in* user is
/// redirected away from. Everything else requires an account; the app has no
/// anonymous browsing.
const _gateLocations = {
  '/login',
  '/signup',
  '/password-reset',
  // Reached from the login screen mid-sign-in, so it belongs in the trap: the
  // user is signed out until the pending token is exchanged, and a signed-in
  // user has no business here.
  '/social-continue',
};

/// Screens that work in either state, so the redirect leaves them alone both
/// ways. The terms and privacy pages have to be readable at the point of
/// account creation (an App Store requirement, and necessarily before there is
/// an account) *and* afterwards, so they can't live in [_gateLocations] — that
/// would eject a signed-in reader back to wherever they came from.
const _publicLocations = {'/legal/terms', '/legal/privacy'};

/// The web path behind `/legal/terms` / `/legal/privacy`, from the deployment
/// config. Read (not watched) at route-build time: the pages are pushed by a
/// tap, by which point config is long warm, and the terms path has a
/// compile-time default for the case where it isn't. A deployment with no
/// privacy policy has no link to this route in the first place
/// (`AppConfig.hasPrivacyPolicy`), so the empty-string fallback is unreachable
/// rather than a broken page.
String _legalPath(Ref ref, {required bool terms}) {
  final config = ref.read(configProvider).value;
  return terms
      ? (config?.termsPath ?? AppConfig.defaultTermsPath)
      : (config?.privacyPath ?? '');
}

/// Only allow returning to in-app paths, never an attacker-supplied scheme.
String _safeFrom(String? from) {
  if (from != null && from.startsWith('/') && !from.startsWith('//')) {
    return from;
  }
  return '/';
}

final routerProvider = Provider<GoRouter>((ref) {
  // Re-run the redirect whenever auth changes: the initial session restore
  // resolving, sign-in, sign-out, or a mid-session token death.
  final refresh = ValueNotifier(0);
  ref
    ..listen(authProvider, (_, _) => refresh.value++)
    ..onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    // Anything that matched no route and wasn't a site link (a deep link for
    // another host, a mistaken push) goes home rather than to go_router's
    // default error page, which in a release build is a red screen with a
    // stack trace and no way back.
    onException: (context, state, router) {
      debugPrint('No route for ${state.uri}; going home');
      router.go('/');
    },
    redirect: (context, state) {
      // An OS deep link — an Android App Link or an iOS Universal Link —
      // arrives as an *absolute* URL pushed into the router, and there is no
      // app route for `https://auction.fish/lots/123`. Park it for the shell
      // and carry on as if the app had been opened normally: signed in that
      // lands on `/` and the shell loads it; signed out it goes through the
      // login trap and the link is still waiting afterwards.
      //
      // This has to happen in `redirect` rather than only in [onException],
      // because the top-level redirect runs on an *error* match list too — so
      // a signed-out deep link would be turned into `/login?from=<absolute
      // url>` and never reach the exception handler at all, and `_safeFrom`
      // (rightly) refuses a non-relative `from`.
      if (DeepLinkService.instance.offer(state.uri)) {
        return '/';
      }
      final auth = ref.read(authProvider);
      final location = state.matchedLocation;
      // Only the launch-time session restore is ever loading (login attempts
      // keep their previous state); park on the splash screen until it
      // resolves so the login screen doesn't flash for signed-in users.
      if (auth.isLoading) {
        return location == '/splash' ? null : '/splash';
      }
      final signedIn = auth.value != null;
      final onGate = _gateLocations.contains(location);
      if (_publicLocations.contains(location)) {
        return null;
      }
      if (!signedIn) {
        if (onGate) {
          return null;
        }
        // Remember where the user was so sign-in returns them there (matters
        // for a mid-session sign-out on a native screen, e.g. /print/…).
        final from = Uri.encodeQueryComponent(state.uri.toString());
        return location == '/splash' ? '/login' : '/login?from=$from';
      }
      if (onGate || location == '/splash') {
        return _safeFrom(state.uri.queryParameters['from']);
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      // Printing is configured on the /printing/ web page (its Bluetooth card
      // opens the native connect sheet via the JS bridge) — there is no
      // standalone native printer-settings route.
      GoRoute(path: '/', builder: (context, state) => const WebViewScreen()),
      // ?from= is consumed by the redirect above (post-sign-in return), not
      // by the screen.
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/signup',
        builder: (context, state) => const AllauthWebScreen.signup(),
      ),
      GoRoute(
        path: '/password-reset',
        builder: (context, state) => const AllauthWebScreen.passwordReset(),
      ),
      // The deployment's terms and privacy policy, in the same restricted
      // WebView as the account flows (a signed-out reader must not be able to
      // wander into the site from here). Paths come from
      // `/api/mobile/config/`, so a fork points at its own documents; terms
      // falls back to the site's `/tos/`.
      // Finishing a native social sign-in that needs an email address or a
      // confirmation — allauth's own flow, hosted like signup is. Pops `true`
      // when the server lands on the completion path; the login screen then
      // exchanges its pending token. `url` is the backend's `continue_url`.
      GoRoute(
        path: '/social-continue',
        builder: (context, state) => AllauthWebScreen.socialContinue(
          initialPath: state.uri.queryParameters['url'] ?? '/social/signup/',
        ),
      ),
      GoRoute(
        path: '/legal/terms',
        builder: (context, state) => AllauthWebScreen.legal(
          title: 'Terms and Conditions',
          initialPath: _legalPath(ref, terms: true),
        ),
      ),
      GoRoute(
        path: '/legal/privacy',
        builder: (context, state) => AllauthWebScreen.legal(
          title: 'Privacy Policy',
          initialPath: _legalPath(ref, terms: false),
        ),
      ),
      // The PDF/System print methods only. Bluetooth printing has no screen —
      // the shell runs it in the background over the page the user was on
      // (LabelPrintService), because a label print needs no confirmation.
      GoRoute(
        path: '/print/:lotPk',
        builder: (context, state) => PrintLabelScreen(
          lotPk: int.parse(state.pathParameters['lotPk']!),
          // The shell passes the prefs it already fetched; anything else
          // (a direct route) leaves the screen to fetch its own.
          prefs: state.extra is LabelPrefs ? state.extra! as LabelPrefs : null,
        ),
      ),
      // Tap to Pay setup, status and merchant education. Reached from the
      // drawer and from the awareness moment. Apple's review guide requires
      // enablement and education to be reachable outside the checkout flow
      // (requirements 3.6 and 4.3), which is what this route is for.
      GoRoute(
        path: '/tap-to-pay',
        builder: (context, state) => const TapToPayScreen(),
      ),
      // AR lot mode — reached via the web's fishauctions://ar/<slug> deep
      // links (auction rules page; lot pages add ?locate=<pk>). Pops with a
      // web path for the shell to load when the user opens a lot page.
      GoRoute(
        path: '/ar/:auctionSlug',
        builder: (context, state) => ArLotsScreen(
          auctionSlug: state.pathParameters['auctionSlug']!,
          locateLotPk: int.tryParse(state.uri.queryParameters['locate'] ?? ''),
        ),
      ),
      // Offline auction management — native mirrors of the web users /
      // add-lots / set-winners pages, running entirely from the local
      // snapshot of the operator's last admin auction (BACKEND_SPEC.md
      // Part 4). Reached from the drawer and the WebView's can't-reach-
      // the-server banner.
      GoRoute(
        path: '/offline',
        builder: (context, state) => const OfflineUsersScreen(),
      ),
      GoRoute(
        path: '/offline/add-user',
        builder: (context, state) => const OfflineAddUserScreen(),
      ),
      GoRoute(
        path: '/offline/add-lots/:userKey',
        builder: (context, state) =>
            OfflineAddLotsScreen(userKey: state.pathParameters['userKey']!),
      ),
      GoRoute(
        path: '/offline/set-winners',
        builder: (context, state) => const OfflineSetWinnersScreen(),
      ),
    ],
  );
});
