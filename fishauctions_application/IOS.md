# iOS — state and what's left

The Dart layer is fully platform-aware and Tap to Pay works on real hardware (2026-09-02). What remains is Apple's publishing entitlement and the App Store submission.

## Settled decisions

- Bundle ids `com.fishauctions.app` / `.RunnerTests`; `CFBundleDisplayName` = `auction.fish`.
- **`IPHONEOS_DEPLOYMENT_TARGET = 16.0`** — forced by the Square pod. Cuts iPhone 6s/7/SE1.
- **`TARGETED_DEVICE_FAMILY = "1"` (iPhone only) is a one-way door.** Every hardware feature here is a phone feature, and once a version ships supporting iPad, App Store Connect will not accept an update that drops it. iPad users can still run it in compatibility mode. `UISupportedInterfaceOrientations~ipad` is left in as dead config for a future re-add.
- **`PrivacyInfo.xcprivacy`** declares `UserDefaults` under reason `CA92.1` (AppDelegate's cached Square app id). Without it every upload returns `ITMS-91053`. Extend it only if native code starts reading file timestamps, disk space, boot time, or the keyboard list. The nutrition label is answered in App Store Connect, not here.
- **`ENABLE_USER_SCRIPT_SANDBOXING = NO`** — Square's setup script can't run under sandboxing.
- iOS "flavors" aren't needed; environment selection is dart-define only. Only add per-env bundle ids if staging and prod must coexist on one iPhone.

## Getting an entitled build onto a phone with no Mac

Apple's **development** Tap to Pay entitlement attaches to *development* profiles, so it can never reach TestFlight. `ios-release.yml` with `distribute: true` + **`export_method: development`** swaps `RunnerDebug.entitlements` into place, exports with `method=development`, skips App Store Connect, and leaves a sideloadable IPA as the artifact.

**The only prerequisite is one registered device** — Apple issues no development profile to a team with zero of them.

1. Get the UDID: `idevice_id -l` (no app can read it; the `device_uuid` this app sends is an unrelated random v4).
2. developer.apple.com → Certificates, Identifiers & Profiles → **Devices** → **+**. Capped at 100/year, and removals don't free a slot until renewal.
3. **No new CI secrets** — a development export uses the same App Store Connect API key.
4. `ideviceinstaller -i <the>.ipa`. It only installs on a registered device. Artifact retention is one day.

That build gets `aps-environment: development`, so its push tokens are sandbox ones.

**Use `flavor: prod` for a real Tap to Pay test.** The workflow defaults to `staging`, whose Square config is sandbox — and `MockReaderUI` is pod'd `:configurations => ['Debug']` while the archive is Release, so a sandbox build can only ever show the "connect hardware" screen.

## Signing — four runs' worth of dead ends, don't re-try

- **Not `flutter build ipa`.** It passes `-allowProvisioningUpdates` but never the `-authenticationKey*` flags, which xcodebuild requires in the absence of an Apple ID in Xcode's Accounts pane. Staging the `.p8` doesn't help — nothing points xcodebuild at it. The workflow runs `flutter build ios --config-only` then archives/exports with `xcodebuild` itself.
- **The archive is ad-hoc signed and `-exportArchive` applies the real signature.** Archive-then-resign is how Xcode works, but Apple won't issue a development profile to a team with zero registered devices. Ad-hoc (`CODE_SIGN_IDENTITY=-`) satisfies the archive half with no profile, and is the one identity that doesn't trip a conflict under `CODE_SIGN_STYLE=Automatic`. This is what Xcode Cloud does ([DevForums 756119](https://developer.apple.com/forums/thread/756119)).
- **Not `CODE_SIGNING_ALLOWED=NO`** — a fully unsigned archive exports an *unsigned* IPA and pairs with `signingStyle: manual`.
- The Flutter template pins `"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "iPhone Developer"` in all three project-level configs; deleting the pin doesn't help, because Xcode's default is "Apple Development", which wants the same kind of profile.

## `ios/Podfile` exists only for Square's setup phase — don't delete it

Flutter regenerates a stock Podfile on demand, silently taking the App Store rejection with it. `SquareMobilePaymentsSDK.framework` ships nested frameworks and a `setup` executable, both illegal in an App Store binary (ITMS-90035/90205/90206); the phase hoists and re-signs them and must be **last**, so it's added from `post_integrate`. It's skipped when `CODE_SIGNING_ALLOWED=NO`, because the re-sign needs a real identity.

## Apple-side prerequisites for a signed build

Cloud signing can use an app record but can't invent one.

1. **Apple Developer Program membership**, active.
2. **Register the App ID** (explicit `com.fishauctions.app`). Enable capabilities only alongside the matching entitlements file — an entitlement the profile doesn't carry breaks signing. Currently needed: Push Notifications, Background Modes → Remote notifications, App Attest, NFC Tag Reading, Sign in with Apple, Tap to Pay.
3. **Create the App Store Connect record.** The App Store name is globally unique, ≤30 chars, and independent of `CFBundleDisplayName`.
4. **App Store Connect API key, role Admin.** **Admin is not a suggestion** — Certificates, Identifiers & Profiles is a separate permission area only Admin and Account Holder reach over the API, and cloud signing *creates* the distribution certificate. An App Manager key fails with `Cloud signing permission error` / `No signing certificate "iOS Distribution" found`, and a key's role **cannot be edited after creation** ([DevForums 698117](https://developer.apple.com/forums/thread/698117)). Download the `.p8` once.
5. Repo secrets: `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`, `APPSTORE_API_PRIVATE_KEY` (whole file, BEGIN lines included), `APPLE_TEAM_ID`.
6. Run **iOS Release** with `distribute: true`. First run is the shakeout.

TestFlight processing is ~5–15 min. **Internal testers need no review**; external ones need Beta App Review. `ITSAppUsesNonExemptEncryption=false` already skips the per-upload encryption question.

## Remaining

- [ ] **Tap to Pay *publishing* entitlement** — checklist, videos and materials in `TAPTOPAY.md`.
- [ ] **After the grant**: add `com.apple.developer.proximity-reader.payment.acceptance` to `Runner.entitlements` and regenerate the distribution profile. Deliberately not there now.
- [ ] **iOS push**: upload an APNs auth key to Firebase; the backend's `send_fcm_message` needs a `notification`+`data` hybrid for iOS to display it (`PUSH.md`).

> **No Square "per-seller Tap to Pay" sign-off exists.** The integrator's account is approved and OAuth-connected sellers inherit that. Don't reintroduce a per-seller T&C step on either platform.
