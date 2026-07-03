import 'package:flutter/material.dart';

/// Shown by the router while the launch-time session restore resolves, so a
/// signed-in user never sees the login screen flash before landing on the
/// WebView shell. Plain and dark — it's on screen for well under a second on
/// a healthy network.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
