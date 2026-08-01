# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---


## Notes on this document

Earlier parts (printing profiles, push pipeline, AR mapping v1, offline sync,
proximity check-in, the last-used-auction lookup) were removed once the backend
implemented them — `git log` on this file has the history. Several `CLAUDE.md`
references to "Part 1 / Part 6 / Part T / Part W" point at that removed content;
the code and `auctions/mobile/urls.py` are the truth.

---

## Part TTP — Tap to Pay on iPhone: App Store / entitlement review

Source of requirement numbers: Apple's *Tap to Pay on iPhone — App & Marketing
Requirements and Review Guide*, **v1.6, March 2026**. Apple grants the
**publishing** entitlement (the one TestFlight and the App Store need) only
after reviewing the app against that checklist; the development entitlement we
already hold does not cover distribution.

The app side of everything below is implemented. These are the pieces that live
in Django, each with the checklist item it unblocks. The app degrades gracefully
without every one of them — nothing here breaks the existing charge flow — but
**TTP-1, TTP-2 and TTP-3 are review blockers**, not polish.

### TTP-1 (blocker, requirement 2.2 + General Requirements) — merchant onboarding must work inside the app

Today `auctions/templates/auctions/square_seller.html` hides the "Connect your
Square account" links whenever `request.is_mobile_app` and shows a banner telling
the user to open the website in a browser instead. Apple's General Requirements
say an app using Tap to Pay "must function independently of any additional
secondary apps ... a merchant should be able to open your app and navigate
through the Tap to Pay on iPhone onboarding and checkout process without needing
other apps", and requirement 2.2 requires "a fully digital onboarding experience
within the app ... fully completed on an iPhone". Sending the merchant to Safari
fails both, and it is the first thing the entitlement reviewer's onboarding video
would show.

**Change:** drop the `request.is_mobile_app` gating in `square_seller.html` (and
`paypal_seller.html`) so the connect/reconnect links render in the app, and
delete the "not available in the app" banner.

The app already handles the rest: `_openExternally` in `webview_screen.dart` now
routes Square/PayPal OAuth hosts — and our own `/square/connect/`,
`/paypal/connect/` paths — into an **in-app browser view**
(`SFSafariViewController` on iOS, Chrome Custom Tabs on Android) rather than the
system browser. That surface is what Apple counts as in-app, and it shares
Safari's cookie jar, so a merchant whose Square login is "Sign in with Google"
still works — which is exactly what would *not* work if this were loaded in the
shell's own WebView, since Google blocks its sign-in in embedded WebViews.

**Nice-to-have on top:** have `square_callback` (`/square/onboard/success/`)
render a "Return to the app" button pointing at `fishauctions://square-connected`.
Without it the merchant finishes OAuth in the browser view and has to press Done
themselves. Not a blocker; the flow completes either way.

### TTP-2 (blocker, requirements 5.4 + 5.5 + 1.9) — the checkout button's copy and icon

`auctions/templates/auctions/quick_checkout_htmx.html` currently renders:

```html
<a href="fishauctions://pay/{{ invoice.pk }}" class="btn btn-primary btn-lg w-100 my-2">
  <i class="bi bi-credit-card-2-front"></i> Tap to Pay with card
</a>
```

Two violations:

- **Requirement 5.5** — "When using iconography in the button, the symbol must
  be either `wave.3.right.circle` or `wave.3.right.circle.fill` from SF
  Symbols." A Bootstrap credit-card glyph is not that. The marketing rules
  separately forbid creating icons that depict Tap to Pay on iPhone, so
  substituting another wave-ish glyph is not a fix.
- **Requirement 5.4** — the label must come from the guide's localization table.
  English is **"Tap to Pay on iPhone"** (long form) or **"Tap to Pay"** (short
  form). "Tap to Pay with card" is neither.

**Change:** drop the `<i>` entirely (5.5 is conditional on *using* iconography,
so no icon means it does not apply) and set the label to `Tap to Pay on iPhone`.
The app takes the same approach — see `tapToPaySymbolAsset` in
`lib/widgets/tap_to_pay_branding.dart` for how to add the real SF Symbol later.

**The button is iOS-only copy**, so it needs to be platform-aware: on Android
this same template must not say "on iPhone". `request.is_mobile_app` doesn't
distinguish them today — add `request.is_ios_app` / `is_android_app` off the same
user-agent check, and render "Tap to Pay on iPhone" vs "Tap to Pay" accordingly.

Also check **5.2**: "The button ... must be easily accessible, without requiring
scrolling ... When multiple payment options are available, Tap to Pay should be
positioned at the top of the list." It is already above the PayPal/Square QR
block, and the QR block is hidden in-app — worth confirming on a real phone that
nothing above it (the unsold-lot warning, the membership-renewal partial) pushes
it below the fold on a small screen.

