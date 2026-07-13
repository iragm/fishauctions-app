# iOS — current state and what's left

The Dart layer is fully platform-aware (Bluetooth printing, permission flows,
AirPrint, downloads, calendar all branch correctly), and the Square Tap to Pay
plumbing is now written for iOS too. What remains is Mac-only: the first
signed build, and the Apple/Square approvals below.

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
- `AppDelegate.swift` implements the `com.fishauctions.app/platform` channel
  (`initializeSquare`) with the cached-id early-init pattern; the Dart bridge
  (`lib/utils/platform_bridge.dart`, ex-`android_platform.dart`) now routes
  Square init through the channel on iOS as well.
- `SquarePaymentService`: location permission is requested on iOS before a
  charge (Square requires it there too), and `ensureAppleAccountLinked()` runs
  the one-time Apple account link ahead of the first iOS charge (the payment
  sheet calls it; no-op on Android).
- Home-screen quick actions (`ShortcutService`) work on iOS with no extra
  project config.

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

## Tap to Pay on iPhone — remaining to-do list

Code is written; everything left needs a Mac, an Apple Developer account, or
Square-side approval. In order:

- [x] AppDelegate `com.fishauctions.app/platform` channel with
      `initializeSquare` → `MobilePaymentsSDK.initialize(squareApplicationID:)`
      (cached-id early init in `didFinishLaunching`; refuse a different id —
      restart to switch deployments, same semantics as Android).
- [x] Dart bridge routes Square init through the channel on iOS
      (`PlatformBridge.initializeSquare`); capability check uses the plugin's
      `isDeviceCapable()` on iOS (hardware floor: iPhone XS+ on iOS 16.4+).
- [x] Location permission requested on iOS before a charge
      (`ensureLocationPermission`; `NSLocationWhenInUseUsageDescription` in
      Info.plist).
- [x] One-time Apple account link step in the payment sheet
      (`ensureAppleAccountLinked` → plugin's `isAppleAccountLinked` /
      `linkAppleAccount`), with a clear message on cancel/failure.
- [ ] **First build on a Mac** — `AppDelegate.swift` was written without an
      iOS toolchain; expect at most minor compile fixes (the
      `MobilePaymentsSDK.initialize` call matches the Square plugin's own
      example app verbatim). `open ios/Runner.xcworkspace`, pick a signing
      team, `flutter run -t lib/main.dart --dart-define=FLAVOR=staging`.
- [ ] **Sandbox smoke test with the mock reader** — with the staging config
      (sandbox app id), authorize completes on a simulator/device; the plugin
      ships `MockReaderUI` (`showMockReaderUI`) to exercise a full tap → 
      `payments/confirm/` round-trip without the entitlement or real hardware.
      Temporary debug hook; don't ship a button for it.
- [ ] **Request the Tap to Pay entitlement** from Apple:
      `com.apple.developer.proximity-reader.payment.acceptance` (Apple's
      "Tap to Pay on iPhone" entitlement request form on
      developer.apple.com; Square's Tap to Pay docs link it). Needs the
      production bundle id `com.fishauctions.app` registered first.
- [ ] **After the grant**: create `ios/Runner/Runner.entitlements` containing
      that entitlement, set `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements`
      on the Runner target, regenerate the provisioning profile. (Deliberately
      NOT added now — an entitlements file the profile doesn't carry breaks
      signing for the plain build above.)
- [ ] **Real-device production test**: iPhone XS+ on iOS 16.4+, production
      Square app id from prod `/api/mobile/config/`, real card, small
      invoice; verify the invoice flips to PAID and the web checkout page
      re-renders.

> No Square "per-seller Tap to Pay" sign-off exists. The integrator's Square
> account is already approved for Tap to Pay, and OAuth-connected seller
> accounts inherit that — there is no per-seller dashboard T&C step to gate on
> (applies to both platforms; don't reintroduce it).
- [ ] When iOS *push* lands later: the backend's `send_fcm_message` needs an
      `apns` config block for data-only delivery (noted in BACKEND_SPEC.md
      Amendments) plus an APNs auth key in Firebase.

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
