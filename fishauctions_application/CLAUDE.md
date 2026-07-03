# CLAUDE.md — FishAuctions Flutter App

## What This Is

A Flutter mobile client for the FishAuctions auction platform. The app is architecturally a **thin WebView shell + native hardware layer**:

- WebView loads the existing Django web UI (authenticated via JWT injected as cookies/headers)
- Native Flutter code handles hardware the web can't reach: Square Tap to Pay, Bluetooth label printing, barcode scanning

The Django backend lives at https://github.com/iragm/fishauctions. Do not rewrite it — extend it via the `/api/mobile/` namespace.

## Running the App

```bash
flutter run --flavor dev -t lib/main.dart       # dev (localhost backend)
flutter run --flavor staging -t lib/main.dart   # staging backend
flutter run --flavor prod -t lib/main.dart      # production
```

Three flavors are configured in `android/app/build.gradle.kts`:
- **dev**: `com.fishauctions.app.dev`
- **staging**: `com.fishauctions.app.staging`
- **prod**: `com.fishauctions.app`

`lib/config/environment.dart` maps flavor → API base URL.

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

```
GET /api/mobile/labels/<lot_pk>/
  Returns:
    {
      "label_data": {
        "lot_number", "title", "quantity", "minimum_bid", "buy_now_price",
        "seller", "auction", "category", "i_bred_this_fish", "custom_field_1"
      },
      "metadata": {
        "generated_at", "lot_pk",
        "supported_formats": ["png", "pdf", "raw_commands"]
      }
    }
```

The backend returns data only — no printer commands. The Flutter app is responsible for rendering to the label format and sending via Bluetooth.

Labels are **3×2 inches** (thermal, landscape). Target printers: TBD (TSPL/ZPL/ESC-POS to be determined when hardware is selected).

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
             "location_id", "access_token", "square_application_id",
             "square_environment", "idempotency_key",
             "reference_id" }   ← reference_id: app MUST tap with this exact value
  (Requires the authenticated operator to be an auction/club admin.)
  ← square_application_id: the deployment's PUBLIC Square app id; the app
    initializes the SDK with it (see flow step 2). Required — without it the
    SDK can't initialize and Tap to Pay fails. NOT the secret access_token.

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
1. `/payments/create/` → per-invoice amount + seller `access_token` +
   `location_id` + `reference_id` + `square_application_id`
2. App initializes the Square SDK with `square_application_id` (once per
   process, via the `com.fishauctions.app/platform` channel →
   `MobilePaymentsSdk.initialize`; the Flutter plugin doesn't expose
   `initialize`), then calls `authorize(accessToken, locationId)` (re-auth if
   the device was authorized for a different seller)
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
`iragm/fishauctions`. `create` must include `square_application_id` in its
response (this is what the app initializes the SDK with — if it's missing the
app rejects the response and Tap to Pay can't start). `confirm` verifies the
on-device `payment_id` via Square's GetPayment — checking status, amount, and
the issued `reference_id` — then records it idempotently and marks the invoice
PAID.

Runtime Tap to Pay still needs: a real NFC device on API 31+, Square production
approval for Tap to Pay, and the iOS Tap to Pay entitlement (iOS not wired yet).
None of that is testable in CI; CI only verifies the app compiles and links.

## Django Backend Notes (from CLAUDE.md in iragm/fishauctions)

- Stack: Django 5.x, DRF, allauth, Bootstrap 5, HTMX, MariaDB, Redis, Celery, Docker
- Main app: `auctions/` (~5k line models.py, ~8k line views.py)
- Web auth uses allauth/session — completely separate from JWT; do not touch it
- Mobile endpoints live in `auctions/mobile/` (views, serializers, services, urls)
- Backend dev setup requires Docker: `docker compose up -d`, access at `http://127.0.0.1`

## What's NOT Done Yet (gaps from backend audit)

- **Tests:** When adding mobile features, push backend tests alongside the endpoints.
- **PaymentIntent model:** The prompt specified a standalone PaymentIntent model but the backend uses `InvoicePayment` directly. This works — just don't expect a `/payments/<id>/status/` endpoint to exist yet.
- **iOS flavor config:** Android flavors are fully configured. iOS build configurations are not set up yet (and the Square Tap to Pay entitlement is iOS-only work).
- **Push notifications:** Not implemented on either side. `MobileDevice` model exists for future use.
- **Square Tap to Pay (runtime):** Backend endpoints are done; charging still needs a real NFC device on API 31+ and Square production approval (sandbox works for the full flow). Not exercisable in CI.
- **Release signing:** Release builds are debug-signed. Add a real keystore before any Play Store upload.

## CI/CD

GitHub Actions live in `.github/workflows/` (repo root, above `fishauctions_application/`):
- **ci.yml** — PRs + master pushes: pub get, generated-code freshness check, `dart format` check, `flutter analyze`, `flutter test`.
- **android-release.yml** — master pushes: builds the prod release APK (requires JDK 17) and uploads it as an artifact. Play Store + iOS/macOS steps are scaffolded but disabled pending signing.

Builds require **JDK 17** (AGP 9). `minSdk` is **28** (Square SDK floor).

## Auth Model — Account Required

The app has **no anonymous browsing**. The router (`lib/config/router.dart`)
traps signed-out users on three gate screens until a sign-in succeeds:

- `/login` — native login (password + "Continue with Google"). The Google
  button renders only when the deployment's `/api/mobile/config/` returns a
  non-empty `google_server_client_id`; unconfigured deployments simply don't
  offer it (no "not configured" error).
- `/signup`, `/password-reset` — the django-allauth web flows
  (`/accounts/signup/`, `/accounts/password/reset/`) hosted in a restricted
  WebView (`AllauthWebScreen`): navigation is confined to `/accounts/…`, a link
  to the web login form returns to the native login screen, and anything else
  opens in the system browser. This keeps reCAPTCHA, email verification, and
  throttling server-side with no native re-implementation.

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
  bounces to `/accounts/login/` (`_reconcileWebSession`).
- The web login form is never shown in-app — a web-form login would create a
  cookie session with no JWT.
- The WebView intercepts specific URL patterns to trigger native flows (e.g. `fishauctions://print/<lot_pk>` → native Bluetooth print dialog, `fishauctions://pay/<invoice_pk>` → native Square payment flow); a web `/accounts/logout/` navigation triggers the full native sign-out instead of navigating.

## Key Decisions

- **WebView-first:** The web UI is the source of truth for all business logic and display. Flutter native code only handles hardware.
- **Account required:** No signed-out mode. Signup/password-reset ride the allauth web flows in a restricted WebView rather than native forms.
- **JWT only for API calls:** The WebView session uses cookies like normal web. JWT is only used for the REST API calls from Dart code.
- **Flavor = environment:** Never hardcode URLs. Always read from `EnvironmentConfig`.
- **Secure storage for tokens:** `flutter_secure_storage` everywhere. No exceptions.
