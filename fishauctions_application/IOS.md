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
- `Runner/PrivacyInfo.xcprivacy` (in the target's Resources) declares the one
  required-reason API the app target itself calls — `UserDefaults`, for
  AppDelegate's cached Square app id — under reason `CA92.1`. Without it every
  upload returns `ITMS-91053: Missing API declaration`. Plugins ship their own
  manifests; extend this one only if native code starts reading file
  timestamps, disk space, boot time, or the active keyboard list. The privacy
  *nutrition label* is answered in the App Store Connect questionnaire, not
  here (see the comment in the file).

## First run on a device (needs a Mac + Xcode)

1. `open ios/Runner.xcworkspace`, pick a signing team for the Runner target.
2. Run with **no `--flavor`** (iOS has no schemes; environment selection is
   dart-define only — Android's `--flavor` merely picks the applicationId):

   ```bash
   flutter run -t lib/main.dart --dart-define=FLAVOR=staging
   ```

3. At this point everything except Tap to Pay should work: WebView shell +
   session handoff, Google sign-in, BLE label printing, PDF/system printing,
   authenticated downloads, camera check-in scanner, add-to-calendar.

## Google sign-in on iOS — done in-repo

The **iOS OAuth client** exists (Google Cloud console → Credentials → OAuth
client ID → *iOS*, bundle id `com.fishauctions.app`, same Cloud project as the
web client so the ID token's audience lines up), and Info.plist carries both
halves it needs: `GIDClientID`, and a `CFBundleURLTypes` entry whose scheme is
that id with the domain reversed.

Both are **committed in plaintext, deliberately.** An OAuth client id for a
mobile app is public by construction — it ships inside every copy of the
binary and falls out of an IPA in seconds. iOS OAuth clients have no client
secret at all; they're public clients, and the security boundary is the
backend verifying the ID token's issuer and audience, plus Google binding the
client to the bundle id. Same category as `square_application_id`. Moving it
to an Actions secret would buy nothing (the value still lands in the shipped
plist) and cost a build-time plist mutation that breaks `flutter run` locally.
The genuinely secret material — the App Store Connect `.p8`, Square access
tokens, `FIREBASE_CREDENTIALS_JSON` — never appears in the app at all.

`serverClientId` (the *web* client id) keeps coming from
`/api/mobile/config/`, already wired in `SocialAuthService` — that one is
per-deployment, and it's the reason a fork only has to edit Info.plist rather
than rebuild against new constants.

**Verify on device:** under Flutter 3.44's `SceneDelegate` lifecycle,
`application(_:open:options:)` is never called — the OAuth callback arrives via
`scene(_:openURLContexts:)` and reaches `google_sign_in_ios` only through
Flutter's forwarding shim. If sign-in opens Google and then hangs on the way
back, that's the suspect, and it looks identical to a mistyped URL scheme.

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
      `notification`+`data` hybrid so iOS displays it (the current data-only
      message doesn't) — the exact backend change is in `PUSH.md` Part D — plus
      an APNs auth key in Firebase and the push capability below.

## Distribution — CI only, no Mac

Builds run on the `macos-latest` runner in `.github/workflows/ios-release.yml`:
- **Unsigned (default):** `flutter build ios --no-codesign`, no secrets — the
  compile/link check on Apple toolchain. Works today.
- **Signed → TestFlight (`distribute: true`):** **App Store Connect API key +
  Xcode automatic cloud signing** — no hand-made certificate or provisioning
  profile to maintain. Four secrets: `APPSTORE_API_KEY_ID`,
  `APPSTORE_API_ISSUER_ID`, `APPSTORE_API_PRIVATE_KEY`, `APPLE_TEAM_ID`.

**The signed path does not use `flutter build ipa`,** and must not be
"simplified" back to it. That command passes `-allowProvisioningUpdates` but
never the `-authenticationKey*` flags, and `man xcodebuild` is explicit that
the option needs *either* an Apple ID in Xcode's Accounts pane (impossible on a
fresh runner) *or* the API key named via `-authenticationKeyPath` /
`-authenticationKeyID` / `-authenticationKeyIssuerID`. Staging the `.p8` in
`~/private_keys` doesn't help — nothing points xcodebuild at it, and cloud
signing fails with "No Accounts: Add a new account in Accounts settings".
flutter_tools exposes no way to add xcodebuild flags, so the workflow instead
runs `flutter build ios --config-only` (which writes `Generated.xcconfig`,
updates the SPM minimum deployment, and runs `pod install` for the
CocoaPods-only plugins — `square_mobile_payments_sdk` ships no `Package.swift`)
and then archives/exports with `xcodebuild` itself.

**`CODE_SIGN_IDENTITY` is not set anywhere, deliberately — don't add it back.**
Under `CODE_SIGN_STYLE=Automatic`, Xcode owns the identity and profile choice
(Apple Development for a Debug build, Apple Distribution for a Release archive)
and it *errors out* on a manually specified identity rather than honouring it.

The Flutter template ships
`"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "iPhone Developer"` in all three
project-level configs — still true in 3.44 — and **those three lines have been
deleted from `project.pbxproj`.** They pinned the Release archive to a
*development* identity, so automatic signing went looking for an "iOS App
Development" profile, which requires a registered device, and the first signed
run died with *"Your team has no devices from which to generate a provisioning
profile"* on a runner that will never have one. Deleting them fixes local Mac
builds too, which carried the same development-only pin.

Overriding the identity instead of deleting the pin fails in two further ways,
both burned through on real runs: as an xcodebuild command-line setting it
leaks to **every target in the workspace** (*"GoogleUtilities_…-UserDefaults
has conflicting provisioning settings"* — SPM resource bundles have no business
being distribution-signed, and xcodebuild can't scope a setting to one target),
and scoped to the Runner target via an xcconfig it simply relocates the
conflict onto Runner itself. Automatic signing rejects a specified identity at
any scope. `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE` on the command line are
fine and necessary — the SPM targets need them to sign themselves.

The exported `.ipa` filename is **globbed, never hardcoded**: xcodebuild names
it from the archive's product and nothing predicts whether that resolves to
`PRODUCT_NAME` (`Runner`), `CFBundleName` (`fishauctions_application`) or
`CFBundleDisplayName` (`auction.fish`) — flutter_tools prints `"$path/*.ipa"`
for the same reason.

### Apple-side prerequisites for the first signed build

Cloud signing can only *use* an app record; it can't invent one. In order:

1. **Apple Developer Program membership**, $99/yr, paid and active. If
   <https://developer.apple.com/account> shows no "Certificates, Identifiers &
   Profiles" section at all, enrollment hasn't completed — everything below is
   blocked until it does. (An empty list inside that section is fine and
   expected; cloud signing fills it in.)
2. **Register the App ID**: Certificates, Identifiers & Profiles → Identifiers
   → ＋ → *App IDs* → *App* → Description `auction.fish`, Bundle ID **explicit**
   `com.fishauctions.app`. Leave every capability **off** for now — Push
   Notifications and Tap to Pay get enabled alongside `Runner.entitlements`,
   and an entitlement the profile doesn't carry breaks signing.
3. **Create the App Store Connect record**: App Store Connect → Apps → ＋ →
   New App. Platform iOS; Name `auction.fish` (App Store names are globally
   unique and ≤30 chars — if it's taken, `auction.fish` with a suffix, and note
   that this name is independent of `CFBundleDisplayName`, which is what shows
   under the icon); Primary Language English (U.S.); Bundle ID = the identifier
   from step 2; SKU any private string, e.g. `auction-fish-ios`; Full access.
4. **App Store Connect API key**: Users and Access → Integrations → App Store
   Connect API → Team Keys → Generate. Role **App Manager**. Download the
   `.p8` **once** (Apple never shows it again). Key ID and Issuer ID are on
   that page. If the archive later fails with a permissions error creating a
   certificate, regenerate the key as **Admin**.
5. Repo secrets (Settings → Secrets and variables → Actions):
   `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`, `APPSTORE_API_PRIVATE_KEY`
   (the whole `.p8`, `-----BEGIN…` lines included), `APPLE_TEAM_ID` (10 chars,
   from developer.apple.com → Membership).
6. Run **iOS Release** with `distribute: true`, flavor `staging`. First run is
   the shakeout: cloud signing creates the distribution certificate and
   provisioning profile on the fly.

Then in App Store Connect → TestFlight: the build takes ~5–15 min to process.
**Internal testers** (up to 100 people on your team, added under Users and
Access) need **no review at all** — that's the fast path to a phone. External
testers require Beta App Review. `ITSAppUsesNonExemptEncryption=false` in
Info.plist already skips the per-upload encryption question.

> **Guideline 4.8 (Login Services)** applies at *App Store* submission, not to
> TestFlight. Offering Google sign-in alongside first-party accounts can draw a
> demand for an equivalent privacy-preserving option (in practice: Sign in with
> Apple). Enforcement is inconsistent and the first-party username/password
> login is a reasonable defense, so this is deliberately **not** pre-built —
> if it's cited, adding Sign in with Apple is the fix, not removing Google.

Also needed for iOS **push**: enable the **Push Notifications** + **Background
Modes → Remote notifications** capabilities on the Runner target (do it with the
Tap to Pay entitlement work above), and upload the APNs key to Firebase.

iOS "flavors": not needed for environment selection. Only add per-env bundle
ids/schemes if staging and prod must coexist on one iPhone the way they do on
Android.
