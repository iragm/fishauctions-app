# Push Notifications — setup checklist (Firebase / FCM + APNs)

Status of the feature end-to-end, and the concrete to-do to turn it on. This is
the app + ops side; the backend (`BACKEND_SPEC.md` Part 2) is **already
implemented** and inert by design.

## Where each half stands

- **Backend (done):** `auctions/notifications.py` routes every user
  notification through `notify_user`, which calls `send_push_to_user` when the
  user prefers push, else emails. `send_fcm_message` sends a **data-only** FCM
  message (`title`/`body`/`url`/`category` in `data`, `AndroidConfig` priority
  `high`). `PushNotificationSent` dedupes; `promo_push_notifications` handles
  promos. It stays dormant until `FIREBASE_CREDENTIALS_JSON` is set *and* a
  device reports a real token — `push_configured()` / `user_prefers_push()`
  both gate on those, so today everyone falls back to email.
- **App (stub):** `lib/services/push_service.dart` `currentToken()` returns
  `null`. Registration plumbing is already live — `AuthService.registerThisDevice`
  sends `fcm_token` **when present**, and sign-out calls `devices/unregister/`.
  No `firebase_*` plugins, no Firebase project yet.

So three things remain: **(1)** a Firebase project + APNs key, **(2)** deliver
its *client* config to the app, **(3)** wire `firebase_messaging` in the app.

## Decision: deliver Firebase client config via `/api/mobile/config/`

**Yes — the Firebase client config can and should ride the existing public
config endpoint**, exactly like `square_application_id` already does. The four
values FCM needs on the client (`apiKey`, `appId`, `messagingSenderId`,
`projectId`) are **public** — they ship inside `google-services.json` /
`GoogleService-Info.plist` in every app binary, and Google documents them as
non-secret. They fit the endpoint's stated "PUBLIC VALUES ONLY" contract. The
**secret** half (the FCM v1 service-account JSON = `FIREBASE_CREDENTIALS_JSON`,
and the APNs `.p8` key) stays server-side — the same split as Square's public
app id vs. per-invoice secret access token.

This keeps the "one binary serves any deployment" property: no
`google-services.json` baked into the build, a fork points the app at its own
backend and gets its own Firebase project's config at runtime.

**The one wrinkle — `appId` is per-package.** Unlike the single Square app id,
`FirebaseOptions.appId` (and its `apiKey`) is bound to the applicationId /
bundle id, so the three Android flavors are **three Firebase Android apps** with
three `appId`s. The app already knows its own id at runtime (`package_info_plus`),
so the endpoint returns a map keyed by package/bundle id and the app selects its
own entry. Proposed shape:

```jsonc
// GET /api/mobile/config/  (adds "firebase"; existing keys unchanged)
"firebase": {
  "android": {
    "com.fishauctions.app":         { "api_key": "…", "app_id": "1:NNN:android:…", "messaging_sender_id": "NNN", "project_id": "fishauctions-…" },
    "com.fishauctions.app.staging": { "api_key": "…", "app_id": "1:NNN:android:…", "messaging_sender_id": "NNN", "project_id": "fishauctions-…" },
    "com.fishauctions.app.dev":     { "api_key": "…", "app_id": "1:NNN:android:…", "messaging_sender_id": "NNN", "project_id": "fishauctions-…" }
  },
  "ios": {
    "com.fishauctions.app":         { "api_key": "…", "app_id": "1:NNN:ios:…", "messaging_sender_id": "NNN", "project_id": "fishauctions-…" }
  }
}
```

Empty/absent `firebase`, or no entry for this package → push simply stays off
for that build (email fallback), mirroring how `hasSquare` gates Tap to Pay.

> **Caveat to verify on device:** initializing Firebase from runtime values
> (`Firebase.initializeApp(options: …)`) instead of the bundled
> `google-services.json` is a supported but off-the-beaten-path "manual
> initialization" path. It means **caching** the fetched config locally and
> initializing from cache on cold start — including in the background isolate —
> so a killed-app push can still be handled (same cache-and-init-early pattern
> as the Square app id on iOS). The very first launch before the first config
> fetch can't receive a background push, which is fine (no token is registered
> yet either). **Confirm the first terminated-state delivery on a real device**
> before calling this done. If it proves fiddly, the fallback is the standard
> per-flavor `google-services.json` + `GoogleService-Info.plist` in the build —
> lower-risk but bakes the Firebase project into the binary, against the
> one-binary goal.

---

## Part A — Firebase project + APNs key (console / ops)

Do this once for the deployment. **Where:** <https://console.firebase.google.com/>.

- [ ] **Create the Firebase project** (or reuse an existing Google Cloud
      project). Name it for the deployment (e.g. `fishauctions`).
- [ ] **Register the Android apps** — one per flavor applicationId:
      `com.fishauctions.app`, `com.fishauctions.app.staging`,
      `com.fishauctions.app.dev`. Download each `google-services.json` — **not
      to commit**; you only need the four values (`api_key`/`current_key`,
      `mobilesdk_app_id`, `project_number`, `project_id`) to paste into the
      backend config (Part D).
