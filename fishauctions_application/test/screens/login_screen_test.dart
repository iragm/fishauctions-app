import 'package:fishauctions_application/models/app_config.dart';
import 'package:fishauctions_application/models/auth_models.dart';
import 'package:fishauctions_application/models/social_provider.dart';
import 'package:fishauctions_application/providers/auth_provider.dart';
import 'package:fishauctions_application/providers/config_provider.dart';
import 'package:fishauctions_application/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A signed-out notifier that never touches secure storage or the network.
class _SignedOut extends AuthNotifier {
  @override
  Future<AppUser?> build() async => null;
}

Future<void> _pump(WidgetTester tester, {required bool emailCodes}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_SignedOut.new),
        configProvider.overrideWith(
          (ref) async => AppConfig.fromJson({
            'brand_name': 'auction.fish',
            'email_code_sign_in_enabled': emailCodes,
          }),
        ),
        socialProvidersProvider.overrideWith(
          (ref) async => const <SocialProvider>[],
        ),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('LoginScreen with email codes enabled', () {
    testWidgets('shows the email box and hides the password form', (
      tester,
    ) async {
      await _pump(tester, emailCodes: true);

      expect(find.text('Continue with email'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
      expect(find.text('Sign in with a username and password'), findsOneWidget);
      expect(find.text('Username or email'), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(find.text('Forgot password?'), findsNothing);
    });

    testWidgets('has no Create account button and keeps the legal links', (
      tester,
    ) async {
      await _pump(tester, emailCodes: true);

      expect(find.text('Create account'), findsNothing);
      expect(find.textContaining("Don't have an account"), findsNothing);
      expect(find.text('Terms and Conditions'), findsOneWidget);
    });

    testWidgets('the toggle reveals the password form and Forgot password', (
      tester,
    ) async {
      await _pump(tester, emailCodes: true);

      final toggle = find.text('Sign in with a username and password');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(find.text('Username or email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
    });

    testWidgets('an empty email is refused before any request', (tester) async {
      await _pump(tester, emailCodes: true);

      await tester.tap(find.text('Continue with email'));
      await tester.pumpAndSettle();

      expect(find.text('Required'), findsOneWidget);
    });
  });

  group('LoginScreen without email codes', () {
    testWidgets('keeps the password form and no email box', (tester) async {
      await _pump(tester, emailCodes: false);

      expect(find.text('Continue with email'), findsNothing);
      expect(find.text('Username or email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Sign in with a username and password'), findsNothing);
    });
  });
}
