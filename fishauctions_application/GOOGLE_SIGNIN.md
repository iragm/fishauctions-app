# Google sign-in — how it works and what has to be registered

## How it works

Google blocks its OAuth / One-Tap flows inside embedded WebViews, so Google
login happens **natively** (the `google_sign_in` plugin): the SDK returns a
Google ID token, and the backend (`POST /api/mobile/auth/google/`) verifies it
and issues the app's JWT pair. Username/email + password login needs none of
this and works without it — Google is additive.

The web client id the SDK verifies against (`serverClientId`) comes from the
deployment at runtime: `GET /api/mobile/config/` → `google_server_client_id`
(`SocialAuthService`). Nothing Google-related is baked into the binary, so one
build serves any deployment. If a deployment returns an empty value, the login
screen simply doesn't show the Google button — there's no "not configured"
error path.

## What to register in Google Cloud (APIs & Services → Credentials)

- **Web OAuth client** — the token *audience*, served as
  `google_server_client_id`. Reuse the one the **website's** Google login
  already uses; `/api/mobile/auth/google/` must verify ID tokens against the
  same client id.
- **Android OAuth client — one per applicationId you ship.** Android Google
  Sign-In matches on package name **+ signing-certificate SHA-1**, so each
  flavor's applicationId needs an entry with the SHA-1 of the cert that
  actually signs that build:

  | Flavor  | applicationId                  | SHA-1 to register          |
  | ------- | ------------------------------ | -------------------------- |
  | dev     | `com.fishauctions.app.dev`     | debug keystore SHA-1       |
  | staging | `com.fishauctions.app.staging` | debug keystore SHA-1       |
  | prod    | `com.fishauctions.app`         | **release** keystore SHA-1 |

  ```bash
  # debug (default Flutter debug keystore)
  keytool -list -v -alias androiddebugkey -storepass android -keypass android \
    -keystore ~/.android/debug.keystore | grep SHA1
  # release: point -keystore/-alias/-storepass at the release keystore
  ```

- **iOS OAuth client** — created, bundle id `com.fishauctions.app`; its
  `GIDClientID` and reversed-client-id URL scheme are committed in
  `ios/Runner/Info.plist` (public by construction — see [`IOS.md`](IOS.md) for
  why that's not a secret). Untested on hardware; iOS OAuth clients need no
  SHA-1, so the signing-cert failure below is Android-only.

### The two ways this fails silently

1. **Wrong signing cert.** A build signed with a cert whose SHA-1 isn't
   registered gets no ID token and no useful error — the account picker just
   closes. If Google sign-in "does nothing", check the SHA-1 first.
2. **Play App Signing.** Google Play re-signs uploads with its own app signing
   key, so an installed-from-Play build presents a *different* SHA-1 than the
   upload keystore. Register the **app signing key** SHA-1 from Play Console
   (Release → Setup → App integrity) as well as the upload key's.

## The button

`lib/widgets/google_sign_in_button.dart` draws Google's own button artwork
from `assets/google/` — the light and dark pill PNGs out of the sign-in
branding kit at
<https://developers.google.com/identity/branding-guidelines>, unmodified.

The guidelines pin the fill, stroke, label font (Google Sans Medium, which we
don't bundle) and the padding around the "G", and forbid recoloring the mark,
showing it without the button boundary and text, or distorting it. Scaling
Google's asset proportionally keeps all of that true, which is why the widget's
only knob is `height` (natural size is 40; the login screen uses 52) and why
the width is always derived from the aspect ratio. If the button needs to
change, re-download the kit rather than editing the PNGs.
