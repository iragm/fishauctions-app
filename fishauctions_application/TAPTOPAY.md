# Tap to Pay on iPhone — publishing entitlement & App Review

Status against Apple's *Tap to Pay on iPhone — App & Marketing Requirements and Review Guide* **v1.6**. We hold the **development** entitlement (2026-07-31); the **publishing** one gates TestFlight *and* the App Store and comes only after Apple reviews this checklist. Region: **US only** — so PIN-entry education is required, and fallback payment, surcharging and IFR are not applicable.

Backend items are **TTP-n** in `BACKEND_SPEC.md`.

## Where the code is

| Piece | File |
|---|---|
| Setup / status / education screen | `lib/screens/tap_to_pay_screen.dart` (`/tap-to-pay`) |
| Awareness modal | `lib/widgets/tap_to_pay_awareness.dart` |
| Eligibility, warm-up, reader status, diagnostics | `lib/services/tap_to_pay_service.dart` |
| Naming + SF Symbol slot | `lib/widgets/tap_to_pay_branding.dart` |
| Checkout sheet | `lib/widgets/payment_sheet.dart` |
| Square SDK wrapper | `lib/services/square_payment_service.dart` |
| Apple education sheet | `ios/Runner/TapToPayEducation.swift` |
| Education presenter + iOS 17 text fallback | `lib/widgets/tap_to_pay_education.dart` |

## Two rules that constrain every change

1. **Never draw our own Tap to Pay artwork** — only Apple's toolkit assets. Hence the type-only modal and **no icon** on any Tap to Pay control.
2. **Never shorten the name.** One constant, `tapToPayName`, so no screen invents wording.

Rule 1 was broken in three places until 2026-08-30, including the "Set up Tap to Pay on iPhone" button itself — the exact control 5.5 governs — while `tap_to_pay_branding.dart` spelled out that `Icons.contactless` is forbidden. Documenting a rule is not enforcing it: **`grep -rn "Icons.contactless" lib/` before any screenshot or recording.**

## 1. General requirements

| # | Req | Status |
|---|---|---|
| 1.1 | iPhone XS and later | Done — Square's `isDeviceCapable()` |
| 1.2 | Deployment target at the Tap to Pay minimum (*conditional*) | **N/A** — see below. Target is iOS 16.0 |
| 1.3 | A12 minimum + `UIRequiredDeviceCapabilities` (*conditional*) | **N/A** — see below |
| 1.4 | Handle `osVersionNotSupported` with an "update iOS" message | Done — Square hides the real error, so the OS version is read natively and anything below 17.6 says "update", not "unsupported" |
| 1.5 | Warm up at launch / foreground | Done — mount, resume, and the `tapToPayWarm` bridge handler |
| 1.6 | Read terms-acceptance from Apple, never a local variable | Done — `isAppleAccountLinked()` every call. **Do not add a cache** |
| 1.7 | Face ID / Touch ID login (*recommended*) | Not done — recommended only; sign-in is rare |
| 1.8 | Follow the HIG | Done |
| 1.9 | Follow developer marketing guidelines | Done |

## 2. Onboarding merchants

| # | Req | Status |
|---|---|---|
| 2.1 | New user can discover account creation + Tap to Pay | Done |
| 2.2 | Fully digital onboarding, in-app on iPhone | **Two open.** Fixed 2026-09-01: `/square/connect/` bounced the merchant to the web login form, since the browser view carries Safari's cookies, not ours — now opened through an `auth/web-session/` handoff. Open: the flow strands the merchant with only the system Done button (**TTP-7**); and a new organizer can't start it until an admin trusts them (**TTP-9**) |
| 2.3 | Onboarding under 15 minutes | Seconds of merchant effort, gated by a human approval step. Declared, not claimed as a clean pass |

## 3. Enabling

