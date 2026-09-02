# Push Notifications (Firebase / FCM + APNs)

App side and backend send path are **done**. What remains is ops: two Firebase projects, the `firebase` block in `config/`, and `FIREBASE_CREDENTIALS_JSON` per deployment.

| Layer | State |
|---|---|
| Backend send path | Done — `notify_user` choke point, `send_push_to_user`, `PushNotificationSent` dedupe. Inert until `FIREBASE_CREDENTIALS_JSON` is set and a device reports a token |
| App | Done — `PushService` initializes FCM from runtime config, registers the token, routes taps, shows a foreground banner. Inert (email fallback) without config |
| Firebase projects | **Ops** |
| `firebase` block in `config/` | **Backend** |
| `FIREBASE_CREDENTIALS_JSON` | **Ops** — already read in code |

## Decisions

- **Client config rides `GET /api/mobile/config/`.** The four values FCM needs are public (same class as `square_application_id`), so they're served at runtime instead of bundling `google-services.json` — one binary per deployment. The secret half stays server-side.
- **Two Firebase projects, staging and prod.** The **iOS bundle id is `com.fishauctions.app` in every environment** (no iOS flavors), and a Firebase project can't hold two iOS apps with the same bundle id. Also keeps a staging test push away from prod devices.

  | Project | Android app | iOS app |
  |---|---|---|
  | `fishauctions-staging` | `com.fishauctions.app.staging` | `com.fishauctions.app` |
  | `fishauctions` | `com.fishauctions.app` | `com.fishauctions.app` |

- **The dev Android flavor has no Firebase app**, so a dev build cleanly gets no push. This is why the config is **self-checking**: each block is tagged with the package/bundle it's for, and the app compares it to its own (`package_info_plus`) before initializing — otherwise a dev build against staging would register under the wrong app id.

```jsonc
"firebase": {
  "android": {"package_name": "com.fishauctions.app.staging", "api_key": "…",
              "app_id": "1:…:android:…", "messaging_sender_id": "…", "project_id": "…"},
  "ios":     {"bundle_id": "com.fishauctions.app", "api_key": "…",
              "app_id": "1:…:ios:…", "messaging_sender_id": "…", "project_id": "…"}
}
```

Android values come from `google-services.json`; iOS from `GoogleService-Info.plist` (`API_KEY`, `GOOGLE_APP_ID`, `GCM_SENDER_ID`). Absent or partial → the app treats it as "no push".

- **Messages must be `notification`+`data` hybrid, not data-only.** Data-only forces the app to render notifications in the terminated state (a fragile background-isolate path) and **doesn't display on iOS at all**. A `notification` block (title/body) plus `data` (url/category) lets the OS display it on both platforms; the app then only handles the foreground banner and tap routing. **This is the one backend change still outstanding**, and it's what the app was built against.

## iOS

Entitlements are already wired: `Runner.entitlements` (`aps-environment: production`) and `RunnerDebug.entitlements` (`development`), plus `UIBackgroundModes: [remote-notification]`. Still needs the Push Notifications and Background Modes capabilities on the App ID, and an **APNs auth key uploaded to Firebase**.

## Test path

1. Set `FIREBASE_CREDENTIALS_JSON` on staging, deploy the config change, confirm `/api/mobile/config/` returns the `firebase` block.
2. Install a **staging** Android build, grant notifications, sign in → the device registers a real `fcm_token`. Toggle `push_notifications_instead_of_email`.
3. Trigger a notification and verify the tap lands correctly **foregrounded, backgrounded, and killed**.
4. iOS: repeat after the APNs key and a signed build.

**Testing traps**: a **dev-flavor build can never receive push against staging** (by design — the config targets `.staging`), and a signed-out app never initializes push at all.
