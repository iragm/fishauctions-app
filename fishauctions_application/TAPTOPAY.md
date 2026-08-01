# Tap to Pay on iPhone — publishing entitlement & App Review

Status against Apple's *Tap to Pay on iPhone — App & Marketing Requirements and
Review Guide*, **v1.6 (March 2026)**.

We hold the **development** entitlement (dev only, as of 2026-07-31). The
**publishing** entitlement is what TestFlight and the App Store need, and Apple
grants it only after reviewing the app against the checklist below. Apple asks
for three things with that request: UI flows, video recordings, and a completed
requirements checklist. This file is the working copy of that checklist.

Region: **US only**. That makes PIN-entry education required (all regions except
JP/TW), and makes fallback-payment (CA/GL/IE/IM/JE/UK), surcharging (AU/BR) and
IFR (BE/DE/DK/FR/NO) not applicable.

Backend items referenced as **TTP-n** are specified in `BACKEND_SPEC.md`, Part
TTP.

---

## Where the code is

| Piece | File |
|---|---|
| Setup / status / education screen | `lib/screens/tap_to_pay_screen.dart` (route `/tap-to-pay`) |
| Awareness moment (full-screen modal) | `lib/widgets/tap_to_pay_awareness.dart` |
| Eligibility, warm-up, reader status, enable | `lib/services/tap_to_pay_service.dart` |
| Reader status / eligibility models | `lib/models/tap_to_pay_status.dart` |
| Naming + SF Symbol slot | `lib/widgets/tap_to_pay_branding.dart` |
| Checkout sheet (initializing → processing → outcome → receipt) | `lib/widgets/payment_sheet.dart` |
| Square SDK wrapper | `lib/services/square_payment_service.dart` |
| Apple education sheet (`ProximityReaderDiscovery`) | `ios/Runner/TapToPayEducation.swift` |

## Two rules that constrain every change here

1. **Never draw our own Tap to Pay artwork.** The guide forbids developing
   customized marketing content, images or videos for Tap to Pay on iPhone, and
   forbids creating illustrations or icons that depict iPhone or the capability.
   Only Apple's toolkit assets, with light customization (brand colour, font,
   logo). This is why the awareness modal and the education fallback are
   type-only, and why the app ships with **no icon** on its Tap to Pay controls.
2. **Never shorten the name.** "Tap to Pay on iPhone", never "Tap to Pay" alone
   and never with "Apple" in it. One constant, `tapToPayName`, so no screen
   invents its own wording.

---

## 1. General requirements

| # | Req | Status |
|---|---|---|
| 1.1 | Support iPhone XS and later | **Done** — Square's `isDeviceCapable()` enforces the floor |
| 1.2 | Deployment target set to the Tap to Pay minimum (*conditional*) | **N/A — see "Declared not applicable" below.** Target is iOS 16.0 |
| 1.3 | A12 minimum + `UIRequiredDeviceCapabilities` (*conditional*) | **N/A — see below.** Deliberately not restricted |
| 1.4 | Handle `osVersionNotSupported` with an "update iOS" message | **Done** — `TapToPayService.unsupportedReason()`. Square hides the real error, so the OS version is read natively (`PlatformBridge.osVersion`) and anything below 17.6 is reported as "update your iPhone" rather than "unsupported device" |
| 1.5 | Warm Tap to Pay up at launch / foreground | **Done in app; needs TTP-3.** `_warmSquare()` runs at shell mount and on every resume and calls `TapToPayService.prepare()`, which authorizes the SDK — the step that actually starts the reader preparing. Until the endpoint exists it no-ops and authorization stays per-invoice |
| 1.6 | Read terms-acceptance status from Apple, never a local variable | **Done** — `isAppleAccountLinked()` on every call, memoized nowhere. Do not add a cache |
| 1.7 | Face ID / Touch ID login (*recommended*) | **Not done.** Recommended only; the app keeps a long-lived JWT session, so sign-in is rare |
| 1.8 | Follow the HIG | **Done** |
| 1.9 | Follow the developer marketing guidelines | **App done; needs TTP-2** for the web checkout button |

## 2. Onboarding merchants

