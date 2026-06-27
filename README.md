# fishauctions-app

Mobile app for the fishauctions project. The Flutter client lives in
[`fishauctions_application/`](fishauctions_application/); see its
[`CLAUDE.md`](fishauctions_application/CLAUDE.md) for architecture and the
backend API.

## Google Sign-In setup

Google blocks its OAuth / One-Tap flows inside embedded WebViews, so the app
signs in with Google **natively** (the `google_sign_in` plugin): it gets a
Google ID token and the backend (`POST /api/mobile/auth/google/`) verifies it
and issues a JWT. Email/username + password login needs none of this and works
without it — Google is additive.

To make the "Continue with Google" button work you need to configure Google
Cloud OAuth clients and pass the web client id into the build:

### 1. OAuth clients (Google Cloud Console → APIs & Services → Credentials)

- **Web OAuth client ID** — this is the token *audience* and the value the app
  passes as `serverClientId`. Reuse the one the **website's** Google login
  already uses (the backend's `/api/mobile/auth/google/` must verify ID tokens
  against this same client id).
- **Android OAuth client ID — one per applicationId you ship.** Android Google
  Sign-In matches by package name **+ signing-cert SHA-1**, so register each
  flavor's applicationId with the SHA-1 of the cert that signs it:

  | Flavor   | applicationId                  | SHA-1 to register          |
  | -------- | ------------------------------ | -------------------------- |
  | dev      | `com.fishauctions.app.dev`     | debug keystore SHA-1       |
  | staging  | `com.fishauctions.app.staging` | debug keystore SHA-1       |
  | prod     | `com.fishauctions.app`         | **release** keystore SHA-1 |

  Get a keystore SHA-1 with, e.g.:

  ```bash
  # debug (default Flutter debug keystore)
  keytool -list -v -alias androiddebugkey -storepass android -keypass android \
    -keystore ~/.android/debug.keystore | grep SHA1
  # release: point -keystore/-alias/-storepass at your release keystore
  ```

### 2. Pass the web client id into the build

The app reads the web client id from a compile-time define
(`EnvironmentConfig.googleServerClientId`). Add it to your run/build commands
(and CI) alongside the existing `FLAVOR` define:

```bash
flutter run   --flavor dev     -t lib/main.dart \
  --dart-define=FLAVOR=dev     --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>

flutter build apk --flavor prod -t lib/main.dart \
  --dart-define=FLAVOR=prod    --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>
```

If `GOOGLE_SERVER_CLIENT_ID` is empty, the "Continue with Google" button simply
reports that Google sign-in isn't configured; the rest of the app (including
email/password login) is unaffected.

## Known pre-release TODOs

- **Google button icon is a placeholder.** The button uses the Material
  `g_mobiledata` glyph; swap in the official Google wordmark/"G" asset (and
  follow Google's branding guidelines) before release — see
  [`lib/screens/login_screen.dart`](fishauctions_application/lib/screens/login_screen.dart).
