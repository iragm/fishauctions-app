import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../services/auth_service.dart';

/// Native sign-in for the JWT-backed mobile API (payments, label printing,
/// command palette). The WebView keeps its own cookie session for browsing;
/// this screen is what makes the *native* features authenticate.
///
/// Shown automatically by the router when an unauthenticated user opens a
/// feature that needs the API; [from] is the location to return to afterwards.
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

    // Signed in — register this device (best-effort) and return to the caller.
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
                'Sign in to use payments and label printing.',
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
            ],
          ),
        ),
      ),
    ),
  );
}
