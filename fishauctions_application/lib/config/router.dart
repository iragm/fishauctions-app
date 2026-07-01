import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/login_screen.dart';
import '../screens/print_label_screen.dart';
import '../screens/printer_screen.dart';
import '../screens/webview_screen.dart';
import '../services/api_service.dart';

/// Routes that hit the JWT-backed mobile API and therefore require a native
/// sign-in first. (Payment is launched as a modal over the WebView, not a
/// route — its sign-in gate lives in WebViewScreen._launchPayment.)
bool _requiresAuth(String location) => location.startsWith('/print/');

final routerProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    initialLocation: '/',
    redirect: (context, state) async {
      final location = state.matchedLocation;
      if (!_requiresAuth(location)) {
        return null;
      }
      // Presence of tokens is enough to enter; the API client refreshes or
      // surfaces a 401 from there. No tokens at all → sign in first.
      if (await ApiService.instance.hasTokens) {
        return null;
      }
      final from = Uri.encodeQueryComponent(state.uri.toString());
      return '/login?from=$from';
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const WebViewScreen(),
        routes: [
          GoRoute(
            path: 'settings/printer',
            builder: (context, state) => const PrinterScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) =>
            LoginScreen(from: state.uri.queryParameters['from']),
      ),
      GoRoute(
        path: '/print/:lotPk',
        builder: (context, state) =>
            PrintLabelScreen(lotPk: int.parse(state.pathParameters['lotPk']!)),
      ),
    ],
  ),
);
