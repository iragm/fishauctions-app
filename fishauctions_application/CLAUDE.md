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

```
POST /api/mobile/payments/create/
  Body:    { "invoice_pk": 123 }
  Returns: {
    "invoice_pk", "amount", "currency", "location_id",
    "idempotency_key", "square_application_id", "square_environment"
  }

POST /api/mobile/payments/confirm/
  Body:    { "invoice_pk": 123, "source_id": "<nonce from Square SDK>", "idempotency_key": "<from create response>" }
  Returns: { "payment_id", "status", "receipt_number" }
```

**Payment flow:**
1. Call `/payments/create/` → get Square config + idempotency key
2. Pass `square_application_id`, `location_id`, `amount` to Square In-Person SDK
3. SDK collects card tap → returns `source_id` nonce
4. Call `/payments/confirm/` with nonce + idempotency key
5. Backend charges card via Square API, marks invoice PAID

Square Terminal/In-Person SDK integration lives entirely in Flutter. The backend only handles server-side creation and confirmation.

## Django Backend Notes (from CLAUDE.md in iragm/fishauctions)

- Stack: Django 5.x, DRF, allauth, Bootstrap 5, HTMX, MariaDB, Redis, Celery, Docker
- Main app: `auctions/` (~5k line models.py, ~8k line views.py)
- Web auth uses allauth/session — completely separate from JWT; do not touch it
- Mobile endpoints live in `auctions/mobile/` (views, serializers, services, urls)
- Backend dev setup requires Docker: `docker compose up -d`, access at `http://127.0.0.1`

## What's NOT Done Yet (gaps from backend audit)

- **Tests:** No mobile endpoint tests exist on the backend. When adding features, push backend tests too.
- **PaymentIntent model:** The prompt specified a standalone PaymentIntent model but the backend uses `InvoicePayment` directly. This works — just don't expect a `/payments/<id>/status/` endpoint to exist yet.
- **iOS flavor config:** Android flavors are fully configured. iOS build configurations are not set up yet.
- **Push notifications:** Not implemented on either side. `MobileDevice` model exists for future use.
- **CI/CD:** No pipelines on the backend or Flutter side.

## WebView Integration Notes

The WebView loads the Django web UI. JWT auth must be bridged into the WebView session:

- After login, exchange the JWT for a session cookie by hitting a backend endpoint (to be added), OR
- Inject the JWT as a header on every WebView request via a navigation delegate
- The WebView intercepts specific URL patterns to trigger native flows (e.g. `/print/<lot_pk>/` → native Bluetooth print dialog, `/pay/<invoice_pk>/` → native Square payment flow)

## Key Decisions

- **WebView-first:** The web UI is the source of truth for all business logic and display. Flutter native code only handles hardware.
- **JWT only for API calls:** The WebView session uses cookies like normal web. JWT is only used for the REST API calls from Dart code.
- **Flavor = environment:** Never hardcode URLs. Always read from `EnvironmentConfig`.
- **Secure storage for tokens:** `flutter_secure_storage` everywhere. No exceptions.