- [ ] **Register the iOS app** — bundle id `com.fishauctions.app`. Same: harvest
      the values from `GoogleService-Info.plist` for the config endpoint.
- [ ] **Cloud Messaging API (V1)** — on by default for new projects. Confirm at
      Project settings → Cloud Messaging (the legacy server key is irrelevant;
      the backend uses the V1 API via the service account).
- [ ] **Service-account key for the backend** — Project settings → *Service
      accounts* → **Generate new private key** → download the JSON. This is the
      secret `FIREBASE_CREDENTIALS_JSON` env var on the deployment (hand to the
      backend; never in the app or config endpoint).
- [ ] **APNs auth key (iOS)** — at <https://developer.apple.com/account> →
      *Certificates, Identifiers & Profiles* → **Keys** → **+** → enable *Apple
      Push Notifications service (APNs)* → **download the `.p8` once** (Apple
      shows it a single time). Note the **Key ID** and your **Team ID**.
- [ ] **Upload the APNs key to Firebase** — Project settings → Cloud Messaging →
      *Apple app configuration* → **APNs Authentication Key** → upload the `.p8`
      + Key ID + Team ID. This is what lets FCM reach iOS devices.

## Part B — Android app wiring

- [ ] Add deps: `firebase_core`, `firebase_messaging`, and
      `flutter_local_notifications` (the backend sends **data-only** messages,
      which don't self-display — the app renders them). No `google-services`
      Gradle plugin and no `google-services.json` in the build if we take the
      config-API path.
- [ ] Extend `AppConfig` (`lib/models/app_config.dart`) to parse the `firebase`
      map; add a `FirebaseClientConfig? firebaseFor(package, platform)` selector
      keyed on `package_info_plus`'s `packageName`.
- [ ] On startup, if a config entry exists: cache it (secure storage / prefs)
      and `Firebase.initializeApp(options: FirebaseOptions(...))` from cache
      (so cold start / background isolate don't depend on the network).
- [ ] Implement `PushService.currentToken()` → request the Android 13+
      `POST_NOTIFICATIONS` runtime permission, then
      `FirebaseMessaging.instance.getToken()`. Re-register the device on
      `onTokenRefresh` (the seam is already noted in `push_service.dart`).
- [ ] Register a background handler (`@pragma('vm:entry-point')`,
      `FirebaseMessaging.onBackgroundMessage`) that re-inits Firebase from cache
      and renders the data message via `flutter_local_notifications`; foreground
      `onMessage` renders too. Tap → route the message's `url` into the WebView
      (reuse the existing deep-link/next-path plumbing).
- [ ] Confirm `registerThisDevice` now sends the real `fcm_token`
      (`push_configured()` on the backend flips true once a device reports one).

## Part C — iOS / APNs specifics (after the Mac build exists — see `IOS.md`)

- [ ] Xcode **Runner** target → *Signing & Capabilities*: add **Push
      Notifications** and **Background Modes → Remote notifications**.
- [ ] Same runtime-config init as Android (bundle id `com.fishauctions.app`
      entry), plus the standard iOS permission prompt.
- [ ] **Backend prerequisite (Part D):** the current data-only message has no
      `apns` block, so iOS won't display/deliver it when backgrounded. That
      backend change must land before iOS push works at all.

## Part D — Backend handoff (for `iragm/fishauctions`)

Spec these for the backend; **do not edit that repo here**:

- [ ] **Add `firebase` to `MobileConfigView`** (`auctions/mobile/views.py`,
      ~line 566) — the per-package public map above, sourced from new settings
      (mirror how `SQUARE_APPLICATION_ID` is read). Public values only; the
      view's own docstring already forbids secrets.
- [ ] **Make `send_fcm_message` iOS-capable** (`auctions/notifications.py:132`).
      It's currently Android-only data-only. Add an `apns` block so iOS both
      wakes and displays, without changing the Android path (Android ignores
      `apns`):
      ```python
      apns=messaging.APNSConfig(
          headers={"apns-priority": "10"},
          payload=messaging.APNSPayload(aps=messaging.Aps(
              alert=messaging.ApsAlert(title=title, body=body),
              content_available=True,      # deliver data to a backgrounded app
              mutable_content=True,
          )),
      ),
      ```
      (Keeps the top-level `data` for tap-routing; the `alert` is what APNs
      shows.) Already flagged in `BACKEND_SPEC.md` Amendments.
- [ ] Set `FIREBASE_CREDENTIALS_JSON` (Part A service-account JSON) on the
      deployment. `push_configured()` returns true once it's present.

## Test path

1. Backend: set `FIREBASE_CREDENTIALS_JSON` on **staging**; confirm
   `push_configured()` is true.
2. Android: install a build, grant notifications, sign in → device registers
   with a real `fcm_token`. In the web UI toggle "push instead of email"
   (`UserData.push_notifications_instead_of_email`).
3. Trigger a notification (e.g. a watched-lot event, or the promo command) →
   expect a notification tapped through to the right web page. **Verify with the
   app foregrounded, backgrounded, and killed.**
4. iOS: only after Part C + the `apns` backend change; repeat on an iPhone.
