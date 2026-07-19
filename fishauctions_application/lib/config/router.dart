import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../screens/allauth_web_screen.dart';
import '../screens/ar_lots_screen.dart';
import '../screens/login_screen.dart';
import '../screens/offline_add_lots_screen.dart';
import '../screens/offline_add_user_screen.dart';
import '../screens/offline_set_winners_screen.dart';
import '../screens/offline_users_screen.dart';
import '../screens/print_label_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/webview_screen.dart';

/// The screens an anonymous user is allowed on. Everything else requires an
/// account — the app has no anonymous browsing, so the redirect below traps
/// signed-out users on these until they sign in.
const _gateLocations = {'/login', '/signup', '/password-reset'};

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
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final location = state.matchedLocation;
      // Only the launch-time session restore is ever loading (login attempts
      // keep their previous state); park on the splash screen until it
      // resolves so the login screen doesn't flash for signed-in users.
      if (auth.isLoading) {
        return location == '/splash' ? null : '/splash';
      }
      final signedIn = auth.valueOrNull != null;
      final onGate = _gateLocations.contains(location);
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
      GoRoute(
        path: '/print/:lotPk',
        builder: (context, state) =>
            PrintLabelScreen(lotPk: int.parse(state.pathParameters['lotPk']!)),
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
