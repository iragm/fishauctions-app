# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part N — Notification opt-in (`notifications/prefs/` + a template hook)

**Why:** the app used to raise the OS notification permission dialog from
`PushService.init`, i.e. seconds after launch, before the user had been told what
they'd be notified about. That's now gone (2026-07-29). The prompt is raised only
from places where the answer means something, and "Enable" always performs the
same three steps:

1. the OS notification permission,
2. an FCM token registered against this device (`devices/register/`), and
3. **both** server-side toggles — `UserData.push_notifications_instead_of_email`
   and `UserData.push_notifications_when_lots_sell`.

Step 3 is the part the backend owes. Without it the app can only ask for the
permission and then tell the user to go finish on `/preferences/` — which is a
poor experience made worse by the fact that the preferences form *disables*
`push_notifications_instead_of_email` until the account has a device with a live
token (`UserData.has_push_device`), so a user who has only granted the permission
finds the checkbox they were sent to greyed out until the page is reloaded.

### N1. `GET`/`PATCH /api/mobile/notifications/prefs/`

Auth: `IsMobileAuthenticated`. Throttle: `mobile_api`.

```
GET  → 200 { "push_instead_of_email": false, "push_when_lots_sell": false }

PATCH { "push_instead_of_email": true, "push_when_lots_sell": true }
     → 200  (same shape, reflecting stored state)
```

* Both keys optional on `PATCH`; only the ones sent are written (partial update).
* Writes `request.user.userdata`. No other side effects.
* Do **not** refuse the write when `push_configured()` is false or the user has no
  device — store the intent. The app has already registered the device by the time
  it PATCHes (`PushService.enable` awaits the registration before the prefs write
  precisely so this ordering holds), and a stored preference that can't be
  honoured yet is exactly what the web form already does.
* 404 is reserved for "this backend build predates the endpoint": the app then
  self-disables the prefs write for the process and falls back to sending the user
  to `/preferences/`. So there's zero behavior change until this ships.

App side: `lib/services/notification_prefs_service.dart` (done, degrades on 404).

### N2. The in-person lot page hook

The app raises the offer itself on `/preferences/` — it can match that URL. It
**cannot** tell that a lot page belongs to an in-person auction, and deliberately
doesn't try to guess (no extra round trip per lot page). The page tells it, via a
JS bridge the shell already registers:

```js
// Only inside the app — guard on the bridge existing.
if (window.flutter_inappwebview?.callHandler) {
  // Soft banner over the page, at most once per device. Fire on load for a lot
  // in an in-person auction that hasn't closed.
  window.flutter_inappwebview.callHandler('pushPromptOffer', 'lot_selling_soon')
    .then(r => { /* { offered: bool } */ });
}
```

Suggested gate, all server-side: `lot.is_part_of_in_person_auction` and the
auction isn't over, and (optionally) the user watches the lot. Everything about
*when* to ask stays in the template, which is the point.

Two more handlers are available for the preferences page, so it can render a real
control instead of relying on the app's banner:

```js
// {supported, permitted, prefs_endpoint} — e.g. show "Notifications are on for
// this phone" instead of a disabled checkbox with no explanation.
callHandler('pushGetState')
// Runs the full opt-in now (for an explicit button tap, no banner), resolving
// with the same state object afterwards.
callHandler('pushEnable', 'preferences')
```

`supported: false` means this build/deployment has no push config at all — the
right copy then is the existing "install the app" text, not "allow
notifications".

---

## Part L — Terms & privacy policy links (App Store requirement)

Apple requires an app that offers account registration to link its **terms** and
**privacy policy** from inside the app, at the point of sign-up — not only from
the App Store listing. Today: `/tos/` exists (`UserAgreement`), **there is no
privacy policy page at all**, and `account/signup.html` links to neither. The
signup page renders inside the app's WebView with the site chrome dropped for the
mobile user agent, so the `base.html` footer link isn't there either.

The app now draws both links natively on the login and signup screens
(`lib/widgets/legal_links.dart`), which unblocks submission for terms. Three
backend items complete it:

### L1. Publish a privacy policy page — **submission blocker**

A normal page (any path; `/privacy/` suggested). Until it exists the app shows
**no** privacy link — deliberately, rather than a dead one — and the app cannot
be submitted.

### L2. `GET /api/mobile/config/` gains two keys

```json
{
  "terms_url":          "/tos/",
  "privacy_policy_url": "/privacy/"
}
```

Absolute URLs are fine — the app reduces a same-host absolute URL to its path and
**rejects an off-host one** (these pages load inside the signed-out login trap, so
an arbitrary host would be a way out of it). Omitted/empty: `terms_url` falls back
to `/tos/`, `privacy_policy_url` to "no privacy link". Public values, consistent
with everything else in that endpoint.

### L3. Link both from `account/signup.html`

Under the submit button, in the template, so the web signup page carries them too.
The app allow-lists both paths in the signup WebView, so they open **in place**
rather than kicking the user out to Safari mid-form.

---

## Part D — Account deletion (App Store requirement)

**Answer to "do we need this?": yes, and it's mandatory rather than a nice-to-have.**
App Store Review Guideline 5.1.1(v) has required, since June 2022, that any app
supporting account *creation* also support account *deletion* initiated from
inside the app. There is currently no way to delete an account anywhere —
website or app — so this is a hard blocker for the iOS submission, and Google
Play's Data deletion policy asks for the same thing (it accepts a web URL, so
one page satisfies both stores).

