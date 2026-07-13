# Push Notifications — setup + status (Firebase / FCM + APNs)

End-to-end plan to turn push on. The **app side is now implemented**; what
remains is two Firebase projects, a small backend addition, and the env var.

## Status

| Layer | State |
|---|---|
| Backend send path | **Done** — `auctions/notifications.py`: `notify_user` choke point, `send_push_to_user`, `promo_push_notifications`, `PushNotificationSent` dedupe. Inert until `FIREBASE_CREDENTIALS_JSON` is set and a device reports a token. |
| App (Flutter) | **Done (this repo)** — `PushService` initializes FCM from the runtime config, requests permission, registers the token, routes taps into the WebView, shows a foreground banner. Inert (email fallback) until the config below is served. |
| Firebase projects | **You** — create staging + prod (Part A). |
| Config endpoint `firebase` block | **Backend** — Part D prompt. |
| `FIREBASE_CREDENTIALS_JSON` | **You/ops** — already wired in code; just set the env var per deployment. |

## Architecture decisions

**Client config rides `GET /api/mobile/config/`.** The four values FCM needs
(`api_key`, `app_id`, `messaging_sender_id`, `project_id`) are public — the same
class as `square_application_id`, which already goes through this endpoint — so
they're served at runtime instead of bundling `google-services.json`. One binary
serves any deployment. The **secret** half (`FIREBASE_CREDENTIALS_JSON`) stays
server-side.

**Two Firebase projects: staging and prod** (dev shares the staging backend, so
no separate dev project). Why two, not one:
- The **iOS bundle id is `com.fishauctions.app` in every environment** (no iOS
  flavors). A Firebase project can't hold two iOS apps with the same bundle id,
  so staging and prod iOS apps *must* live in separate projects.
- Clean isolation: a staging test push can't reach prod devices; separate
  service-account creds per deployment.

Each project holds the apps for the deployment(s) that backend serves:

| Project | Android app | iOS app | Backend that serves it |
|---|---|---|---|
| `fishauctions-staging` | `com.fishauctions.app.staging` | `com.fishauctions.app` | staging.auction.fish (dev + staging flavors) |
| `fishauctions` (prod) | `com.fishauctions.app` | `com.fishauctions.app` | production |

The **dev** Android flavor (`com.fishauctions.app.dev`) has no Firebase app; a
dev build finds no matching config and cleanly gets no push (email fallback).

**Config shape — flat, self-checking.** Each backend returns only its own
project's values, tagged with the package/bundle they're for. The app compares
that id to its own (`package_info_plus`) and only initializes on a match — so a
dev-flavor build hitting the staging backend disables push instead of
registering against the wrong app id:

```jsonc
// GET /api/mobile/config/  (adds "firebase"; existing keys unchanged)
// Absent/partial → app treats it as "no push". Example: the staging backend.
"firebase": {
  "android": {
    "package_name":        "com.fishauctions.app.staging",
    "api_key":             "AIzaSy…",         // google-services.json client.api_key.current_key
    "app_id":              "1:889…:android:…", // …client.client_info.mobilesdk_app_id
    "messaging_sender_id": "889…",             // project_info.project_number
    "project_id":          "fishauctions-staging"
  },
  "ios": {
    "bundle_id":           "com.fishauctions.app",
    "api_key":             "AIzaSy…",         // GoogleService-Info.plist API_KEY
    "app_id":              "1:889…:ios:…",     // GOOGLE_APP_ID
    "messaging_sender_id": "889…",             // GCM_SENDER_ID
    "project_id":          "fishauctions-staging"
  }
}
```

**Messages are `notification`+`data` (hybrid), not data-only.** The current
`send_fcm_message` is data-only, which forces the app to render notifications in
the terminated state (a fragile background-isolate path) and doesn't display on
iOS at all. Switching to a `notification` block (title/body) **plus** `data`
(url/category) makes the OS display it in background/terminated on **both**
platforms, and the app only handles the foreground banner + tap-routing. This is
the Part D backend change and is what the app was built against.

---

## Part A — Firebase project setup (do once each, ~15 min)

**Where:** <https://console.firebase.google.com/>. Do **staging first**, then
repeat for **prod**.

