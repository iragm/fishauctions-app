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

Rule 1 is easy to break by reflex, and was broken in three places until
2026-08-30 — caught while reviewing the shot list for the entitlement video,
which is to say one review pass short of shipping it to Apple. Material's
`Icons.contactless` / `Icons.contactless_outlined` sat on the drawer entry, the
setup status card, and — worst — the **"Set up Tap to Pay on iPhone" button
itself**, which is precisely the control requirement 5.5 governs. Meanwhile
`tap_to_pay_branding.dart` had spelled out that this exact glyph is forbidden.
Documenting a rule is not enforcing it: `grep -rn "Icons.contactless" lib/`
before any Tap to Pay screenshot or recording.

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
| 2.2 | Fully digital onboarding, completed in-app on iPhone | **Three faults, all found by filming it; one fixed.** *Fixed 2026-09-01:* the browser view carries Safari's cookies, not ours, so `/square/connect/` bounced the merchant to the web login form mid-flow — the app now opens it through an `auth/web-session/` handoff so the browser view has a real session. *Open:* the flow still ends by stranding the merchant on auction.fish with only the system Done button (`BACKEND_SPEC.md` Part TTP-7, revised — it was recorded as cosmetic and is not). *Open:* a new organizer cannot start it at all until a site admin trusts them, see "Declared: the trust gate" below |
| 2.3 | Onboarding under 15 minutes | **Seconds once started**, but end to end it includes waiting for a human to press "Trust this user". Declared below rather than claimed as a clean pass |

## 3. Enabling Tap to Pay on iPhone

| # | Req | Status |
|---|---|---|
| 3.1 | Highly visible, discoverable communication | **Done** — awareness modal + drawer entry |
| 3.2 | Full-screen modal splash (*recommended*; also marketing 6.2) | **Done** — `TapToPayAwarenessSheet`, eligible users only, once per **install** and marked when the merchant *dismisses* it. Both halves of that were wrong until 2026-08-30: it marked on delivery rather than acknowledgement, into the Keychain, which survives app deletion — so any way of failing to present it was permanent, unresettable, and looked identical to being ineligible |
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
| 4.1 | Use `ProximityReaderDiscovery` on iOS 18+ | **Done — verified on device 2026-08-30** (iPhone, iOS 26, development-signed build): Apple's sheet presents, no error. Carries 4.4, 4.6, 4.7 and 4.8 with it. Note it does **not** work in a TestFlight build — the entitlement gates education too |
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

## Declared: the trust gate on accepting payments

`UserData.is_trusted` gates promoting an auction, **accepting payments**, and
sending invoice emails, and a superuser turns it on with a "Trust this user"
button on the auction ribbon. Separately `UserData.square_enabled` (defaulted
from `SQUARE_ENABLED_FOR_USERS`, itself `False`) gates the Square connect entry
points. Neither is set for a brand-new account.

**Keep it.** A marketplace that lets anyone who signs up start an OAuth flow to
collect money from strangers has a fraud problem, not a compliance win, and
Apple's own 3.8/3.8.1 contemplate exactly this shape of control — an
authorization model where an unauthorized user is told to contact an admin.
Platform-side risk review before enabling payment acceptance is ordinary; the
2.x requirements are aimed at legacy merchant acquiring (fax a form, wait three
days, receive a terminal), not at KYC.

**Two things about it are worth being straight about, and neither is its
existence.**

1. **2.3's "under 15 minutes" is not a clean pass** while a human has to press a
   button, so the row above says so rather than claiming seconds. Say it in the
   submission: onboarding is seconds of merchant effort, gated by a review step
   the platform performs. Declaring it is cheaper than having a reviewer find it.
2. **The gate is currently invisible, which is the part Apple would actually
   object to.** With `square_enabled` false there is no "pending approval"
   anywhere: the Preferences menu has no Square item, the auction banner doesn't
   render, and `SquareConnectView` only errors if you reach the URL by hand. The
   merchant meets a dead end and concludes the feature doesn't exist. The site
   already solves this for *promotion* — an untrusted creator gets
   `untrusted_message` plus a "Contact us and request access" button — and Square
   should do the same. Specced as `BACKEND_SPEC.md` Part TTP-9.

**Do not disable it to film the videos.** Pre-approve the test account instead,
and give video 1 one line of narration acknowledging the review step. Filming the
approval itself would make a human in the loop the centrepiece of the onboarding
video, which invites the scrutiny the written declaration handles better.

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

## Building and testing this