| # | Req | Status |
|---|---|---|
| 2.1 | New user can discover account creation + Tap to Pay | **Done** — native signup, then the awareness modal and drawer entry |
| 2.2 | Fully digital onboarding, completed in-app on iPhone | **App done; blocked on TTP-1.** The app now routes Square OAuth into an in-app browser view, but the website still hides the connect links from the app and tells the merchant to open a browser. **This is the most likely rejection reason as it stands** |
| 2.3 | Onboarding under 15 minutes | **Done** — Square OAuth; seconds |

## 3. Enabling Tap to Pay on iPhone

| # | Req | Status |
|---|---|---|
| 3.1 | Highly visible, discoverable communication | **Done** — awareness modal + drawer entry |
| 3.2 | Full-screen modal splash (*recommended*; also marketing 6.2) | **Done** — `TapToPayAwarenessSheet`, once per device, eligible users only |
| 3.3 | Shown to all eligible users at least once | **Done** (modal). Push half is TTP-5 |
| 3.4 | Show how to enable at the end of merchant onboarding | **Done** — the awareness modal routes to `/tap-to-pay` |
| 3.5 | Clear action to accept the Terms and Conditions | **Done** — "Set up Tap to Pay on iPhone" → `linkAppleAccount()` |
| 3.6 | Enablement reachable outside comms/checkout (app settings) | **Done** — drawer → `/tap-to-pay` |
| 3.7 | Enablement trigger inside the checkout flow | **Done** — `ensureAppleAccountLinked()` runs inside the charge |
| 3.8 | Only an admin / authorized party may accept terms | **App done; needs TTP-3** for the authoritative answer |
| 3.8.1 | Unauthorized users told to contact an admin | **Done** — server-authored `message`, with app fallback copy |
| 3.8.2 | Apple Business Connect for enterprise (*conditional*) | **N/A** — public App Store distribution |
| 3.9 | "Try it out" screen after terms + education (*recommended*) | **Done** — the ready state says where to take a payment |
| 3.9.1 | Configuration progress indicator | **Done** — Square's reader callback → `TapToPayReaderStatus`, shown on the settings screen and as the checkout "initializing" view |

## 4. Educating merchants

| # | Req | Status |
|---|---|---|
| 4.1 | Use `ProximityReaderDiscovery` on iOS 18+ | **Done** — `TapToPayEducation.swift`. This one call also satisfies 4.4, 4.6, 4.7 and 4.8 |
| 4.2 | Education after terms acceptance | **Done** — presented immediately after `enable()` succeeds |
| 4.3 | Education in Settings or Help | **Done** — "How to take a payment", always present on `/tap-to-pay` |
| 4.4 | Toolkit assets for education outside the app (*conditional*) | **N/A in-app** (4.1 covers it). If web education is added, see TTP-6 |
| 4.5 | Show how to accept contactless cards | **Done** — 4.1; text fallback on iOS 17 and earlier |
| 4.6 | Show how to accept Apple Pay / digital wallets | **Done** — 4.1 |
| 4.7 | PIN entry + accessibility (required in US) | **Done** — 4.1 |
| 4.8 | Fallback payment method | **N/A** — US is not a fallback region |

## 5. Checking out

| # | Req | Status |
|---|---|---|
| 5.1 | Clearly visible, prominent button | **Done** — full-width `btn-lg` on the checkout page |
| 5.2 | Reachable without scrolling; top of the payment list | **Done**, but **verify on a small screen** — see TTP-2 |
| 5.3 | Button never altered/greyed; pressing it opens terms | **Done** — the button always fires; `ensureAppleAccountLinked()` raises the terms sheet if needed |
| 5.4 | Correct localized copy | **Needs TTP-2** — currently "Tap to Pay with card" |
| 5.5 | `wave.3.right.circle[.fill]` if using an icon | **Needs TTP-2** — currently a Bootstrap credit-card glyph. Fixed by removing the icon (5.5 is conditional on using one) |
| 5.6 | Tap to Pay UI within 1s, 90% of the time | **Needs TTP-3** — the warm-up is what makes this true |
| 5.7 | "Initializing" screen when pressed mid-configuration | **Done** — `_InitializingView` |
| 5.8 | "Processing" screen after the card read | **Done** — "Confirming payment…" |
| 5.9 | Outcome clearly stated (approved / declined / timed out) | **Done** — "Approved — $x" / "Payment declined … the card was not charged" |
| 5.10 | Digital receipt to the customer, approved **or** declined | **Done in app** (share sheet = Activity view); **TTP-4** upgrades it to Square's hosted receipt URL |
| 5.11 | Regional requirements | **N/A** — US only |