### Staging project (`fishauctions-staging`)
- [ ] **Create project** → name `fishauctions-staging`. Analytics optional.
- [ ] **Add Android app** → package name `com.fishauctions.app.staging`. Skip
      the SDK/Gradle steps (we don't bundle the file). **Download
      `google-services.json`** and keep it to harvest four values:
      `current_key` → `api_key`, `mobilesdk_app_id` → `app_id`,
      `project_number` → `messaging_sender_id`, `project_id`.
- [ ] **Add iOS app** → bundle id `com.fishauctions.app`. Download
      `GoogleService-Info.plist`; harvest `API_KEY`, `GOOGLE_APP_ID`,
      `GCM_SENDER_ID`, `PROJECT_ID`.
- [ ] **APNs auth key** (needed for iOS delivery; can defer until iOS testing):
      <https://developer.apple.com/account> → *Certificates, Identifiers &
      Profiles* → **Keys** → **+** → enable *Apple Push Notifications service
      (APNs)* → **download the `.p8` once**, note **Key ID** + **Team ID**. Then
      Firebase → Project settings → *Cloud Messaging* → *Apple app config* →
      **APNs Authentication Key** → upload it. (One APNs key works for all your
      apps/projects.)
- [ ] **Service-account key** → Project settings → *Service accounts* →
      **Generate new private key**. This JSON is **staging's**
      `FIREBASE_CREDENTIALS_JSON` env var. Secret — never in the app or config.

### Prod project (`fishauctions`)
- [ ] Repeat: **Android app** `com.fishauctions.app`, **iOS app**
      `com.fishauctions.app`, upload the same APNs key, generate a **separate**
      service-account key → **prod's** `FIREBASE_CREDENTIALS_JSON`.

You'll end with two sets of client values (→ the config endpoint, Part D) and two
service-account JSONs (→ the two deployments' env).

## Part B — App side (done)

Implemented here; no further app work needed to light up Android:
- `AppConfig.firebase` parses the block above (`lib/models/app_config.dart`).
- `PushService.init` (`lib/services/push_service.dart`) matches the config's id
  to this build, initializes Firebase from runtime `FirebaseOptions`, requests
  permission (iOS + Android 13+), gets/refreshes the FCM token.
- The token flows through the existing `AuthService.registerThisDevice`
  (`fcm_token`); the shell re-registers once a token arrives and on refresh.
- Taps route `data.url` into the WebView; foreground messages show a SnackBar
  with a "View" action (`webview_screen.dart`).
- Absent config → inert, email fallback (today's behavior, unchanged).

## Part C — iOS specifics + Mac-less signing

iOS push additionally needs (all deferrable until you build for iPhone):
- [ ] Xcode **Runner** target capabilities: **Push Notifications** + **Background
      Modes → Remote notifications**. (Editing `Runner.entitlements` /
      project — do alongside the Tap to Pay entitlement in `IOS.md`.)
- [ ] The APNs key uploaded in Part A.

**Signing is CI-only (no Mac).** `ios-release.yml` signs via an **App Store
Connect API key** + Xcode **automatic cloud signing** — no hand-made
certificate or provisioning profile. Create the key and set four repo secrets:

- [ ] App Store Connect → **Users and Access** → **Integrations** (Keys) → *App
      Store Connect API* → **Generate API Key**, role **App Manager** →
      **download the `.p8` once**. Note the **Key ID** and the **Issuer ID**
      (shown above the table).
- [ ] Find your **Team ID**: <https://developer.apple.com/account> → Membership.
- [ ] Register the app: App Store Connect → **Apps** → **+** → new app, bundle
      id `com.fishauctions.app` (creates the TestFlight record cloud signing
      targets).
- [ ] Set repo secrets (Settings → Secrets and variables → Actions):
      `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`,
      `APPSTORE_API_PRIVATE_KEY` (paste the whole `.p8`), `APPLE_TEAM_ID`.
- [ ] Run **iOS Release** with `distribute: true`. First run is the shakeout
      (cloud signing + the app record must exist).

Until then, run it with `distribute` **off** for the free unsigned
compile-check (verifies `AppDelegate.swift` + plugins build on Apple toolchain).

## Part D — Backend handoff (prompt for `iragm/fishauctions`)

Copy this to implement server-side (do **not** edit that repo from here):

> **1. Serve the Firebase client config from `/api/mobile/config/`.**
> In `MobileConfigView.get` (`auctions/mobile/views.py`, ~line 566) add a
> `"firebase"` key built from new settings, following the flat per-platform
> shape in `PUSH.md` (`android` → `package_name`+4 values, `ios` →
> `bundle_id`+4 values). Source them from env-backed settings (mirror
> `SQUARE_APPLICATION_ID`), e.g. `FIREBASE_ANDROID_PACKAGE_NAME`,
> `FIREBASE_ANDROID_API_KEY`, `FIREBASE_ANDROID_APP_ID`,
> `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`, and the `FIREBASE_IOS_*`
> equivalents. Omit a platform (or the whole `firebase` key) when its vars are
> unset. **Public values only** — the view's docstring already forbids secrets.
>
> **2. Make `send_fcm_message` a notification+data hybrid.**
> In `auctions/notifications.py:132`, add a `notification` block so the OS
> displays the message in background/terminated on both platforms, keeping the
> `data` for tap-routing:
> ```python
> message = messaging.Message(
>     notification=messaging.Notification(title=title or "", body=body or ""),
>     data={"title": title or "", "body": body or "",
>           "url": url or "", "category": category or ""},
>     token=token,
>     android=messaging.AndroidConfig(priority="high", collapse_key=collapse_key or None),
>     apns=messaging.APNSConfig(
>         headers={"apns-priority": "10"},
>         payload=messaging.APNSPayload(aps=messaging.Aps(sound="default")),
>     ),
> )
> ```
> (The top-level `notification` covers display; `apns` just adds sound/priority.)
>
> **3. Set `FIREBASE_CREDENTIALS_JSON`** per deployment — staging's
> service-account JSON on staging, prod's on prod. No code change (already read
> in `settings.py` + `notifications.py`); `push_configured()` flips true once
> set.

## Test path

1. Set `FIREBASE_CREDENTIALS_JSON` on **staging** + deploy the config-endpoint
   change; confirm `push_configured()` is true and `/api/mobile/config/` returns
   the `firebase` block.
2. Install a **staging** Android build, grant notifications, sign in → the
   device registers with a real `fcm_token`. Toggle "push instead of email"
   (`UserData.push_notifications_instead_of_email`) in the web UI.
3. Trigger a notification (watched-lot event, or the promo command). Verify the
   tap lands on the right page **foregrounded, backgrounded, and killed**.
4. iOS: after Part C (entitlement + signed TestFlight build + an iPhone), repeat.
