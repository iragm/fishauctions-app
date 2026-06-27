import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../constants/app_constants.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/social_auth_service.dart';

/// The app's single sign-in. Email/username + password and "Continue with
/// Google" both produce the JWT the native features (payments, label printing,
/// command palette) use; the WebView shell then bridges that same session into
/// its Django cookie session, so one sign-in authenticates browsing too.
///
/// Shown by the router when an unauthenticated user opens a feature that needs
/// the API, or from the menu; [from] is the location to return to afterwards.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({this.from, super.key});

  final String? from;

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
      return;
    }
    await _afterAuthSuccess();
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
      return;
    }
    await _afterAuthSuccess();
  }

  // Signed in — register this device (best-effort) and return to the caller.
  Future<void> _afterAuthSuccess() async {
    await AuthService.instance.registerThisDevice();
    if (!mounted) {
      return;
    }
    context.go(_safeTarget(widget.from));
  }

  // Only allow returning to in-app paths, never an attacker-supplied scheme.
  String _safeTarget(String? from) {
    if (from != null && from.startsWith('/') && !from.startsWith('//')) {
      return from;
    }
    return '/';
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
  Widget build(BuildContext context) => Scaffold(
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
              Text(
                'Sign in to your ${AppConstants.appName} account. One sign-in '
                'covers browsing, payments and label printing.',
                style: Theme.of(context).textTheme.bodyMedium,
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
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
              const SizedBox(height: 16),
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
              // No Google wordmark asset is bundled yet; the Material "G" glyph
              // is a placeholder — swap for the brand asset before release.
              OutlinedButton.icon(
                onPressed: _submitting ? null : _signInWithGoogle,
                icon: const Icon(Icons.g_mobiledata, size: 28),
                label: const Text('Continue with Google'),
              ),
              const SizedBox(height: 8),
              // Browsing never requires an account, so always offer a way back
              // to the WebView home (the gated target would just bounce here).
              TextButton(
                onPressed: _submitting ? null : () => context.go('/'),
                child: const Text('Not now — keep browsing'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
