import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../constants/app_constants.dart';
import '../providers/auth_provider.dart';
import '../providers/config_provider.dart';
import '../services/social_auth_service.dart';

/// The app's front door. An account is required to use the app at all — the
/// router traps signed-out users here (plus the signup and password-reset
/// screens) until a sign-in succeeds, at which point the router redirect
/// moves them on; this screen never navigates on success itself.
///
/// Email/username + password and "Continue with Google" both produce the JWT
/// the native features use; the WebView shell then bridges that session into
/// its Django cookie session. The Google button only renders when the
/// deployment has a Google OAuth client id configured
/// (`google_server_client_id` in `/api/mobile/config/`) — an unconfigured
/// deployment simply doesn't offer it.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _credController = TextEditingController();
  final _passController = TextEditingController();
  bool _submitting = false;
  bool _obscure = true;
  String? _error;

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
      _submitting = true;
      _error = null;
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
        _submitting = false;
        _error = _messageFor(state.error);
      });
    }
    // On success the router redirect takes over; leave _submitting on so the
    // button doesn't blink back to life for the frame before it does.
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _submitting = true;
      _error = null;
    });

    final String? idToken;
    try {
      idToken = await SocialAuthService.instance.signInForIdToken();
    } on GoogleSignInUnavailable catch (e) {
      setState(() {
        _submitting = false;
        _error = e.message;
      });
      return;
    } on Object catch (_) {
      setState(() {
        _submitting = false;
        _error = 'Could not start Google sign-in. Please try again.';
      });
      return;
    }
    if (idToken == null) {
      // The user dismissed the Google account picker — not an error.
      setState(() => _submitting = false);
      return;
    }

    await ref.read(authProvider.notifier).loginWithGoogle(idToken);
    if (!mounted) {
      return;
    }
    final state = ref.read(authProvider);
    if (state.hasError) {
      setState(() {
        _submitting = false;
        _error = _googleMessageFor(state.error);
      });
    }
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

  String _googleMessageFor(Object? error) {
    if (error is DioException && error.response?.statusCode == 404) {
      return "Google sign-in isn't available yet. Please use your email and "
          'password for now.';
    }
    return 'Could not sign in with Google. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider).valueOrNull;
    final brand = (config?.brandName.isNotEmpty ?? false)
        ? config!.brandName
        : AppConstants.appName;
    final googleConfigured = config?.googleServerClientId.isNotEmpty ?? false;
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
                  child: _submitting
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
                if (googleConfigured) ...[
                  const SizedBox(height: 8),
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
                  const SizedBox(height: 16),
                  // No Google wordmark asset is bundled yet; the Material "G"
                  // glyph is a placeholder — swap for the brand asset before
                  // release.
                  OutlinedButton.icon(
                    onPressed: _submitting ? null : _signInWithGoogle,
                    icon: const Icon(Icons.g_mobiledata, size: 28),
                    label: const Text('Continue with Google'),
                  ),
                ],
                const SizedBox(height: 24),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
