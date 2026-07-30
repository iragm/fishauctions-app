import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/config_provider.dart';

/// The terms / privacy-policy links, shown wherever an account gets created.
///
/// Apple requires an app with account registration to link its terms and
/// privacy policy from inside the app, at the point of sign-up — not only from
/// the App Store listing. The web signup template carries neither, and the
/// app's WebView drops the site chrome (where the footer link lives) for the
/// mobile user agent, so these links exist natively.
///
/// Both destinations come from `/api/mobile/config/` so a fork points at its own
/// documents; terms falls back to the site's long-standing `/tos/`. A
/// deployment with no privacy policy published shows only the terms link rather
/// than a dead one — see `AppConfig.hasPrivacyPolicy`.
///
/// They open in the same restricted WebView the account flows use
/// (`AllauthWebScreen.legal` via `/legal/...`), so a signed-out user reading the
/// terms is still inside the login trap and can't wander into the site.
class LegalLinks extends ConsumerWidget {
  const LegalLinks({this.padding = const EdgeInsets.only(top: 8), super.key});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Config may still be loading or have failed (offline first run) — terms
    // has a compile-time default, so there is always at least one link.
    final config = ref.watch(configProvider).value;
    final hasPrivacy = config?.hasPrivacyPolicy ?? false;
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: padding,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(
            onPressed: () => context.push('/legal/terms'),
            child: Text('Terms and Conditions', style: style),
          ),
          if (hasPrivacy)
            TextButton(
              onPressed: () => context.push('/legal/privacy'),
              child: Text('Privacy Policy', style: style),
            ),
        ],
      ),
    );
  }
}
