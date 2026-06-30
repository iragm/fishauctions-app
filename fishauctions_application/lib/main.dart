import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/router.dart';
import 'config/theme.dart';
import 'constants/app_constants.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: FishAuctionsApp()));
}

class FishAuctionsApp extends ConsumerWidget {
  const FishAuctionsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: AppConstants.appName,
      routerConfig: router,
      // The WebView content is forced-dark, so the native chrome is dark too,
      // always — never follow the system light/dark setting (that would put a
      // light shell around a dark page).
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
    );
  }
}