**Entitlement: already done, and only in the debug file.**
`com.apple.developer.proximity-reader.payment.acceptance` is in
`RunnerDebug.entitlements` and deliberately **not** in `Runner.entitlements`.
The development entitlement Apple granted enables the capability for
*development* provisioning profiles, which is what a Debug build signs with — so
a real charge on a tethered iPhone works today. A *distribution* profile only
carries it once the publishing entitlement is granted; adding the key to
`Runner.entitlements` before then breaks every Release/TestFlight export, since
cloud signing can't build a profile that satisfies it. Add it there on the day
the publishing grant arrives.

**Every part of this needs the entitlement, education included** (established on
hardware 2026-08-30 — this paragraph used to claim the opposite, and see
"The education sheet does not present" below for how that was worked out).
`ProximityReaderDiscovery` presents education rather than a card reader and
Apple's documentation for it never mentions an entitlement, which is where the
wrong conclusion came from — but in a TestFlight build `content(for:)` fails
with `ContentError.unknown`, and the identical build signed with a *development*
profile presents Apple's sheet normally. So none of the entitlement-review
videos is recordable from a distribution build, and the way to record them
before the publishing grant is `ios-release.yml` with
`export_method: development` (see `IOS.md`).

### The education sheet does not present in a distribution build (resolved 2026-08-30)

On a prod TestFlight build on **iOS 26**, "How to take a payment" shows the
Flutter `_EducationFallbackSheet` rather than Apple's sheet. That is a review
blocker, not a cosmetic one: from iOS 18 requirement 4.1 makes Apple's sheet
mandatory, and the fallback is exactly the hand-written Tap to Pay copy the
guide forbids as a substitute.

What is already ruled out: the method channel is wired on both sides and its
name matches (`com.fishauctions.app/platform`), the Swift compiles (CI archives
it every release, so the `ProximityReaderDiscovery` API surface as written is
real), and `#available(iOS 18.0, *)` passes on 26. So it is a runtime failure
inside `TapToPayEducationPresenter.present`, leaving three candidates: the
presenting view controller resolved to nil, `content(for:)` threw, or
`presentContent(…)` threw.

**One of those was a real defect and is fixed.** The controller was resolved as
`connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController`,
which is wrong three ways: `connectedScenes` is a **`Set`**, so `.first` picks an
arbitrary scene rather than the one on screen; a backgrounded or unattached
scene has no key window, so the whole chain can yield nil while the app is
plainly visible; and presenting from a controller that is *already* presenting
throws rather than stacking. `presentingViewController()` now prefers a
`.foregroundActive` scene, falls back through `.foregroundInactive`, takes the
key window or the scene's first window, and walks `presentedViewController` to
the top. Suspicion was already pointing here: Flutter 3.44's `SceneDelegate`
lifecycle has broken one thing in this app the same way (the Google OAuth
callback; see `IOS.md`).

**And we were discarding the answer to the other two.**
`PlatformBridge.presentTapToPayEducation` collapsed every `PlatformException`
into `'failed'` and the screen showed the fallback silently, so nothing about
the cause survived — and with no debugger on a TestFlight build there is no
console to recover it from. Now: the Swift names the step that failed
(`education_failed_content` vs `education_failed_present`, two failures with
nothing in common — a regionalized fetch from Apple versus UIKit presentation)
and reports `String(describing:)` plus the bridged `NSError` domain and code
alongside `localizedDescription`, which on its own flattens to "The operation
couldn't be completed" for any error that isn't `LocalizedError`.
`PlatformBridge.lastTapToPayEducationError` keeps it, `TapToPayService`
`debugPrint`s it, and `/tap-to-pay` prints it in red under the education button
whenever the fallback is used.

**Result of that build (2026-08-30): `education_failed_content` — "unknown",
`ProximityReaderDiscovery` content error 5.** So presentation is never reached
and the view-controller defect above was not the cause (it was still a real one;
keep the fix). The failure is Apple's regionalized content *fetch*, and the case
is literally `unknown`, meaning the framework itself couldn't classify it — no
further detail is coming from that channel.

**The error enum does most of the elimination for us.** Apple documents
`ProximityReaderDiscovery.ContentError` with six cases, and — read in
declaration order, which matches the bridged code 5 — `unknown` is the last of
them:

| # | Case | Apple's text |
|---|---|---|
| 0 | `contentNotFound` | "the requested content isn't available" |
| 1 | `contentDisplayFailed` | "an issue occurred when trying to display" |
| 2 | `notSupported` | "the current device doesn't support the requested content" |
| 3 | `networkUnavailable` | "the system can't reach the network" |
| 4 | `systemBusy` | "the system is busy" |
| 5 | `unknown` | "the framework encountered a problem that the system can't interpret" |

