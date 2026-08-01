import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fishauctions_application/models/app_config.dart';
import 'package:fishauctions_application/models/social_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SocialProvider', () {
    test('ids are allauth\'s own provider ids', () {
      // The app and backend share these strings, and they land in
      // SocialAccount.provider — so native and web sign-ins converge on one
      // row. Renaming any of them silently forks a user's accounts in two.
      expect(SocialProvider.apple.id, 'apple');
      expect(SocialProvider.google.id, 'google');
      expect(SocialProvider.facebook.id, 'facebook');
    });

    test('round-trips through fromId', () {
      for (final p in SocialProvider.values) {
        expect(SocialProvider.fromId(p.id), p);
      }
      expect(SocialProvider.fromId('twitter'), isNull);
    });
  });

  group('SocialCredential.toJson', () {
    test('sends only the fields the provider actually supplied', () {
      // A Google credential has no nonce, no authorization code and no name;
      // emitting nulls for them would make the backend unable to distinguish
      // "absent" from "provider sent null".
      final json = const SocialCredential(
        provider: SocialProvider.google,
        idToken: 'tok',
        email: 'a@example.com',
      ).toJson();
      expect(json, {
        'provider': 'google',
        'id_token': 'tok',
        'email': 'a@example.com',
      });
    });

    test('carries the Apple first-authorization extras', () {
      // Apple sends name and email exactly once, ever. If the app drops them
      // here the backend can never recover them.
      final json = const SocialCredential(
        provider: SocialProvider.apple,
        idToken: 'tok',
        authorizationCode: 'code',
        rawNonce: 'raw',
        email: 'a@privaterelay.appleid.com',
        firstName: 'Ada',
        lastName: 'Lovelace',
      ).toJson();
      expect(json['provider'], 'apple');
      expect(json['authorization_code'], 'code');
      expect(json['nonce'], 'raw');
      expect(json['first_name'], 'Ada');
      expect(json['last_name'], 'Lovelace');
    });

    test('Facebook classic sends an access token, not an id token', () {
      final json = const SocialCredential(
        provider: SocialProvider.facebook,
        accessToken: 'fbtok',
      ).toJson();
      expect(json['access_token'], 'fbtok');
      expect(json.containsKey('id_token'), isFalse);
      // No email key at all — a Facebook account may simply not have one, and
      // that's what routes the user into the web continuation.
      expect(json.containsKey('email'), isFalse);
    });
  });

  group('SignInNonce', () {
    test('hashed is the SHA-256 of raw, which is what the backend checks', () {
      final nonce = SignInNonce.generate();
      expect(nonce.hashed, sha256.convert(utf8.encode(nonce.raw)).toString());
    });

    test('is unique per call', () {
      // A reused nonce would let a captured ID token be replayed — the exact
      // thing the nonce exists to prevent.
      final nonces = {for (var i = 0; i < 50; i++) SignInNonce.generate().raw};
      expect(nonces.length, 50);
    });

    test('raw is URL-safe and unpadded, so it survives a query string', () {
      final raw = SignInNonce.generate().raw;
      expect(raw, isNot(contains('=')));
      expect(raw, isNot(contains('+')));
      expect(raw, isNot(contains('/')));
      expect(raw.length, greaterThan(32));
    });
  });

  group('SocialLoginResult', () {
    test('a continuation is not a signed-in state', () {
      const result = SocialLoginResult.needsWeb(
        continueUrl: '/social/signup/',
        pendingToken: 'pending',
        detail: 'Pick an email address.',
      );
      expect(result.isSignedIn, isFalse);
      expect(result.continueUrl, '/social/signup/');
      expect(result.pendingToken, 'pending');
      expect(result.detail, 'Pick an email address.');
    });
  });

  group('AppConfig social provider gating', () {
    test('parses the per-provider keys', () {
      final config = AppConfig.fromJson(const {
        'square_application_id': '',
        'square_environment': '',
        'google_server_client_id': 'g-client',
        'apple_sign_in_enabled': true,
        'facebook_app_id': '1234567890',
        'brand_name': 'auction.fish',
      });
      expect(config.googleServerClientId, 'g-client');
      expect(config.appleSignInEnabled, isTrue);
      expect(config.facebookAppId, '1234567890');
    });

    test('a deployment configuring none of them offers none', () {
      // The absent keys must read as "off", not crash and not default to on —
      // an older backend serves this exact payload.
      final config = AppConfig.fromJson(const {
        'square_application_id': '',
        'square_environment': '',
        'google_server_client_id': '',
        'brand_name': 'auction.fish',
      });
      expect(config.appleSignInEnabled, isFalse);
      expect(config.facebookAppId, isEmpty);
      expect(config.googleServerClientId, isEmpty);
    });
  });
}