| # | Req | Status |
|---|---|---|
| 3.1 | Visible, discoverable communication | Done — awareness modal + drawer entry |
| 3.2 | Full-screen modal splash (*recommended*) | Done — eligible users only, once per **install**, marked on *dismissal*. Both halves were wrong until 2026-08-30: it marked on delivery rather than acknowledgement, into the Keychain, which survives app deletion — so any failure to present was permanent, unresettable, and looked identical to being ineligible |
| 3.3 | Shown to all eligible users at least once | Done |
| 3.4 | Show how to enable at the end of onboarding | Done |
| 3.5 | Clear action to accept the Terms | Done — `linkAppleAccount()` |
| 3.6 | Enablement reachable outside comms/checkout | Done — drawer → `/tap-to-pay` |
| 3.7 | Enablement trigger inside checkout | Done — `ensureAppleAccountLinked()` in the charge |
| 3.8 | Only an admin may accept terms | Done |
| 3.8.1 | Unauthorized users told to contact an admin | Done — server-authored message |
| 3.8.2 | Apple Business Connect (*conditional*) | N/A — public App Store |
| 3.9 | "Try it out" screen (*recommended*) | Done |
| 3.9.1 | Configuration progress indicator | Done — reader callback → `TapToPayReaderStatus`, on both paths a merchant can leave education by. Settings: dismissing the sheet lands on the status card, and acceptance now re-runs `prepare()` so the bar tracks a reader that is actually arming instead of parking on `unknown`. Checkout: `_awaitReaderReady`'s `_InitializingView` |

## 4. Educating merchants

