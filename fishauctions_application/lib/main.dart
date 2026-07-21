import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/router.dart';
import 'config/theme.dart';
import 'constants/app_constants.dart';
import 'services/shortcut_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Android 15+ forces edge-to-edge (the system bars can't be made opaque), so
  // the bars are transparent by design — the app reserves space for them with
  // SafeArea instead. Light icons keep the nav/status buttons legible over the
  // app's always-dark UI.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // Register the home-screen quick actions before the first frame so a cold
  // start *from* a shortcut has its handler in place; never blocks launch.
  unawaited(ShortcutService.instance.init());
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
