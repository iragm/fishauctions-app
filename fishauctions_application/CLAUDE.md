# CLAUDE.md — FishAuctions Flutter App

## What This Is

A Flutter mobile client for the FishAuctions auction platform. The app is architecturally a **thin WebView shell + native hardware layer**:

- WebView loads the existing Django web UI (authenticated via JWT injected as cookies/headers)
- Native Flutter code handles hardware the web can't reach: Square Tap to Pay, Bluetooth label printing, barcode scanning

The Django backend lives at https://github.com/iragm/fishauctions. Do not rewrite it — extend it via the `/api/mobile/` namespace.

**A local checkout of that backend repo is available at `/home/user/staging/fishauctions`.** Use it as a reference — read its code, check what `/api/mobile/` endpoints actually exist/return, confirm model fields, etc. — instead of guessing or relying solely on this file staying in sync.

- **Never edit files in `/home/user/staging/fishauctions`.** It's a separate repo outside this app's scope. If backend changes are needed (a new endpoint, a field, a migration), write up the spec (endpoint shape, request/response, model change) and hand it to the user to implement there — do not open Edit/Write against that path under any circumstances.
- **Prefer the web backend over native/local app logic.** When a feature could be done either by adding logic/state to the Flutter app or by extending the Django backend and having the WebView/API surface it, default to the backend. Only keep something local in the app if there's a concrete reason it must be — hardware access the web can't reach (Bluetooth, NFC/Tap to Pay, camera/barcode scanning), true offline requirements, or a native platform API with no web equivalent. This matches the WebView-first architecture below: the web UI is the source of truth for business logic and display.

## Running the App

```bash
# Android — --flavor picks the applicationId; --dart-define picks the backend.
flutter run --flavor dev -t lib/main.dart --dart-define=FLAVOR=dev          # staging backend
flutter run --flavor staging -t lib/main.dart --dart-define=FLAVOR=staging  # staging backend
flutter run --flavor prod -t lib/main.dart --dart-define=FLAVOR=prod        # production

# iOS — no --flavor (no Xcode schemes; env selection is dart-define only).
flutter run -t lib/main.dart --dart-define=FLAVOR=staging
```

Three Android flavors are configured in `android/app/build.gradle.kts`:
- **dev**: `com.fishauctions.app.dev`
- **staging**: `com.fishauctions.app.staging`
- **prod**: `com.fishauctions.app`