### TTP-3 (blocker for warm-up, requirements 1.5 + 5.6 + 3.8) — `GET /api/mobile/payments/authorization/`

New endpoint. Two jobs, both from the checklist:

- **1.5** — "At the launch of your app or when it comes to the foreground, your
  app must trigger the initial preparation and warming-up of Tap to Pay on an
  iPhone." Square's reader only begins preparing once the SDK is *authorized*,
  and today authorization happens per invoice inside `/payments/create/` — i.e.
  at the exact moment the cashier presses the button. That also makes **5.6**
  ("the Tap to Pay on iPhone UI should come up within one second at least 90% of
  the time") unachievable. The app needs credentials before any invoice exists.
- **3.8 / 3.8.1** — "Tap to Pay on iPhone Terms and Conditions must only be
  accepted by an administrator user or otherwise authorized party", and an
  unauthorized user must be shown a message telling them to contact an admin.
  Only the backend knows who administers an auction with a linked Square seller.

```
GET /api/mobile/payments/authorization/     (Bearer JWT)

200 — this user can take payments:
{
  "eligible": true,
  "can_accept_terms": true,
  "access_token": "<seller OAuth token, same one /payments/create/ issues>",
  "location_id": "<Square location id>",
  "seller_name": "Capital Cichlid Association"
}

200 — signed in, but not a merchant:
{
  "eligible": false,
  "can_accept_terms": false,
  "message": "Only an auction admin with a connected Square account can set up Tap to Pay."
}
```

Notes:

- Resolve the seller the same way `/payments/create/` does
  (`club.effective_square_seller` / auction creator), for the user's most recent
  admin auction. If they administer several with different sellers, pick the same
  one `create` would for their latest auction — the app re-authorizes per invoice
  anyway, so a wrong guess costs one extra `authorize()`, never a wrong charge.
- `message` is rendered verbatim by the app (like the check-in nudges), so the
  reason can change without an app release. Omit it and the app uses its own copy.
- Issue `access_token`/`location_id` **only** when the user could actually charge
  right now. `eligible: true` with no credentials is a valid, handled response —
  the app shows the setup UI but skips the warm-up.
- Same auth/permission checks as `create`. This hands out a seller token, so it
  must not be reachable by a non-admin.
- **The app self-disables on 404**, so shipping this later costs nothing but the
  warm-up (and the drawer entry, which stays hidden until `eligible` is true).

### TTP-4 (requirement 5.10) — `receipt_url` on the confirm response

"Regardless of whether a transaction is approved or declined, it must be possible
to send a confidential digital receipt to the customer. This could be done via
SMS, email, QR code, or Activity views."

The app now offers "Send receipt to customer" on both the approved and the
declined outcome, through the OS share sheet (an Activity view — explicitly
listed as acceptable). It currently shares the amount, the invoice number and the
receipt number. `POST /api/mobile/payments/confirm/` already calls Square's
GetPayment to verify the charge; **add that payment's `receipt_url` to the
response** and the share becomes a real hosted receipt rather than a reference
number:

```
{ "payment_id": "...", "status": "...", "receipt_number": "...",
  "receipt_url": "https://squareup.com/receipt/preview/..." }
```

Purely additive — the app treats a missing `receipt_url` as "no link".

### TTP-5 (marketing 6.1 + 6.3) — launch email and push notification

Marketing requirements, required at launch and **only once the feature is in full
general availability**:

- **6.1** a dedicated launch email to all eligible users, using the toolkit's
  "Launch email" template.
- **6.3** an in-app push notification to all eligible users, using the "Value
  Proposition" copy from the toolkit's push-notification guidelines.

Both are backend/comms work riding the existing push + email pipelines; the app
needs no change. **6.2** (the in-app splash screen) is already implemented in the
app — `lib/widgets/tap_to_pay_awareness.dart`.

The copy and assets for all three **must** come from Apple's *Tap to Pay on
iPhone Marketing Guide and Toolkit*; the guide forbids writing your own. The
access page and its password are on p. 23 of the review guide PDF.

### TTP-6 (requirement 4.4, optional) — web-side merchant education

If any Tap to Pay education appears on the *website* (not the app), it must use
the Apple-approved toolkit assets. Inside the app this is already satisfied a
better way: the app calls Apple's own `ProximityReaderDiscovery` sheet, which
requirement 4.1 asks for and which Apple keeps current and localized — that one
call satisfies 4.4, 4.6, 4.7 and 4.8 outright.