"Initiated from inside the app" is satisfied by a **web page reachable in the
WebView** — it does not have to be native, and shouldn't be: this is
account-lifecycle business logic, which belongs on the server by this project's
own architecture rule. What Apple rejects is deletion that requires emailing
support or leaving the app to find a form.

### D1. A deletion page, linked from `/preferences/`

Suggested `/account/delete/`:

* Explains what is deleted and what is retained, in plain language.
* Requires a deliberate confirmation (password re-entry, or typing the username).
* Does the deletion (or schedules it) and signs the session out.

Because it lives on `/preferences/`, which is already in the app's WebView, **no
app change is needed** — the app follows the link like any other page, and the
app's own `/logout/` interception already turns the resulting web sign-out into a
full native sign-out (JWT + cached profile + WebView cookies + offline data +
push token). One thing to get right: the deletion flow must end at `/logout/` or
otherwise drop the session, or the app will sit on a signed-in shell for an
account that no longer exists.

### D2. What "delete" should mean here

This is a product decision, not something the app can imply, but the constraints
worth writing down:

* **Auction history can't simply vanish.** Bids, invoices, and sold lots are
  other people's records too — a seller's payout history referencing a deleted
  buyer still has to make sense, and clubs need their own past auctions intact.
  Anonymize-in-place (`AuctionTOS` keeps the bidder number and the amounts, loses
  the name/email/account link) is the usual answer and matches how the codebase
  already soft-deletes.
* **Personal data must actually go**: `User` (email, username, password),
  `UserData` (address, coordinates, preferences), `MobileDevice` rows and their
  FCM tokens, `ClubMember` PII, chat authorship, marketing-list membership
  (Brevo/Mailchimp both need an explicit contact delete — see
  `auctions/brevo.py`).
* **Say which it is on the page.** "Your account and personal details are
  deleted; past auction results stay in the auction's records without your name
  attached" is honest and Apple accepts it. What gets rejected is a page that
  quietly does less than it says.
* A grace period (e.g. 30 days, reversible by signing in) is allowed and worth
  having given the above is irreversible.

### D3. Optional: `POST /api/mobile/account/delete/`

Not needed for compliance if D1 exists, and **not** recommended as the primary
path — the confirmation UX belongs on the web. Only worth adding if the app ever
needs to offer deletion while the WebView can't load.

---

## Part S — Rename "AR" to "Lot scanning" in user-facing web copy

The app now calls the feature **"Lot scanning"** everywhere the user can see it
(2026-07-29). "AR" survives only in things users never read: the
`fishauctions://ar/<slug>` deep-link scheme, the `/api/mobile/ar/*` endpoints,
`?src=ar`, and Dart/Python identifiers. **None of those need to change** — this is
a copy change only, and the two sides currently disagree.

Reason for the rename: "AR" describes the technique, not the job. The feature
finds lots. Users looking for it search for "scan"; nobody looking for their lot
thinks "I want augmented reality". (The app's command palette still *matches* the
queries `ar` and `augmented reality` as aliases, so the old vocabulary keeps
working.)

Web strings to change — every place the word is shown, not the links themselves:

* The auction rules page button that emits `fishauctions://ar/<slug>` — e.g.
  "Scan lots with AR" → **"Scan lots"**.
* The lot page's "Locate with AR" → **"Find this lot"**.
* The "Back to AR" bar rendered for `?src=ar` → **"Back to scanning"**.
* Admin-facing map/observation pages and any help text that says "AR mode" →
  "lot scanning".
* The `/preferences/` and rules-page help text describing the feature.

No app release is needed for any of this.

---

## Part A — Apple Wallet membership cards (no backend work; two polish notes)

The app now hands a downloaded `.pkpass` to Apple's own **Add to Apple Wallet**
sheet (`PKAddPassesViewController`, `ios/Runner/WalletPassPresenter.swift`)
instead of the generic file-preview path, so tapping the existing "Add to Apple
Wallet" button on `partials/club_member_uuid_card.html` behaves the way it does
in Safari: one sheet, one "Add", done. The backend side already works as-is —
`Content-Disposition: attachment` plus `application/vnd.apple.pkpass` is exactly
what the app's download interception keys on. **Nothing is required here.**

Two things that would improve it, both template-only:

1. **Hide the Google Wallet button on iOS** (and Apple's on Android). Both are
   rendered unconditionally today; in the app the Google Wallet save URL opens in
   the system browser, so on an iPhone it's a button that leaves the app to do
   nothing useful. The app's user agent (`FishAuctionsApp/1.0 (Flutter; iOS)`)
   already distinguishes the platform, alongside the existing `is_mobile_app`
   check.
2. **The `apple_wallet_enabled` explainer is aimed at a web reader.** Inside the
   app, "or just take a screenshot" reads oddly next to a working Wallet
   integration on the same phone. Worth a mobile-app variant, or hiding the stub
   button entirely when Apple Wallet isn't configured.

---

## Notes on this document

Earlier parts (printing profiles, push pipeline, AR mapping v1, offline sync,
proximity check-in, the last-used-auction lookup) were removed once the backend
implemented them — `git log` on this file has the history. Several `CLAUDE.md`
references to "Part 1 / Part 6 / Part T / Part W" point at that removed content;
the code and `auctions/mobile/urls.py` are the truth.