`lib/config/environment.dart` maps `--dart-define=FLAVOR` → API base URL (dev
and staging both point at `https://staging.auction.fish`; there is no localhost
target — a phone can't reach one anyway). iOS state and remaining setup:
`IOS.md`.

## Architecture

```
lib/
  config/         # EnvironmentConfig (dev/staging/prod URLs, feature flags)
  models/         # Dart data classes (freezed)
  screens/        # UI: login, webview shell, payment, printing
  services/       # API client, auth service, printing service, payment service
  widgets/        # Shared UI components
  utils/          # Logger, error handling
```

**State management:** Riverpod (flutter_riverpod + riverpod_generator)  
**Navigation:** go_router  
**HTTP:** Dio  
**Secure storage:** flutter_secure_storage (JWT tokens)

## Backend API — /api/mobile/

Base URL is set per flavor in `EnvironmentConfig.apiBaseUrl`.

All endpoints (except login/refresh) require `Authorization: Bearer <access_token>`.

### Authentication

```
POST /api/mobile/auth/login/
  Body:    { "credential": "username_or_email", "password": "..." }
  Returns: { "access": "...", "refresh": "..." }

POST /api/mobile/auth/refresh/
  Body:    { "refresh": "..." }
  Returns: { "access": "...", "refresh": "..." }   ← rotation enabled

GET /api/mobile/auth/me/
  Returns: { "id", "username", "email", "first_name", "last_name", "is_staff", "date_joined" }
```

**Token config:** Access tokens expire in 60 min. Refresh tokens expire in 30 days with rotation — every refresh call returns a new refresh token; old one is blacklisted.

**Token storage:** Store both tokens in `flutter_secure_storage`. Never in SharedPreferences or memory only.

### Device Registration

```
POST /api/mobile/devices/register/
  Body:    { "device_uuid": "...", "device_name": "...", "platform": "ios"|"android", "app_version": "..." }
  Returns: { "id", "device_uuid", "device_name", "platform", "app_version", "created_at", "last_seen" }
```

Call this after login. Upserts by `device_uuid` — safe to call repeatedly.

### Label Printing

Printing is configured on the `/printing/` web page (print-method dropdown:
PDF default / System printer / Bluetooth) and the app branches on the user's
`print_method`. Full backend contract in `BACKEND_SPEC.md` Part 1; both sides
are implemented and live (verified against staging 2026-07).

```
GET /api/mobile/labels/<lot_pk>/                    # RGB PNG (default fmt)
GET /api/mobile/labels/<lot_pk>/?fmt=png&resolution=WxH&dpi=N   # exact raster
GET /api/mobile/labels/<lot_pk>/?fmt=pdf            # single-lot PDF (WeasyPrint, user's prefs)
GET /api/mobile/labels/prefs/   + PATCH             # UserLabelPrefs + computed warnings
GET /api/mobile/printers/profiles/                  # ThermalPrinterProfile rows (ETag'd)
```

- **PDF / System printer** — the same WeasyPrint PDFs the website makes;
  System routes them into the OS print dialog (`printing` package), both from
  WebView downloads and the `fishauctions://print/<lot_pk>` screen.
- **Bluetooth** — server-rendered PNG at the printer's exact raster → 1-bit
  pack (`LabelRaster`) → `PrinterProfileDriver` interprets the printer's
  declarative command program (JSON steps: `tx`/`tx_text`/`tx_raster`/
  `delay_ms`/`await`/`repeat_per_copy`, schema v1). Printers are **Django
  admin rows** served by `printers/profiles/`; adding one needs no app
  release. Bundled seed profiles (`bundled_printer_profiles.dart`: D11s
  AiYin/Lujiang + raw ESC/POS) cover cold-start/offline and must stay in sync
  with the backend seed rows.
- The `/printing/` page's Bluetooth card drives the native connect/unpair
  bottom sheet through JS-bridge handlers `printerGetState` /
  `printerConnect` / `printerUnpair` (each resolves with
  `{supported, connected, name, address, profile, labelSize}`).

### Payments (Square Tap to Pay)

Uses the official **`square_mobile_payments_sdk`** Flutter plugin (the Mobile
Payments SDK — successor to the Reader SDK). Tap to Pay completes the charge
**on-device** via Square; there is no client-side card nonce. The app authorizes
the SDK with OAuth credentials the Django backend already holds.

App-side code: `lib/services/square_payment_service.dart` (SDK wrapper) and
`lib/screens/payment_screen.dart` (checkout UI; mirrors the web "quick checkout"
page but taps instead of scanning a QR).

Credentials are resolved **per invoice** on the backend (the invoice's
`club.effective_square_seller` / auction creator), so they ride along in the
`create` response — the app never stores a Square token.

```
POST /api/mobile/payments/create/
  Body:    { "invoice_pk": 123 }
  Returns: { "invoice_pk", "amount" ("15.00"), "currency",
             "location_id", "access_token",
             "square_environment", "idempotency_key",
             "reference_id" }   ← reference_id: app MUST tap with this exact value
  (Requires the authenticated operator to be an auction/club admin.)
  ← the deployment's PUBLIC Square app id comes from GET /api/mobile/config/
    (`square_application_id`); the app initializes the SDK with it at startup.
    If the create response also carries `square_application_id` it's used only
    as a fallback when the config fetch failed. NOT the secret access_token.

POST /api/mobile/payments/confirm/
  Body:    { "invoice_pk": 123, "payment_id": "<Square payment id>",
             "idempotency_key": "<from create>" }   ← payment_id, NOT source_id
  Returns: { "payment_id", "status", "receipt_number" }
```

The cashier launches the charge by tapping the checkout page's **"Tap to Pay"
button** (the `fishauctions://pay/<pk>` deep link the WebView intercepts). We
deliberately do **not** auto-start on invoice load: a Square charge takes over
the whole screen (its own full-screen Android Activity — mandatory, per Square's
docs), so the cashier opts in with an explicit tap rather than being dropped
into a full-screen prompt the instant the invoice renders. Once the sheet is
open the tap proceeds automatically (create → authorize → charge); the button is
also the retry after a cancel.

**Payment flow:**
1. App initializes the Square SDK with `square_application_id` from
   `GET /api/mobile/config/` (warmed at WebView mount; once per process, via
   the `com.fishauctions.app/platform` channel → `MobilePaymentsSdk.initialize`;
   the Flutter plugin doesn't expose `initialize`)
2. `/payments/create/` → per-invoice amount + seller `access_token` +
   `location_id` + `reference_id`; the app then calls
   `authorize(accessToken, locationId)` (re-auth if the device was authorized
   for a different seller)
3. SDK runs the Tap to Pay prompt **with the backend's `reference_id`** →
   captures the card on-device → completed `Payment` with an id
4. App posts the Square `payment_id` to `/payments/confirm/`
5. Backend verifies via Square's GetPayment API, checks the `reference_id`
   matches what it issued, and marks the invoice PAID. A mismatched (or
   client-invented) reference_id is rejected.

**Why the app id comes from the backend:** so a single app binary can serve any
deployment (a fork's own Square account/env) without baking Square config in —
the same reason the backend URL is moving to runtime config. The
`square_application_id` is the deployment's *public* integrator app id (it ships
in every build by design; the web SDK embeds it in page HTML), distinct from the
secret `access_token`. It is environment-specific (sandbox-sq0idb-… vs
sq0idp-…), so it must agree with `square_environment`. The SDK has no
re-initialize, so the app initializes once per process and refuses a *different*
app id mid-session (switch deployments → restart).

**Backend status:** the `create`/`confirm` endpoints are implemented on
`iragm/fishauctions`, and `GET /api/mobile/config/` serves the deployment's
`square_application_id`/`square_environment`. `confirm` verifies the
on-device `payment_id` via Square's GetPayment — checking status, amount, and
the issued `reference_id` — then records it idempotently and marks the invoice
PAID.

Runtime Tap to Pay still needs: a real NFC device on API 31+ (Android) or an
iPhone XS+ on iOS 16.4+, Square production approval for Tap to Pay, and — on
iOS — Apple's proximity-reader entitlement (code is wired on both platforms;
the iOS checklist is in `IOS.md`). None of that is testable in CI; CI only
verifies the app compiles and links.

## Django Backend Notes (from CLAUDE.md in iragm/fishauctions)

- Stack: Django 5.x, DRF, allauth, Bootstrap 5, HTMX, MariaDB, Redis, Celery, Docker
- Main app: `auctions/` (~5k line models.py, ~8k line views.py)
- Web auth uses allauth/session — completely separate from JWT; do not touch it
- Mobile endpoints live in `auctions/mobile/` (views, serializers, services, urls)
- Backend dev setup requires Docker: `docker compose up -d`, access at `http://127.0.0.1`

## What's NOT Done Yet (gaps from backend audit)

- **Tests:** When adding mobile features, push backend tests alongside the endpoints.
- **PaymentIntent model:** The prompt specified a standalone PaymentIntent model but the backend uses `InvoicePayment` directly. This works — just don't expect a `/payments/<id>/status/` endpoint to exist yet.
- **iOS:** project config (bundle id, iOS 16 target, Info.plist keys) is done; the Mac-only work — first signed build, Google iOS OAuth client, the Square platform channel in AppDelegate, and the Tap to Pay entitlement — is checklisted in `IOS.md`.
- ~~Printing backend endpoints~~ — landed (`printers/profiles/`, `labels/prefs/`, `labels/<pk>/?fmt=pdf`, `UserLabelPrefs.print_method`, the `/printing/` page's dropdown + BT card are live on staging). The app still degrades gracefully when offline: bundled printer profiles, print method defaults to PDF, prefs fetch returns null.
- **Push notifications:** the backend side of `BACKEND_SPEC.md` Part 2 is **implemented** (`auctions/notifications.py` notify_user choke point, `send_push_to_user` + `promo_push_notifications` tasks, `UserData.push_notifications_instead_of_email`, `PushNotificationSent`, firebase-admin) but inert by design until (a) `FIREBASE_CREDENTIALS_JSON` is set on the deployment and (b) devices report real FCM tokens. App plumbing exists (`fcm_token` sent on device registration when present, `devices/unregister/` called on sign-out) but `PushService.currentToken()` is a stub returning null until a Firebase project + `firebase_messaging` are wired (the plan delivers the public Firebase client config via `/api/mobile/config/`, not a bundled `google-services.json`). Until both land, every notification falls back to email (`user_prefers_push()` is false for everyone). **Full setup checklist + config-endpoint decision: `PUSH.md`.**
- **Square Tap to Pay (runtime):** Backend endpoints are done; charging still needs a real NFC device on API 31+ and Square production approval (sandbox works for the full flow). Not exercisable in CI.
- **Release signing:** wired in CI (keystore from repo secrets; the release workflow refuses to build unsigned). *Local* `flutter build --release` still falls back to debug signing unless you create `android/key.properties` yourself.

## CI/CD

GitHub Actions live in `.github/workflows/` (repo root, above `fishauctions_application/`):
- **ci.yml** — PRs + master/main pushes: pub get, generated-code freshness check, `dart format` check, `flutter analyze`, `flutter test`.
- **android-release.yml** — **manual** (`workflow_dispatch`, pick a Play track): runs the CI suite as a gate, restores the upload keystore from secrets (fails fast if `ANDROID_KEYSTORE_BASE64` is missing — a release must be real-signed), builds the signed prod `.aab` **and uploads it to Google Play** on the chosen track (`PLAY_SERVICE_ACCOUNT_JSON`; prerequisites satisfied), plus a signed sideloadable APK artifact.
- **ios-release.yml** — **manual** (`workflow_dispatch`) on a `macos-latest` runner, same CI gate. Default run is an unsigned `flutter build ios --no-codesign` (works today, no secrets — the macOS equivalent of the Android compile gate; it's what verifies `AppDelegate.swift`/plugins actually build on Apple toolchain). The `distribute: true` path (signed `.ipa` → TestFlight via an App Store Connect API key) is scaffolded and fails fast until the signing secrets exist (see `IOS.md`).
- **dependabot.yml** — weekly grouped minor/patch PRs (pub, gradle, actions); majors arrive individually.

Builds require **JDK 17** (AGP 9). `minSdk` is **28** (Square SDK floor).

## Auth Model — Account Required

The app has **no anonymous browsing**. The router (`lib/config/router.dart`)
traps signed-out users on three gate screens until a sign-in succeeds:

- `/login` — native login (password + "Continue with Google"). The Google
  button renders only when the deployment's `/api/mobile/config/` returns a
  non-empty `google_server_client_id`; unconfigured deployments simply don't
  offer it (no "not configured" error).
- `/signup`, `/password-reset` — the django-allauth web flows hosted in a
  restricted WebView (`AllauthWebScreen`). **Allauth is mounted at the site
  root** (`/signup/`, `/password/reset/`, `/login/`, `/logout/` — not under
  `/accounts/`): navigation is confined to an allow-list of the flow's own
  pages, a link to the web login form returns to the native login screen, and
  anything else opens in the system browser. This keeps reCAPTCHA, email
  verification, and throttling server-side with no native re-implementation.

The native JWT (`authProvider`) is the single source of truth for "signed in".
Session restore falls back to a cached profile when the network is down (tokens
present ⇒ signed in); a definitive refresh-token rejection signs the app out
globally via `ApiService.onSessionInvalidated` → router → `/login`. Sign-out
clears everything: web logout POST, all WebView cookies, JWT pair, cached
profile, Google account picker state, Square authorization.

## WebView Integration Notes

The WebView loads the Django web UI and only mounts for a signed-in session.
JWT auth is bridged into the WebView's Django cookie session:

- On first load, if the WebView has no `sessionid` cookie (fresh sign-in, or
  cookies wiped by sign-out) the shell boots through the
  `/api/mobile/auth/web-session/` handoff so the very first page renders signed
  in; otherwise it loads directly and repairs a lapsed session when the server
  bounces to `/login/` (`_reconcileWebSession`; LOGIN_URL — allauth is
  root-mounted).
- The web login form is never shown in-app — a web-form login would create a
  cookie session with no JWT.
- The WebView intercepts specific URL patterns to trigger native flows (e.g. `fishauctions://print/<lot_pk>` → native Bluetooth print dialog, `fishauctions://pay/<invoice_pk>` → native Square payment flow); a web `/logout/` navigation triggers the full native sign-out instead of navigating.
- Home-screen quick actions (long-press the launcher icon) deep-link into web pages: `ShortcutService` owns the type→path mapping ("Lots in my last auction" → `/lots/my-last-auction/` backend redirect, "Selling" → `/selling/`, "Invoices" → `/invoices/`); the shell consumes the pending path at mount (surviving the login trap via the handoff `?next=`) or navigates in place when already up.

## Key Decisions

- **WebView-first:** The web UI is the source of truth for all business logic and display. Flutter native code only handles hardware.
- **Backend over native, by default:** If a feature can live in Django and just be surfaced through the WebView/API, put it there. Native/local app state is only for things the web genuinely can't do (hardware access, offline).
- **Account required:** No signed-out mode. Signup/password-reset ride the allauth web flows in a restricted WebView rather than native forms.
- **JWT only for API calls:** The WebView session uses cookies like normal web. JWT is only used for the REST API calls from Dart code.
- **Flavor = environment:** Never hardcode URLs. Always read from `EnvironmentConfig`.
- **Secure storage for tokens:** `flutter_secure_storage` everywhere. No exceptions.
- **Backend repo is read-only reference:** `/home/user/staging/fishauctions` is available locally for browsing the Django backend, but never edit it — spec needed backend changes and hand them to the user.