That matters more than it looks. Three of the innocent explanations have their
**own dedicated cases** — an unsupported device is `notSupported`, no network is
`networkUnavailable`, no content published for this country is
`contentNotFound` — and we got none of them. Reproduced on a retry, so
`systemBusy` is out too. `unknown` is Apple's catch-all for a failure the
framework itself cannot classify, which is what a refusal from underneath it
looks like.

Two independent confirmations from outside: Apple's own `ProximityReaderDiscovery`
overview never mentions an entitlement, but Stripe's Tap to Pay integration
documents merchant education *after* "request and configure the Tap to Pay on
iPhone development entitlement", i.e. it is only ever described working inside an
entitled app; and Apple's provisioning answer on the forums is that an approved
team's managed entitlement is "configured only for the Development distribution
type", with any other type failing.

So **the entitlement is the leading explanation**, and the claim in
`TapToPayEducation.swift` and in "Most of the new code needs no entitlement at
all" below is probably **wrong**: education is as gated as the reader, and *no*
part of Apple's three videos is recordable from a distribution build.

**Verdict: it was the entitlement.** The same commit, signed with a
*development* profile carrying `RunnerDebug.entitlements` and installed on the
same iPhone, presents Apple's sheet with no error at all. Nothing about the code
changed between the two runs. `ContentError.unknown` is what a distribution
build gets, which is worth remembering because it names none of the six things
that are actually wrong.

Two pieces of instrumentation from the hunt are worth keeping rather than
reverting. The presenter still names the failing step
(`education_failed_content` vs `education_failed_present`) and reports
`String(describing:)` plus the bridged `NSError` domain and code, since
`localizedDescription` alone flattens to "The operation couldn't be completed".
And it still appends `contentList=<n>` to a content-step failure — Apple
documents that list as *"specific to the country of the current device"*, so it
separates an entitlement refusal from a region with no published content, which
is exactly the distinction that cost two build cycles here.

The view-controller fix in the same commit was a genuine defect and is
independently confirmed by Stripe's integration guide (*"Pass the topmost
presented view controller… otherwise the call fails"*), but it was not this bug.

**If it is the entitlement, the fix is one build, not a Mac.** A development or
ad-hoc profile can carry `com.apple.developer.proximity-reader.payment.acceptance`
today (the grant landed 2026-07-31) — what Apple withholds is a *distribution*
profile. Apple will not issue a development profile to a team with zero
registered devices, which is the only reason this pipeline ad-hoc signs its
archive, so the sequence is: get the iPhone's UDID (Apple Devices app on
Windows, or Apple Configurator on an iPad — iOS Settings shows the serial, not
the UDID), register it under Devices in the developer portal, have
`ios-release.yml` export `method: development` with
`CODE_SIGN_ENTITLEMENTS = Runner/RunnerDebug.entitlements`, and install the
result over the air via an `itms-services` manifest. Note that build gets
`aps-environment: development`, so its push tokens are sandbox ones — fine for a
test build, wrong for anything else.

That build is worth having regardless of what it proves here: it is also the
only way to record video 3, since a real tap needs the same entitlement.

**This also puts a load-bearing claim in doubt.** The paragraph below says the
education flow is exercisable in any build because no entitlement is involved —
which is what makes the entitlement-review videos recordable before the grant.
If the reason turns out to be the entitlement, that is false, and every one of
Apple's three videos needs a development build, i.e. a Mac.

