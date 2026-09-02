# Google sign-in

Google blocks its OAuth flows inside embedded WebViews, so Google login is **native** (`google_sign_in`): the SDK returns an ID token and `POST /api/mobile/auth/google/` verifies it and issues the JWT pair. Username/password login needs none of this.

The `serverClientId` comes from `GET /api/mobile/config/` (`google_server_client_id`), so nothing Google-related is baked into the binary. An empty value simply hides the button — there is no "not configured" error path.

## What to register (Google Cloud → APIs & Services → Credentials)

- **Web OAuth client** — the token *audience*, served as `google_server_client_id`. Reuse the website's; `/api/mobile/auth/google/` must verify against the same client id.
- **Android OAuth client, one per applicationId.** Android matches on package name **+ signing-certificate SHA-1**:

  | Flavor | applicationId | SHA-1 |
  |---|---|---|
  | dev | `com.fishauctions.app.dev` | debug keystore |
  | staging | `com.fishauctions.app.staging` | debug keystore |
  | prod | `com.fishauctions.app` | **release** keystore |

  ```bash
  keytool -list -v -alias androiddebugkey -storepass android -keypass android \
    -keystore ~/.android/debug.keystore | grep SHA1
  ```

- **iOS OAuth client** — bundle id `com.fishauctions.app`. Its `GIDClientID` and reversed-client-id URL scheme are committed in `Info.plist` (public by construction). iOS clients need no SHA-1, so the failures below are Android-only.

## The two ways it fails silently

1. **Wrong signing cert.** A build signed with an unregistered SHA-1 gets no ID token and no error — the account picker just closes. If Google sign-in "does nothing", check the SHA-1 first.
2. **Play App Signing.** Play re-signs uploads with its own key, so an installed-from-Play build presents a *different* SHA-1 than the upload keystore. Register the **app signing key** SHA-1 (Play Console → Release → Setup → App integrity) as well.

## The button

`lib/widgets/google_sign_in_button.dart` draws Google's own unmodified PNGs from `assets/google/`. The guidelines pin fill, stroke, label font and padding, and forbid recoloring or distorting the mark — so the widget's only knob is `height` and the width is always derived from the aspect ratio. To change it, re-download the branding kit rather than editing the PNGs.
