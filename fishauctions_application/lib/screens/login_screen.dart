import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../constants/app_constants.dart';
import '../models/social_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/config_provider.dart';
import '../services/social_auth_service.dart';
import '../widgets/legal_links.dart';
import '../widgets/social_sign_in_buttons.dart';

/// Which sign-in is in flight, if any. Both paths lock the whole screen, but
/// each reports progress and failures next to its own button.
enum _Busy { none, password, social }

/// Shown when the deployment config couldn't be fetched — i.e. the phone can't
/// reach the backend, so no sign-in of any kind is going to work yet. Framed as
/// information plus a retry rather than an error: nothing has gone wrong with
/// the app.
class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Can\'t reach the server right now. Check your connection.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// The app's front door. An account is required to use the app at all — the
/// router traps signed-out users here (plus the signup and password-reset
/// screens) until a sign-in succeeds, at which point the router redirect
/// moves them on; this screen never navigates on success itself.
///
/// The social buttons (Apple, Google, Facebook) and email/username + password
/// all produce the JWT the native features use; the WebView shell then bridges
/// that session into its Django cookie session. The social buttons lead because
/// they're the one-tap paths, and each renders only when the deployment has
/// that provider configured in `/api/mobile/config/` — a deployment with none
/// simply shows the password form. Apple comes first on iOS, which its
/// guidelines require (see `SocialAuthService.availableProviders`).
///
/// A social sign-in doesn't always finish here. When the provider gives no
/// usable email — routine with Facebook, and the reason Apple's private-relay
/// addresses matter — the backend returns a web continuation the user completes
/// in the restricted allauth WebView, after which the app swaps a pending token
/// for the session. See `_finishInWebFlow` and `BACKEND_SPEC.md` Part SOCIAL.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _credController = TextEditingController();
  final _passController = TextEditingController();
  _Busy _busy = _Busy.none;
  bool _obscure = true;
  String? _error;

  /// Failure from the most recent social attempt, shown under the buttons.
  String? _socialError;

  /// Which provider is mid-flight, so the spinner appears under *its* button
  /// rather than under all of them.
  SocialProvider? _activeProvider;

  bool get _submitting => _busy != _Busy.none;

  @override
  void dispose() {
    _credController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _busy = _Busy.password;
      _error = null;
      _socialError = null;
    });

    await ref
        .read(authProvider.notifier)
        .login(_credController.text.trim(), _passController.text);
    if (!mounted) {
      return;
    }

    final state = ref.read(authProvider);
    if (state.hasError) {
      setState(() {
        _busy = _Busy.none;
        _error = _messageFor(state.error);
      });
    }
    // On success the router redirect takes over; leave _submitting on so the
    // button doesn't blink back to life for the frame before it does.
  }

  Future<void> _signInWith(SocialProvider provider) async {
    setState(() {
      _busy = _Busy.social;
      _activeProvider = provider;
      _error = null;
      _socialError = null;
    });

    final SocialCredential? credential;
    try {
      credential = await SocialAuthService.instance.signIn(provider);
    } on SocialSignInUnavailable catch (e) {
      _failSocial(e.message);
      return;
    } on Object catch (_) {
      _failSocial(
        'Could not start ${provider.label} sign-in. Please try again.',
      );
      return;
    }
    if (credential == null) {
      // The user dismissed the provider's sheet — not an error.
      setState(() {
        _busy = _Busy.none;
        _activeProvider = null;
      });
      return;
    }

    final result = await ref
        .read(authProvider.notifier)
        .loginWithSocial(credential);
    if (!mounted) {
      return;
    }
    if (result == null) {
      _failSocial(_socialMessageFor(ref.read(authProvider).error, provider));
      return;
    }
    if (result.isSignedIn) {
      // The router redirect takes over; leave the screen locked so nothing
      // blinks back to life for the frame before it does.
      return;
    }
    await _finishInWebFlow(result, provider);
  }

  /// The provider gave us an identity but not enough to finish: no email at all
  /// (routine with Facebook), or one that hasn't been verified.
  ///
  /// allauth already implements collecting and confirming an address properly —
  /// including the confirmation email — so the user finishes there, in the same
  /// restricted WebView the signup and password-reset flows use, and the app
  /// then swaps the pending token for a session. Re-implementing that natively
  /// would mean duplicating allauth's rate limiting, its confirmation-link
  /// handling and its "this address is already taken by another account" rules.
  Future<void> _finishInWebFlow(
    SocialLoginResult result,
    SocialProvider provider,
  ) async {
    final pendingToken = result.pendingToken ?? '';
    final continueUrl = result.continueUrl ?? '';
    if (continueUrl.isEmpty || pendingToken.isEmpty) {
      _failSocial(
        'Could not finish signing in with ${provider.label}. Please try again.',
      );
      return;
    }
    final completed = await context.push<bool>(
      Uri(
        path: '/social-continue',
        queryParameters: {'url': continueUrl, 'detail': ?result.detail},
      ).toString(),
    );
    if (!mounted) {
      return;
    }
    if (completed != true) {
      // Backed out of the web flow — no account was created, nothing to say.
      setState(() {
        _busy = _Busy.none;
        _activeProvider = null;
      });
      return;
    }
    await ref.read(authProvider.notifier).completeSocialLogin(pendingToken);
    if (!mounted) {
      return;
    }
    if (ref.read(authProvider).hasError) {
      _failSocial(
        'Almost there — finish confirming your email address, then sign in '
        'with ${provider.label} again.',
      );
    }
  }

  void _failSocial(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = _Busy.none;
      _activeProvider = null;
      _socialError = message;
    });
  }

  String _messageFor(Object? error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 400 || code == 401) {
        return 'Incorrect username/email or password.';
      }
    }
    return 'Could not sign in. Check your connection and try again.';
  }

  String _socialMessageFor(Object? error, SocialProvider provider) {
    if (error is DioException) {
      // 404 means this deployment hasn't deployed the social endpoint yet — a
      // configuration gap, not a bad credential, so don't tell the user to try
      // again at something that cannot work.
      if (error.response?.statusCode == 404) {
        return '${provider.label} sign-in isn\'t available yet. Please use '
            'your email and password for now.';
      }
      // The backend authors these (an address already tied to another account,
      // a provider it can't verify right now); show its wording rather than
      // flattening every case into one generic line.
      final detail = error.response?.data;
      if (detail is Map && detail['detail'] is String) {
        return detail['detail'] as String;
      }
    }
    return 'Could not sign in with ${provider.label}. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final configState = ref.watch(configProvider);
    final config = configState.value;
    final brand = (config?.brandName.isNotEmpty ?? false)
        ? config!.brandName
        : AppConstants.appName;
    final providers =
        ref.watch(socialProvidersProvider).value ?? const <SocialProvider>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Center(
                  child: Image.asset(
                    'assets/icon/app_icon.png',
                    width: 96,
                    height: 96,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Sign in to your $brand account.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                // A first launch with no connectivity is a real case (new
                // phone, captive-portal wifi), and it isn't a neutral one: the
                // config fetch is what decides whether "Sign in with Google"
                // even appears, so failing it silently makes the app look like
                // a deployment without Google sign-in. Riverpod caches the
                // error for the session, so offer the retry explicitly rather
                // than requiring a restart.
                if (configState.hasError) ...[
                  _OfflineNotice(
                    onRetry: _submitting
                        ? null
                        : () => ref.invalidate(configProvider),
                  ),
                  const SizedBox(height: 16),
                ],
                // The social buttons lead: they're the one-tap paths, so they
                // sit above the form rather than reading as a fallback
                // underneath it. Order comes from SocialAuthService — Apple
                // first on iOS, which its guidelines require.
                if (providers.isNotEmpty) ...[
                  for (final provider in providers) ...[
                    Center(
                      child: SocialSignInButton(
                        provider: provider,
                        onPressed: _submitting
                            ? null
                            : () => _signInWith(provider),
                      ),
                    ),
                    if (_activeProvider == provider) ...[
                      const SizedBox(height: 12),
                      const Center(
                        child: SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                  ],
                  if (_socialError != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _socialError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'or',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
                TextFormField(
                  controller: _credController,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Username or email',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passController,
                  obscureText: _obscure,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submitting ? null : _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Required' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _busy == _Busy.password
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign in'),
                ),
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => context.push('/password-reset'),
                  child: const Text('Forgot password?'),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      "Don't have an account?",
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => context.push('/signup'),
                      child: const Text('Create account'),
                    ),
                  ],
                ),
                // Terms/privacy at the front door as well as on the signup
                // screen itself: this is the other place an account gets
                // created (Google sign-in creates one on first use).
                const LegalLinks(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