## 6. Marketing (required at launch, after general availability)

| # | Req | Status |
|---|---|---|
| 6.1 | Launch email from the toolkit template | **TTP-5** — backend/comms |
| 6.2 | In-app splash screen from the "Hero in-app banner" | **App done**, but the artwork/copy must be swapped for the toolkit's before launch marketing |
| 6.3 | Push notification using the toolkit's value-proposition copy | **TTP-5** — backend/comms |

---

## Declared not applicable: 1.2 and 1.3

Both are conditional on *"if your app uses Tap to Pay on iPhone as its primary
payment method"*. This app's primary purpose is an auction marketplace: the
overwhelming majority of its users are bidders who never take a payment, and
buyers pay their invoices online (PayPal / Square) rather than in person. Tap to
Pay is an admin-only feature for auction organizers collecting at an in-person
event.

Acting on 1.3 would mean adding `iphone-ipad-minimum-performance-a12` to
`UIRequiredDeviceCapabilities`, which blocks **installation of the entire app**
on iPhone 8, 8 Plus and X — devices that run iOS 16 and browse auctions fine.
Locking every bidder out of the app to satisfy a conditional requirement about a
feature they will never open is the wrong trade.

Say this explicitly in the entitlement submission rather than leaving the rows
blank. If the reviewer disagrees, the change is two lines in `Info.plist` plus
bumping `IPHONEOS_DEPLOYMENT_TARGET` to 16.4 in `project.pbxproj`.

---

## Before submitting

1. **Land TTP-1, TTP-2, TTP-3** (`BACKEND_SPEC.md`). TTP-1 and TTP-2 are
   template edits; TTP-3 is one new read-only endpoint.
2. **Add the entitlement to `ios/Runner/Runner.entitlements`** —
   `com.apple.developer.proximity-reader.payment.acceptance` — but **only after
   Apple grants it**. Adding it early means cloud signing can't build a profile
   that carries it and every export fails. The file already has a comment
   marking the spot.
3. **Download the Marketing Guide and Toolkit** (access page + password on p. 23
   of the review guide PDF) and swap the toolkit's hero banner and approved copy
   into `tap_to_pay_awareness.dart`.
4. **Optional:** export `wave.3.right.circle.fill` from the SF Symbols app into
   `assets/tap_to_pay/` and set `tapToPaySymbolAsset` — see
   `lib/widgets/tap_to_pay_branding.dart`.
5. **Record the three videos** Apple asks for. Note the guide's warning: *use a
   second device to film the checkout flow* — the Tap to Pay screens are
   excluded from screen recording and will come out blank.
   - Onboarding: account creation → Square connect → merchant approved.
   - Enabling + education: awareness modal → terms → Apple's education sheet →
     where to find education later (the drawer) → configuration progress.
   - Checkout: enter an amount → the Tap to Pay button → initializing screen →
     a successful tap.
6. **In App Store Connect**, declare the Tap to Pay entitlement, describe the
   use case (in-person auction checkout by auction organizers), and supply a
   test account with admin rights on an auction that has Square connected.
   Don't mention MDM, and don't put "Tap to Pay on iPhone" in the app name
   (App Review Guideline 5.2.5).

## Testing notes from the guide

- To re-trigger the merchant Terms and Conditions on a device, unlink the Apple
  Account that accepted them (via Apple Business Connect) — you don't need a new
  merchant account.
- To re-test the configuration progress indicator from scratch, uninstall *all*
  Tap to Pay apps from the iPhone; that clears the device's payment-acceptance
  configuration.
- Xcode 14.3+ can simulate the Tap to Pay UI in the Simulator.