| # | Req | Status |
|---|---|---|
| 4.1 | `ProximityReaderDiscovery` on iOS 18+ | Done — verified on device 2026-08-30. Carries 4.4–4.8 with it |
| 4.2 | Education after terms acceptance | Done — **both** acceptance points, since 2026-09-03. It was wired to the settings screen alone, so the likeliest first-ever acceptance (3.7's in-checkout trigger, where setup becomes urgent) educated nobody. `showTapToPayEducation` is now shared and the payment sheet calls it on a *fresh* link only |
| 4.3 | Education in Settings or Help | Done — always present on `/tap-to-pay` |
| 4.4–4.7 | Contactless, wallets, PIN entry, accessibility | Done via 4.1; text fallback on iOS 17 and earlier |
| 4.8 | Fallback payment method | N/A — US |

## 5. Checking out

| # | Req | Status |
|---|---|---|
| 5.1 | Prominent button | Done — full-width `btn-lg` |
| 5.2 | Reachable without scrolling, top of the list | Done — above the QR block |
| 5.3 | Never altered/greyed; pressing opens terms | Done |
| 5.4 | Correct localized copy | Done — "Tap to Pay on iPhone" / "Tap to Pay" |
| 5.5 | `wave.3.right.circle[.fill]` if using an icon | Done — no icon, and 5.5 is conditional on using one |
| 5.6 | Tap to Pay UI within 1 s, 90% of the time | Done — the warm-up is what makes this true |
| 5.7 | "Initializing" screen mid-configuration | Done |
| 5.8 | "Processing" screen after the read | Done |
| 5.9 | Outcome clearly stated | Done |
| 5.10 | Digital receipt, approved **or** declined | Done — share sheet is an Activity view; `confirm` returns `receipt_url` |
| 5.11 | Regional requirements | N/A — US |

## 6. Marketing (required at launch)

| # | Req | Status |
|---|---|---|
| 6.1 | Launch email from the toolkit template | Backend command exists; copy must be the toolkit's |
| 6.2 | In-app splash from the "Hero in-app banner" | App done; **swap in toolkit artwork/copy before launch** |
| 6.3 | Push using the toolkit's value-proposition copy | Backend command exists |

## Declared: the trust gate

`UserData.is_trusted` gates accepting payments and `UserData.square_enabled` gates the Square connect entry points; neither is set for a new account. **Keep it** — a marketplace letting anyone collect money from strangers has a fraud problem, and Apple's own 3.8/3.8.1 contemplate exactly this shape of control.

Two things to be straight about in the submission: 2.3 is not a clean pass while a human presses a button (declaring it is cheaper than a reviewer finding it); and **the gate is currently invisible**, which is the part Apple would object to — with `square_enabled` false there is no "pending approval" anywhere, so the merchant meets a dead end and concludes the feature doesn't exist (**TTP-9**).

**Do not disable it to film the videos.** Pre-approve the test account and narrate the review step in video 1.

## Declared not applicable: 1.2 and 1.3

Both are conditional on Tap to Pay being the app's *primary* payment method. It isn't: this is an auction marketplace whose users are overwhelmingly bidders, and Tap to Pay is an admin-only feature. Acting on 1.3 would add `iphone-ipad-minimum-performance-a12`, which blocks **installation of the whole app** on iPhone 8/8 Plus/X — devices that browse auctions fine. Say this explicitly rather than leaving the rows blank; if the reviewer disagrees it's two lines in `Info.plist` plus bumping the deployment target to 16.4.

## Building and testing

**The entitlement lives only in `RunnerDebug.entitlements`**, deliberately. Apple's development grant enables the capability for *development* profiles; adding the key to `Runner.entitlements` before the publishing grant breaks every Release/TestFlight export, because cloud signing can't build a matching profile. `ios-release.yml` with `export_method: development` copies the debug file over it, which is how a sideloadable entitled build is produced without a Mac (see `IOS.md`).

**Every part of this needs the entitlement, education included** — established on hardware 2026-08-30. `ProximityReaderDiscovery` presents education rather than a reader and Apple's docs never mention an entitlement, but in a TestFlight build `content(for:)` fails with `ContentError.unknown` while the identical development-signed build presents the sheet. So **none of the entitlement-review videos is recordable from a distribution build.**

**Resetting between takes**: Troubleshooting on `/tap-to-pay` → **Reset for re-recording** (`TapToPayService.resetForRecording()`) clears the once-per-install awareness marker and releases the Square authorization, then re-opens the Apple Account sheet via `relinkAppleAccount()` — the SDK has no unlink, so that is the only way *in the app* to see the linking step again.

**There is a real unlink, and it isn't an API.** Apple's own page removes every Tap to Pay merchant id from an Apple Account:

> <https://businessconnect.apple.com/taptopay/removeall> → sign in → **Remove all merchant IDs**

After that the next `linkAppleAccount()` is a genuine first-time acceptance, not a relink, which is what video 2 wants. Two caveats: it is **account-wide**, so every device and every Tap to Pay app linked to that Apple Account is unlinked together; and it **does not work if the Apple Account has an Apple Business Connect account** — there the merchant id has to be removed from inside Business Connect (Tap to Pay on iPhone → the merchant id → Remove), which disables it on all devices. `isAppleAccountLinked()` is asked of Apple every call (1.6), so the app needs no reset of its own to notice.

### Solved: the palette's Tap to Pay row crashed Android (2026-09-03)

Not an iOS bug, but it lives here because it is the same screen. The website's
palette offers `fishauctions://tap-to-pay` to any mobile client; the shell pushed
`/tap-to-pay` with no platform guard, and that screen asked Square for its
authorization state.

**Why that is a crash and not an exception.** Every Square plugin module on
Android holds its manager in a `companion object` property — `AuthModule` is
`private val authManager = MobilePaymentsSdk.authorizationManager()`, and
`SettingsModule` and `PaymentModule` are the same shape. The JVM runs that
initializer on first touch of the class, so calling any of them before
`MobilePaymentsSdk.initialize()` throws *inside a static initializer*, which the
JVM rewraps as `ExceptionInInitializerError`. That is an `Error`, and Flutter's
`MethodChannel.IncomingMethodCallHandler` catches only `RuntimeException` — so it
escapes onto the main thread and ends the process before any reply crosses the
channel. **No Dart `try`/`catch` can help; there is nothing to catch.** Not
calling is the only defence, hence `PlatformBridge.squareInitialized` and the
guard on every SDK-touching getter in `SquarePaymentService`.

The same latent bug reached further than the palette: sign-out calls
`deauthorize()` inside a `try`/`catch` that could never have caught this, so on a
deployment serving no Square application id, signing out on Android would have
taken the app down too.

### Solved: iOS passed Square a prompt with no payment methods (2026-09-02)

Symptom: every iOS charge dead-ended on Square's "Connect hardware to take card payments" screen. That string is `MobilePaymentsSDKUIPaymentPromptScreenConnectHardwarePromptTitle` — the **payment prompt's empty state**, not a reader error.

On iOS, Tap to Pay is a member of `AdditionalPaymentMethods` alongside `.keyed` and `.cash` (the shipped SDK 2.6.0 binary exports `AdditionalPaymentMethods.tapToPay`), *not* the prompt's implicit primary method — and plugin 2026.8.1's iOS mapper stopped falling back to `.all`. So `additionalPaymentMethods: []` built a prompt with nothing in it. Android's mapper ignores the list entirely, which is why Android always worked. Fix: `SquarePaymentService._startPaymentIOS`, which calls the plugin's channel directly because the Dart enum can't spell `tapToPay`.

### Ruled out while chasing it — don't re-test these

The entitlements are correct **in the signed binary**, not just the profile; Apple's reader session builds cleanly (`PaymentCardReader.isSupported: true` → `session created`); and Square's App Attest startup attestation is fine despite looking alarming in the log — a reader cannot reach `ready` unless Square's server has vouched for the app, which also settles the application-signature registration and the merchant account. Deleting and reinstalling to force a fresh App Attest key changed nothing (and proved the key ID lives in the app container, not the keychain).

**The lesson**: all of that was inferred from logs, and the one fact that settled it — the reader's own status — was one `getReaders()` call away and had never been made.

### Reading the failure without a rebuild

`TapToPayService.diagnose()` collects the reader list, `unavailableReason`, the authorized location, SDK environment, device capability, Apple-account linkage and the backend's eligibility answer into one copyable block under **Troubleshooting** on `/tap-to-pay`, also `debugPrint`ed. The checkout sheet pre-flights the same reason and fails with it by name.

Two fields read `—` on iOS and always will: the plugin's iOS `Location.toMap()` omits `merchantId` and `cardProcessingActivated`, which also makes the payment sheet's `cardProcessingActivated == false` gate dead code there.

### Capturing the device log from Linux

```bash
idevice_id -l                    # device unlocked and trusted
idevicesyslog --no-colors -p 'Runner|devicecheckd|merchantd' > syslog.txt
```

Multiple process names go in **one** `-p`, separated by `|`. Expect it to stall anyway — the filter is client-side and the device still pushes everything; all three captures died within a minute. Treat the device log as a bonus; `diagnose()` is the reliable channel.

## Before submitting

1. **Copy the entitlement into `Runner.entitlements`** — only once the publishing grant arrives.
2. **Download the Marketing Guide and Toolkit** (access page + password on p. 23 of the review guide PDF) and swap the hero banner and approved copy into `tap_to_pay_awareness.dart`.
3. Optional: export `wave.3.right.circle.fill` into `assets/tap_to_pay/` and set `tapToPaySymbolAsset`.
4. **Record the three videos.** Apple's warning: **use a second device** — Tap to Pay screens are excluded from screen recording and come out blank.
   - Onboarding: account creation → Square connect → merchant approved.
   - Enabling + education: awareness modal → terms → Apple's education sheet → where to find it later → configuration progress.
   - Checkout: enter an amount → the button → initializing → a successful tap.

## App Store Connect

Nothing in ASC affects the publishing entitlement — that's a separate track. ASC matters only at submission, and it's all metadata. **Apps submitted with a Tap to Pay entitlement get a special review** on top of the normal one, so these notes are read closely.

- **App Review Information → Notes**: declare the entitlement, describe the use case ("point-of-sale for auction organizers collecting payment in person"), state the release method if behind a flag. **Don't mention MDM** — the guide warns it flags the app for unnecessary review.
- **Test account** must have **admin rights on an auction with Square connected**, or the reviewer can't reach the checkout page, the button, or the setup screen. A plain bidder account gets the app rejected as unreviewable.
- **Attachment**: a video walkthrough from sign-in to checkout, or high-fidelity wireframes. The checkout video can be reused — same second-device warning.
- **App name must not contain "Tap to Pay on iPhone"** (Guideline 5.2.5). Product-page messaging must use Marketing Guide assets, and should wait for general availability.
- **Privacy policy URL** → `https://auction.fish/privacy/`.
- **App Privacy questionnaire** is authoritative for the nutrition label (which is why `PrivacyInfo.xcprivacy` omits `NSPrivacyCollectedDataTypes`). Tap to Pay itself collects nothing you declare — Square captures the card on-device — but location, contact info and user content do.
