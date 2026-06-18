import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/payment_screen.dart';
import '../screens/printer_screen.dart';
import '../screens/webview_screen.dart';

final routerProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    initialLocation: '/',
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
        path: '/pay/:invoicePk',
        builder: (context, state) => PaymentScreen(
          invoicePk: int.parse(state.pathParameters['invoicePk']!),
        ),
      ),
    ],
  ),
);
