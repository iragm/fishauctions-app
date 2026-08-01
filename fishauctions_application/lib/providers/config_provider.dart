import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_config.dart';
import '../models/social_provider.dart';
import '../services/config_service.dart';
import '../services/social_auth_service.dart';

/// Deployment config from `GET /api/mobile/config/`, loaded once and cached by
/// [ConfigService]. Read `ref.read(configProvider.future)` to await it (e.g.
/// warming the Square SDK) or watch it in the UI.
final configProvider = FutureProvider<AppConfig>(
  (ref) => ConfigService.instance.load(),
);

/// The social sign-in buttons to show, in order, for this deployment and
/// device — empty when none are configured or the config hasn't loaded.
///
/// A provider rather than a field on the login screen because deciding it is
/// asynchronous twice over: it needs the deployment config, and Apple's
/// availability is a platform call. Watching it means the buttons appear as
/// soon as a retried config fetch succeeds, without the screen re-deriving
/// anything.
final socialProvidersProvider = FutureProvider<List<SocialProvider>>((
  ref,
) async {
  // Deliberately not `.future`: a failed config fetch means "offer nothing"
  // (the screen shows its own offline notice and retry), not an error that
  // should propagate and blank the login form.
  final config = await ref
      .watch(configProvider.future)
      .then<AppConfig?>((c) => c, onError: (_, _) => null);
  return SocialAuthService.instance.availableProviders(config);
});