**What you need:** a Mac with **Xcode 16 or later** (the education API is in the
iOS 18 SDK; it's `@available`-guarded, so the deployment target stays 16.0), and
a **physical iPhone XS+ on iOS 16.4+** — Tap to Pay does not work in the
Simulator. `TapToPayEducation.swift` is already registered in `project.pbxproj`,
so no Xcode file-adding step. No new pods.

```bash
flutter run -t lib/main.dart --dart-define=FLAVOR=staging
```

**How to reach the Tap to Pay UI — and the back door that isn't one.** There are
three entry points and **all three are gated on the backend calling this user a
merchant**; nothing reaches `/tap-to-pay` otherwise.

- drawer → "Tap to Pay"
- command palette → "tap to pay" (also "card", "payment")
- the awareness modal, when `auction_ribbon.html` calls `tapToPayOffer`

This section used to say the palette row "matches by name regardless of
eligibility, precisely so this is testable now". **That was never true of the
shipped backend** and it cost a debugging session on 2026-08-29.
`_app_deep_link_items` in `auctions/command_palette.py` emits the row only when
`request.is_mobile_app` **and** `PaymentService._user_can_take_payments(user)`,
and the code comment says why in as many words: *"Deliberately the same check the
app's Tap to Pay warm-up endpoint makes, so the palette can't offer a row that
the screen behind it turns around and refuses."*

So an empty palette search for "tap to pay" is a real signal, and it means one of
three things — worth checking in this order:

1. **The deployment is running a backend older than the palette row.** Check
   prod separately from staging; they are not the same code.
2. **The `is_mobile_app` User-Agent marker isn't reaching the middleware**
   (`auctions/middleware.py:35`). This would also silently kill the awareness
   modal and every other `is_mobile_app` branch on the site.
3. **The account isn't a merchant.** Least likely on a site owner's login —
   `_user_can_take_payments` short-circuits to True for any superuser.

## Before submitting

1. **Land TTP-1, TTP-2, TTP-3** (`BACKEND_SPEC.md`). TTP-1 and TTP-2 are
   template edits; TTP-3 is one new read-only endpoint.
2. **Copy the entitlement into `ios/Runner/Runner.entitlements`** —
   `com.apple.developer.proximity-reader.payment.acceptance`, already present in
   `RunnerDebug.entitlements` — **only once the publishing entitlement is
   granted**. Before that it breaks Release/TestFlight signing; see "Building
   and testing this" above.
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

## App Store Connect

Nothing needs changing in ASC to **build or test** this, and nothing there
affects the publishing entitlement — that review is a separate track (the
entitlement request form and email, with videos and the checklist above).
ASC matters only at App Store submission, and it's all metadata, no config
toggles.

Note that **apps submitted with a Tap to Pay entitlement get a special review**
by the App Store Review team on top of the normal one, so the notes below are
read closely rather than skimmed.

**App Review Information → Notes.** There's no dedicated Tap to Pay field; the
guide's requirements are all satisfied by what you write here:

- Declare that the app uses the Tap to Pay on iPhone entitlement.
- Describe the use case — "point-of-sale for auction organizers collecting
  payment in person at club auctions".
- State the release method if you ship behind a feature flag.
- **Don't mention MDM.** The guide warns it flags the app for unnecessary
  review.

**App Review Information → test account.** Must be an account with **admin
rights on an auction that has Square connected** — otherwise the reviewer can't
reach the checkout page, the Tap to Pay button, or (once TTP-3 lands) the
setup screen, since all three are gated on being a merchant. A plain bidder
account will get the app rejected as unreviewable. Not geo-fenced, so there's
nothing to declare there.

**Attachment.** Upload either a video walkthrough of the checkout experience
*from sign-in to checkout*, or high-fidelity wireframes of it. The checkout
video from the entitlement review can be reused — same warning applies, film it
with a second device, the Tap to Pay screens don't screen-record.

**App name and product page.** The name must not contain "Tap to Pay on
iPhone" (Guideline 5.2.5) — `auction.fish` is fine. If you add Tap to Pay
messaging to the product page or screenshots it must use Marketing Guide
assets, and the guide says to hold that until the feature is in full general
availability.

**Privacy policy URL** — point it at `https://auction.fish/privacy/`. That page
now exists (`PrivacyPolicyView`), as does account deletion; both were open
blockers as recently as 2026-07-29 and are not any more.

**App Privacy questionnaire.** Worth a pass before submitting: it's
authoritative for the nutrition label (which is why `PrivacyInfo.xcprivacy`
deliberately omits `NSPrivacyCollectedDataTypes`). Tap to Pay itself collects
nothing you declare — Square captures the card on-device and we never see card
data — but location, contact info and user content are all collected and need
to be accurate.

**Guideline 4.8 (Login Services) — app side now done.** The app previously
offered only Google, with no Sign in with Apple, which 4.8 requires whenever a
third-party service sets up the primary account. Sign in with Apple is now
implemented, and comes first on iOS per its guidelines. (Facebook sign-in was
implemented alongside it and removed again on 2026-08-10 — Facebook doesn't
verify the emails it returns — which changes nothing for 4.8: Google alone
still triggers the requirement, and Apple still satisfies it.) Two things still
gate it: the **Sign In with Apple capability** must be enabled on the App ID in
Certificates, Identifiers & Profiles — it's self-serve, but until it's on, every
signed build fails provisioning because `Runner.entitlements` now declares
`com.apple.developer.applesignin` — and the backend half is `BACKEND_SPEC.md`
Part SOCIAL. Apple also requires that deleting an account **revokes the Apple
grant** (SOCIAL-6), which ties into the account-deletion page that already
exists.

### Draft App Review Information → Notes

Paste this into App Store Connect and fill the four placeholders. It is written
to answer, without the reviewer having to ask: what the app is, why sign-in is
required, that the Tap to Pay entitlement is in use and for what, the exact taps
that reach every gated screen, where account deletion lives, and how UGC is
moderated. It deliberately does not mention MDM — the guide warns that flags the
app for unnecessary review.

```text
WHAT THIS APP IS
auction.fish is the companion app for auction.fish, a free web platform that
aquarium and pond hobby clubs use to run their auctions. Members bid on and sell
fish, plants and coral; club organizers run the auction itself. The app is a
shell around the same signed-in website, plus the hardware the web cannot reach:
Bluetooth thermal label printing, camera lot-label scanning, and Tap to Pay on
iPhone.

SIGN-IN IS REQUIRED
There is no signed-out mode. The demo account below administers a club and an
auction, so it can reach every part of the app.

  Username: <DEMO USERNAME>
  Password: <DEMO PASSWORD>

TAP TO PAY ON iPHONE
This app uses the Tap to Pay on iPhone entitlement
(com.apple.developer.proximity-reader.payment.acceptance).

Use case: point of sale for auction organizers collecting payment from buyers in
person at the end of a club auction. Buyers settle their invoice at a check-out
table, which today means cash or a separate card terminal. Payments are processed
by Square, which each club connects to its own Square account; the app never sees
card data.

Availability: the feature is limited to users who administer an auction or club
with a connected, in-person-capable Square account. That is a small minority of
our users -- the great majority are bidders -- so these entry points do not
appear for an ordinary account. The demo account above is an organizer and sees
all of them.

HOW TO REACH IT
Tap to Pay on iPhone requires iPhone XS or later on iOS 16.4 or later and does
not run in the Simulator.

1. Sign in with the demo account above.
2. Side menu (top left) -> "Tap to Pay". This is the setup and education screen:
   terms acceptance, Apple's education sheet, "How to take a payment", and the
   reader configuration progress indicator.
3. To take a payment: open <DEMO AUCTION NAME> -> "Quick checkout" -> choose
   <DEMO BIDDER NAME>. Their invoice loads with "Tap to Pay on iPhone" at the
   top of the payment options. Several $1.00 invoices are waiting (Square's
   minimum charge) so the flow can be repeated; an invoice is marked paid once
   it is charged. Charges are real and we refund them, so please charge as often
   as you need to.
   Note the ordinary Invoices list is not the route -- the card reader is on the
   quick checkout screen, which is the in-person checkout desk.
4. The full-screen awareness modal appears once per device, on an auction page,
   for an organizer whose club has Square connected.

A video walkthrough from sign-in through checkout is attached. The Tap to Pay
screens themselves cannot be screen-recorded, so it was filmed with a second
device.

ACCOUNT DELETION
Side menu -> Preferences -> "Delete my account", or auction.fish/account/delete/.
Deleting an account also revokes the Sign in with Apple grant.

USER-GENERATED CONTENT
Lot names, descriptions, photos and chat messages are written by members. Club
and auction administrators can hide chat messages, remove lots and ban users from
their auctions; any member can ban another member from bidding on their lots.
Site administrators can remove any content or account.

PERMISSIONS
Nothing is requested at launch; each is asked for in context.
- Location: distance to nearby auctions, automatic check-in on arrival at an
  in-person auction, and the location of an in-person card charge, which Square
  requires.
- Camera: reading lot-label QR codes to find a lot in the room, and photographing
  lots for sale.
- Bluetooth: connecting to the seller's own thermal label printer.
- Microphone and Speech Recognition: an organizer calls out lot numbers, bidder
  numbers and prices to record sales hands-free while running an auction. Speech
  is processed on device where the phone supports it.
```

## Testing notes from the guide

- To re-trigger the merchant Terms and Conditions on a device, unlink the Apple
  Account that accepted them (via Apple Business Connect) — you don't need a new
  merchant account.
- To re-test the configuration progress indicator from scratch, uninstall *all*
  Tap to Pay apps from the iPhone; that clears the device's payment-acceptance
  configuration.
- Xcode 14.3+ can simulate the Tap to Pay UI in the Simulator.
