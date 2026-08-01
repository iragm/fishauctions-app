import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'auth_models.dart';

/// A social identity provider the app can sign in with natively.
///
/// All three end up at the same backend endpoint (`auth/social/`), which runs
/// django-allauth's socialaccount pipeline — so the app's job is only to obtain
/// a provider credential and hand it over. The `id` values are allauth's own
/// provider ids, deliberately, so the app and the backend never need a mapping
/// table and the same strings appear in `SocialAccount.provider` rows.
enum SocialProvider {
  apple('apple', 'Apple'),
  google('google', 'Google'),
  facebook('facebook', 'Facebook');

  const SocialProvider(this.id, this.label);

  /// allauth's provider id — the value sent to the backend and stored on
  /// `SocialAccount.provider`.
  final String id;

  /// Human name, for error messages ("Could not sign in with Facebook").
  final String label;

  static SocialProvider? fromId(String id) {
    for (final p in SocialProvider.values) {
      if (p.id == id) {
        return p;
      }
    }
    return null;
  }
}

/// What the native SDK gave us, on its way to the backend.
///
/// Providers differ in which token they hand back, and the difference is not
/// cosmetic — the backend verifies each one differently:
///
/// - **Google** and **Apple** return an OpenID Connect **ID token** (a signed
///   JWT), verified offline against the provider's public keys.
/// - **Apple** and **Facebook Limited Login** bind that token to a **nonce**,
///   which is the app's proof the token was minted for *this* sign-in attempt
///   and not replayed. We send the raw nonce; the token carries its SHA-256.
/// - **Facebook** on Android returns a classic **access token** instead, which
///   the backend has to verify by calling Facebook (`debug_token`).
///
/// [email], [firstName] and [lastName] are best-effort extras, and Apple is the
/// reason they exist at all: it returns the user's name and real email **only
/// on the very first authorization**, never again. If the backend doesn't
/// persist them then, they're gone for good — so the app forwards whatever it
/// was given rather than dropping it. They are never *trusted* (the backend
/// takes identity from the verified token), only used to populate a new
/// account.
class SocialCredential {
  const SocialCredential({
    required this.provider,
    this.idToken,
    this.accessToken,
    this.authorizationCode,
    this.rawNonce,
    this.email,
    this.firstName,
    this.lastName,
  });

  final SocialProvider provider;

  /// OIDC ID token — Google, Apple, and Facebook Limited Login.
  final String? idToken;

  /// OAuth2 access token — Facebook classic login (Android).
  final String? accessToken;

  /// Apple's single-use authorization code. Only Apple issues one, and only the
  /// backend can redeem it (it needs the team's private key). Forwarded because
  /// redeeming it is the only way to obtain Apple's refresh token, which is in
  /// turn the only way to honour a "delete my account" by revoking the Apple
  /// grant — something Apple requires of apps offering Sign in with Apple.
  final String? authorizationCode;

  /// The **raw** nonce whose SHA-256 was sent to the provider. The backend
  /// hashes it and checks the token's `nonce` claim matches.
  final String? rawNonce;

  /// Provider-asserted email, when it gave one. **Apple sends this only on the
  /// first authorization**, and Facebook may never send it at all.
  final String? email;
  final String? firstName;
  final String? lastName;

  Map<String, dynamic> toJson() => {
    'provider': provider.id,
    if (idToken != null) 'id_token': idToken,
    if (accessToken != null) 'access_token': accessToken,
    if (authorizationCode != null) 'authorization_code': authorizationCode,
    if (rawNonce != null) 'nonce': rawNonce,
    if (email != null) 'email': email,
    if (firstName != null) 'first_name': firstName,
    if (lastName != null) 'last_name': lastName,
  };
}

/// What came back from `POST /api/mobile/auth/social/`: either a signed-in
/// user, or a web flow the user has to finish first.
///
/// The second case exists because a provider credential doesn't always carry a
/// usable, verified email — Facebook may send none at all, and an unverified
/// address can't be trusted to identify an account. Rather than rebuild
/// allauth's email collection and confirmation natively, the backend points the
/// app at the web flow that already does it correctly.
class SocialLoginResult {
  const SocialLoginResult._({
    this.user,
    this.continueUrl,
    this.pendingToken,
    this.detail,
  });

  /// Signed in — nothing further to do.
  const SocialLoginResult.signedIn(AppUser user) : this._(user: user);

  /// The user must finish [continueUrl] (an allauth page: enter an email,
  /// confirm one) before an account exists. Afterwards the app exchanges
  /// [pendingToken] for the JWT pair.
  const SocialLoginResult.needsWeb({
    required String continueUrl,
    required String pendingToken,
    String? detail,
  }) : this._(
         continueUrl: continueUrl,
         pendingToken: pendingToken,
         detail: detail,
       );

  final AppUser? user;
  final String? continueUrl;
  final String? pendingToken;

  /// Server-authored explanation of what's still needed, shown verbatim so the
  /// wording can change without an app release.
  final String? detail;

  bool get isSignedIn => user != null;
}

/// A cryptographically random nonce and the SHA-256 hash to send the provider.
///
/// Both Apple and Facebook Limited Login take a hashed nonce in the request and
/// embed it in the returned ID token. The backend recomputes the hash from
/// [raw] and compares — which is what stops an attacker replaying a token
/// captured from another app or another session. Skipping the nonce turns a
/// stolen ID token into a working credential, so neither path omits it.
class SignInNonce {
  SignInNonce._(this.raw, this.hashed);

  factory SignInNonce.generate() {
    // 32 bytes from the platform CSPRNG. `Random.secure()` is the only
    // acceptable source here — `Random()` is seeded predictably and would make
    // the nonce guessable, defeating the entire point of it.
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final raw = base64Url.encode(bytes).replaceAll('=', '');
    final hashed = sha256.convert(utf8.encode(raw)).toString();
    return SignInNonce._(raw, hashed);
  }

  /// Sent to the backend, which hashes it to check the token.
  final String raw;

  /// Sent to Apple/Facebook, and echoed back inside the ID token. Lowercase hex
  /// — the representation both providers document.
  final String hashed;
}
