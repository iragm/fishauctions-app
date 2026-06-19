# Backend spec — `POST /api/mobile/auth/web-session/`

Status: **not yet implemented** on the backend (`iragm/fishauctions`). The app
already calls it ([`AuthService.getWebSessionCookie`](../lib/services/auth_service.dart))
and falls back gracefully (the WebView shows its own login) when it 404s. This
doc specifies what the backend needs so the WebView can be pre-authenticated
from the native JWT session without the user logging in twice.

## Problem

The app has **two independent sessions**:

- **Native JWT** — used by the Dart REST calls (payments, label printing,
  command palette). Established by `POST /api/mobile/auth/login/`.
- **WebView cookie** — the normal Django/allauth session the web UI runs on.

After a native login the WebView is still logged out. This endpoint bridges the
JWT into a real Django session cookie so browsing "just works" after a single
native sign-in.

## Security requirement that drives the design

A Django session cookie must be **`HttpOnly`, `Secure`, `SameSite=Lax`**. The
app currently reads `Set-Cookie` over Dio and re-injects the value with
`WebViewCookieManager` — but that platform API **cannot set `HttpOnly`/`Secure`**,
so the re-created cookie becomes readable by `document.cookie`. With
`JavaScriptMode.unrestricted` that's a session-token exposure (low, since the
content is first-party, but a real downgrade).

**Therefore the cookie must be set by the server on a response the WebView
itself loads — never reconstructed in Dart.** Two designs below; the first is
the recommended one.

---

## Recommended design — one-time handoff token (cookie never touches Dart)

Keeps the session cookie 100% server-set, with all flags, never visible to JS or
to the Dart layer.

### 1. `POST /api/mobile/auth/web-session/`

- **Auth:** `Authorization: Bearer <access_token>` (standard mobile-API auth).
- **Action:** mint a single-use, short-TTL (≈60 s) handoff token bound to
  `request.user`. Store it server-side (cache/DB) with: user id, expiry,
  used=false. Do **not** establish a session here.
- **Response `200`:**

  ```json
  { "handoff_url": "https://auction.fish/api/mobile/auth/web-session/consume/?t=<opaque-token>" }
  ```

### 2. `GET /api/mobile/auth/web-session/consume/?t=<token>`

- **Auth:** none (the token *is* the credential). No `Authorization` header —
  this is loaded by the WebView, not Dart.
- **Action:** atomically validate + mark the token used (reject if missing,
  expired, or already used → 302 to `/accounts/login/`). On success call
  `django.contrib.auth.login(request, user)` using the configured allauth
  backend, which sets the `sessionid` cookie via the normal response with
  `HttpOnly`/`Secure`/`SameSite` from Django settings.
- **Response `302`** → `next` (default web home `/`). The `Set-Cookie` rides the
  redirect; the WebView stores it natively with all flags.

### Client contract (what the app will do)

`getWebSessionCookie()` is replaced by: POST to `/web-session/`, then
`controller.loadRequest(handoff_url)` as the WebView's initial load. The app
never parses or stores the cookie. (This changes
[`webview_screen.dart`](../lib/screens/webview_screen.dart) `_initWebView` and
removes the manual `WebViewCookie` injection + `_extractSessionId`.)

---

## Simpler alternative (acceptable, with a caveat)

Single `POST /api/mobile/auth/web-session/` (Bearer auth) that calls
`auth.login()` and returns `200` with the `Set-Cookie`. For the cookie to land
in the WebView with its flags intact, the **WebView must make this request**
(e.g. a hidden `loadRequest` to an endpoint that accepts the JWT as a one-shot
query/header and redirects). If instead Dart reads `Set-Cookie` and re-injects
it (today's code path), accept that `HttpOnly` is lost — only acceptable as an
interim because the content is first-party. The handoff-token design avoids the
caveat entirely and is preferred.

## Requirements common to both

- **Rate-limit** both endpoints (per user / per IP).
- **HTTPS only**; set `SESSION_COOKIE_SECURE = True`, `SESSION_COOKIE_HTTPONLY = True`,
  `SESSION_COOKIE_SAMESITE = "Lax"` (already standard for the web app).
- **Logout symmetry:** the app treats web navigation to `/accounts/logout/` (on
  the app's own host) as a full sign-out — it clears the JWT and WebView
  cookies. The backend logout already invalidates the session; no change needed.
- **CSRF:** if any subsequent WebView POST needs it, the consume redirect can
  also set the `csrftoken` cookie (not `HttpOnly`, as Django requires JS read).
- **Tests:** add backend tests — valid JWT → usable session; expired/used/missing
  token → no session + redirect to login; cookie carries `HttpOnly`+`Secure`.

## Out of scope

Push notifications, device-bound sessions. The `MobileDevice` row registered at
login could later scope a handoff token to a device, but isn't required for v1.
