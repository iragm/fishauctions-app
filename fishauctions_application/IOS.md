# iOS — current state and what's left

The Dart layer is fully platform-aware already (Bluetooth printing, permission
flows, AirPrint, downloads, calendar all branch correctly; Square paths no-op
safely on iOS until wired). What's missing is project-level config — most of
which is now done in-repo — and the Mac-only native/signing work below.

## Done in-repo (no Mac needed, committed here)

- Bundle ids: `com.fishauctions.app` / `.RunnerTests` (was `com.example.*`).
- `IPHONEOS_DEPLOYMENT_TARGET = 16.0` — forced by the Square Mobile Payments
  SDK pod (`s.platform = :ios, '16.0'`). Cuts iOS 15 devices (iPhone 6s/7/SE1);
  everything iPhone 8+ is fine.
- `CFBundleDisplayName` = `auction.fish`.
- Info.plist usage descriptions: Bluetooth, camera, photo library, calendar
  (legacy + iOS 17 write-only/full-access keys), location (distances + Square
  charge requirement).
- Plugins integrate via Swift Package Manager (Flutter 3.44) — no
  permission_handler Podfile macros needed.

## First run on a device (needs a Mac + Xcode)

1. `open ios/Runner.xcworkspace`, pick a signing team for the Runner target.
2. Run with **no `--flavor`** (iOS has no schemes; environment selection is
   dart-define only — Android's `--flavor` merely picks the applicationId):

   ```bash
   flutter run -t lib/main.dart --dart-define=FLAVOR=staging
   ```

3. At this point everything except Tap to Pay and Google sign-in should work:
   WebView shell + session handoff, BLE label printing, PDF/system printing,
   authenticated downloads, camera check-in scanner, add-to-calendar.

## Google sign-in on iOS

- Create an **iOS OAuth client** in the same Google Cloud project as the web
  client, bundle id `com.fishauctions.app`.
- Info.plist: add `GIDClientID` (the iOS client id) and a `CFBundleURLTypes`
  entry with the reversed client id URL scheme. These are static — they can't
  come from `/api/mobile/config/`.
- `serverClientId` keeps coming from `/api/mobile/config/` (already wired in
  `SocialAuthService`).

## Tap to Pay on iPhone (the real iOS work)

1. **AppDelegate platform channel** — mirror `MainActivity.kt`'s
   `com.fishauctions.app/platform` channel with an `initializeSquare` handler
   calling `MobilePaymentsSDK.initialize(...)` (the Flutter plugin exposes
   authorize/charge but not initialize, same as Android). Square's docs want
   init inside `didFinishLaunchingWithOptions`, but our app id arrives at
   runtime from `/api/mobile/config/` — so: cache the id (UserDefaults) when
   first seen, init late on the very first run, init early from the cache on
   every later launch, and refuse a *different* id ("restart to switch
   deployments" — same semantics as Android). `getSdkInt` /
   `isTapToPayCapable` stay Android-only; Dart already routes iOS capability
   to the plugin's `isDeviceCapable()`.
2. **Entitlement** `com.apple.developer.proximity-reader.payment.acceptance`
   — request from Apple (Square's dashboard walks through it), then add
   `Runner.entitlements` + provisioning profile carrying it.
3. **Apple account linking** — the plugin exposes `linkAppleAccount` /
   `isAppleAccountLinked`; the payment sheet needs a one-time "link your Apple
   account" step on iOS before the first charge (no Android equivalent).
4. **Location gate** — `SquarePaymentService.ensureLocationPermission()`
   currently returns true off-Android; extend it to prompt on iOS too (Square
   requires location authorization during a charge; the plist key is already
   in place).
5. Hardware floor is iPhone XS+ on iOS 16.4+; `isDeviceCapable()` answers at
   runtime and the existing "this device can't take Tap to Pay" UI handles it.
6. Square dashboard: accept the Tap to Pay on iPhone terms for each seller
   account.

## Distribution (later)

- App Store Connect app for `com.fishauctions.app`; signing certs/profiles.
- CI: `android-release.yml` has the TODO for a `macos-latest` job — needs the
  signing material in repo secrets first; keep disabled until then.
- Push: when FCM lands (BACKEND_SPEC Part 2 — `PushService` is a stub on all
  platforms today), iOS additionally needs an APNs auth key uploaded to
  Firebase and the push capability enabled.
- iOS "flavors": not needed for environment selection. Only add per-env bundle
  ids/schemes if staging and prod must coexist on one iPhone the way they do
  on Android.
