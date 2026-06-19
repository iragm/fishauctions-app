# Backend spec — `POST /api/mobile/auth/web-session/`

**Status:** not yet implemented on the backend (`iragm/fishauctions`). The app
already calls it and falls back gracefully when it 404s
([`AuthService.getWebSessionCookie`](../../lib/services/auth_service.dart),
[`WebViewScreen._initWebView`](../../lib/screens/webview_screen.dart)).

## Why it exists

The app has **two independent sessions**:

- **JWT** (SimpleJWT) — used by Dart for `/api/mobile/` REST calls.
- **Django session cookie** — used by the WebView, which loads the normal web
  UI and authenticates exactly like a browser (allauth session).

A native sign-in only establishes the JWT. Without this endpoint the WebView
stays logged out until the user signs in again *inside* the WebView, which is
the dual-login confusion called out in the app review. This endpoint lets the
app bootstrap a Django session **from a valid JWT**, so one native sign-in logs
the user into both.

## Contract

```
POST /api/mobile/auth/web-session/
Authorization: Bearer <access_token>     # standard mobile-API auth
Body: (none)
```

**Success — 200**

The endpoint logs the JWT's user into a real Django session server-side
(`django.contrib.auth.login(request, user)`), so Django emits its own
`Set-Cookie: sessionid=…; HttpOnly; Secure; SameSite=Lax`.

```
HTTP/200
Set-Cookie: sessionid=<id>; Path=/; HttpOnly; Secure; SameSite=Lax
Set-Cookie: csrftoken=<token>; Path=/; Secure; SameSite=Lax   # if applicable
Body: { "ok": true }
```

**Failure**

- `401` — missing/expired/invalid JWT (the standard DRF auth response). The app
  treats anything other than 200 as "fall back to in-WebView login."

## ⚠️ Preferred client integration — do NOT copy the cookie value into JS

The app's current placeholder reads the `Set-Cookie` value and re-injects it via
`WebViewCookieManager().setCookie(...)`. **That path silently drops `HttpOnly`
and `Secure`**, making the session id readable from `document.cookie` (the
WebView runs with JavaScript enabled). That is a security downgrade and should
not ship.

Pick one of these instead, in order of preference:

1. **Redirect-based bootstrap (best).** Add a one-time, JWT-authenticated GET
   that calls `login()` and `302`-redirects into the app:

   ```
   GET /api/mobile/auth/web-session/start/?next=/   (Authorization: Bearer …)
       → 302 to <next>, with Set-Cookie: sessionid=…; HttpOnly; Secure
   ```

   The app loads this URL **in the WebView** with the `Authorization` header
   attached for that one request. The WebView's own cookie jar stores the
   `Set-Cookie` *with* its `HttpOnly`/`Secure` flags intact, because the cookie
   is set by a real navigation rather than copied by Dart. No secret ever
   touches JavaScript. This is the recommended approach — update
   `WebViewScreen._initWebView` to load this URL instead of setting the cookie
   manually, and delete `_extractSessionId`.

2. **One-time exchange code.** `web-session/` returns a short-lived,
   single-use nonce (≤60 s) instead of a cookie. The app navigates the WebView
   to `…/accounts/session-exchange/?code=<nonce>`, the backend validates the
   nonce, calls `login()`, and `302`s onward — same HttpOnly outcome, and the
   nonce is worthless if intercepted after use.

Either way the **backend** sets the cookie via a navigation the WebView makes,
so the cookie keeps `HttpOnly`/`Secure`. The Dart side never parses or stores a
session id.

## Security requirements

- Rotate the session on login (`request.session.cycle_key()` / Django's
  `login()` already does this) to prevent fixation.
- Always set `Secure` + `HttpOnly` + `SameSite=Lax` on `sessionid`
  (production is HTTPS-only; staging too).
- Honor the JWT blacklist — a refresh-rotated/blacklisted access token must not
  mint a web session.
- The endpoint must require a valid access token and nothing else; do not accept
  the refresh token here.

## Logout symmetry

Web logout (`/accounts/logout/`) already triggers a native JWT logout +
WebView cookie clear in the app
([`WebViewScreen._handleNavigation`](../../lib/screens/webview_screen.dart)).
No backend change needed for logout, but keep `/accounts/logout/` invalidating
the Django session as it does today.
