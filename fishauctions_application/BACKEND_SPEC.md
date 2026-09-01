# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part SUPPORT — a support page that works signed out

**Why:** App Store Connect requires a **Support URL**, and App Review opens it in
a plain browser with no session. The only candidate today is `/faq/`, and
`faq.html` ends with:

```django
Still got questions? Email me:
{% if request.user.is_authenticated %}{{admin_email|urlize}}{% else %}(Sign in to see email){% endif %}
```

So a signed-out reviewer gets substantive FAQ content and then, exactly where the
contact method should be, the words *"(Sign in to see email)"*. That is the shape
of a Guideline 1.5 metadata rejection ("your Support URL does not provide
adequate support information"), and a metadata rejection costs a review round
trip — days — for something worth about twenty minutes.

The address is hidden from anonymous users to keep it off scrapers, which is a
real concern and should stay solved. So: keep hiding the address, add a way to
reach a human that doesn't need an account.

**Smallest fix that satisfies it.** In `faq.html`, replace the signed-out branch
with a link to a contact form rather than the current dead text:

```django
{% if request.user.is_authenticated %}{{admin_email|urlize}}{% else %}<a href="{% url 'contact' %}">Send a message</a>{% endif %}
```

and add a `/contact/` view: an unauthenticated form (name, email, message) that
emails `admin_email`, protected by the same reCAPTCHA the signup flow already
uses. No address is exposed, and the page stands on its own as the Support URL.

**Alternative, if a form is more than you want to build:** seed a `/support/`
`BlogPost` by migration the way `/privacy/` already is
(`PrivacyPolicyView`) — a short page carrying a support address in plain text
plus a link to `/faq/` — and point the Support URL there instead. Fewer moving
parts; the trade is that the address is public.

**No app change either way.** The Support URL is App Store Connect metadata; the
app never loads it.

## Part TTP-8 — the invoice page is a dead end in the app

**Where the button is today.** `fishauctions://pay/<pk>` is rendered in exactly
one template, `auctions/quick_checkout_htmx.html`, reached from the auction
page's "Quick checkout" button or the ribbon's "Checkout" menu entry (in-person
auctions only). That placement is right and should stay: quick checkout *is* the
checkout desk, and requirement 5.2's "top of the payment list, no scrolling" is
already satisfied there.

**The gap is `invoice.html`.** It hides the web PayPal and Square buttons for app
requests — correctly, since both redirect to a hosted checkout that can't run in
the WebView — and its own comment says Square "is collected via on-device Tap to
Pay (see quick_checkout_htmx.html)". But nothing on that page *goes* there. So an
admin who opens an invoice in the app (from the users table, a search, a
notification, a bookmark) sees the payment options removed and is offered nothing
in their place, with no hint that a working path exists one screen away.

That is worse than it sounds for review: a reviewer handed a demo account will
plausibly navigate to Invoices first, find no way to take a payment, and conclude
the feature doesn't work.

**Fix, smallest first.** On `invoice.html`, for an app request where the viewer
is an admin of the invoice's auction, the invoice is unpaid, and
`auction.offers_tap_to_pay` is true, render the same button:

```django
<a href="fishauctions://pay/{{ invoice.pk }}" class="btn btn-primary btn-lg w-100 my-2">
  {% if request.is_ios_app %}Tap to Pay on iPhone{% else %}Tap to Pay{% endif %}
</a>
```

Identical copy and no icon, for the same 5.4/5.5 reasons spelled out in
`quick_checkout_htmx.html` — copy the comment rather than restating it, and
extend `TapToPayButtonCopyTests` to cover the second location so the two can't
drift.

And while we are making changes - quick checkout starts with the camera on, which is good if that's the last thing you were doing, but it needs to start with the camaera off.  Store the camera state in userdata or a cookie or somewhere so you can scan a bidder card, tap to pay, come back to quick checkout and scan the next one - or - if you don't do bidder cards with barcodes, you just never see the camera except a little icon button to turn it on
## Part TTP-9 — say "pending approval" instead of showing nothing

**The problem.** `UserData.square_enabled` (default `False`, from
`SQUARE_ENABLED_FOR_USERS`) gates every route to Square connect, and it gates
them by *rendering nothing*:

- `preferences_ribbon.html` shows the "Square account" item only on
  `square_enabled or user.squareseller`
- `Auction.show_square_banner` returns False on `not created_by.userdata.square_enabled`
- `SquareConnectView` errors only if the URL is reached directly

So an organizer who wants to take card payments finds no button, no explanation,
and no way to ask. From inside the app that is indistinguishable from "this site
can't do card payments", which is the reading Apple's onboarding requirements
(2.1, 2.2) exist to prevent — and it's the one thing about our trust model that
would be fair to cite.

**The site already solves this one screen away.** An untrusted creator looking at
an unpromoted auction gets `Auction.untrusted_message` plus a **"Contact us and
request access"** mailto button. That is the right pattern; Square just isn't
using it.

**Fix.** Where the Square connect entry points are hidden today, render a short
disclosed state instead, for a signed-in user who could otherwise use it (an
auction or club admin):

- In `preferences_ribbon.html`, keep the "Square account" item visible and let
  `square_seller.html` carry the explanation, rather than hiding the menu entry.
- On `square_seller.html`, when `not request.user.userdata.square_enabled`,
  replace the connect button with a sentence saying accounts are reviewed before
  card payments are enabled, plus the same request-access mailto the promotion
  banner uses.
- Optionally mirror it on the auction ribbon in place of the connect banner.

**Explicitly not wanted: removing the gate.** Letting anyone who signs up start
an OAuth flow to collect money from strangers trades a real fraud control for a
cosmetic one. The ask is to make the gate *visible and requestable*, not absent.

**No app change.** All three surfaces are templates, and the app renders whatever
the page shows.

## Part TTP-7 (revised) — the Square callback strands the merchant on a web page

**Two separate faults, and only the second one is yours.** The first was
app-side and is fixed (2026-09-01): the in-app browser view carries Safari's
cookies rather than the app's, so `/square/connect/` — `LoginRequiredMixin` —
bounced the merchant to the web login form the moment the flow started, with the
full site navbar, inside what looked like a broken handoff. The app now mints a
`auth/web-session/` handoff token and opens the browser view at the consume URL
with the connect path as `next`, so the browser view holds a real Django session
for the whole round trip. That also means `mark_session_opened_by_app` is set on
it, so the callback page reliably takes its "opened by the app" branch. The
second fault is below.

**What happens at the end.** Square OAuth is a *server-side* flow: Square redirects to
auction.fish with an authorization code, the backend exchanges it using its
secret, and renders a success page. That page is correct and necessary — the
exchange cannot happen in the app. But the merchant is now looking at a website
inside an in-app browser view, and nothing takes them back. The page offers a
`fishauctions://square-connected` link that is inert (the app registers no OS
handler for that scheme, deliberately, and this page renders outside the shell's
WebView so `shouldOverrideUrlLoading` never sees it), so the only way out is the
system **Done** button, which nothing tells them about.

This was written down as cosmetic. Recording the onboarding video for Apple's
entitlement review is what showed it isn't: on camera it reads as the app
handing you off to a website and abandoning you, in the middle of the flow
requirement 2.2 is about.

**Fix now (template only, no app release).** The backend already knows the flow
started in the app — `session_opened_by_app(request)` / `?return_to_app=1`, set
in `SquareConnectView`. On that branch, replace the dead link with a plain
instruction: the account is connected, and **tap Done to return to
auction.fish**. Name the button the system actually shows. That makes the step
deliberate instead of broken, and is enough to film against.

**Fix properly (needs the app half too).** Have the success page *redirect* to a
callback scheme rather than offer a link, so the browser view closes itself the
way an OAuth flow is supposed to:

```html
<meta http-equiv="refresh" content="0;url=fishauctions-oauth://square-connected">
```

gated on the same `session_opened_by_app` branch, with the "tap Done" copy left
visible underneath as the fallback for anyone whose session doesn't complete.

**The app side of this landed 2026-09-01** — seller onboarding now runs in
`ASWebAuthenticationSession` (Chrome Auth Tab on Android, via
`flutter_web_auth_2`) instead of `LaunchMode.inAppBrowserView`, listening for
`fishauctions-oauth://`. It is waiting on the redirect above and nothing else:
with no redirect to match, the session ends on the merchant tapping Done, which
the app treats as a normal finish. So this template change is the whole
remaining fix. Note the **distinct scheme**:
`fishauctions-oauth://`, not `fishauctions://`, so the existing decision not to
register the app's own scheme with the OS survives intact. Nothing but a pending
auth session can act on it.


## Part TTP-10 — the Tap to Pay idempotency key is the wrong Square concept

**The bug, found on hardware 2026-09-01.** A card was declined, the cashier
retried, and Square's own UI answered *"something went wrong, please contact the
developer of this app — error code `payment_attempt_id_reused`"*. Declines are
routine, so this makes Tap to Pay fail precisely when it is needed.

**Cause.** `create_mobile_payment` returns a deliberately stable key:

```python
# Stable, invoice-derived idempotency key — NOT random. The Mobile Payments SDK keys the
# on-device charge with this, so if create -> tap is retried for the same (still-unpaid)
# invoice the duplicate collapses to a single Square charge instead of double-charging.
"idempotency_key": f"taptopay-inv-{invoice_pk}",
```

The reasoning describes the **Payments API's** server-side `idempotency_key`,
which does collapse duplicates and return the original payment. The app passes
this value to the **Mobile Payments SDK** as `paymentAttemptId`, which is a
different thing with the opposite behaviour: it identifies one *attempt*, and a
repeat is an error. Nothing ever de-duplicated; the second tap simply failed.

The existing `PaymentAlreadyChargedError` is the other face of the same mistake —
a stable key making Square return an earlier completed charge.

**The app no longer depends on this** (2026-09-01): `PaymentSheet._freshAttemptId`
derives a per-attempt id from whatever `create` returns, so Tap to Pay works
against the backend as it stands. Two things are still worth doing here.

**1. Make the key per-create.** Append a nonce (`f"taptopay-inv-{invoice_pk}-{uuid4().hex[:8]}"`,
within Square's 45-character limit) and correct the comment. The app's
derivation then becomes belt and braces rather than a workaround.

**2. Record the attempt — this is the part that actually protects anyone.**
Double-charge safety currently rests on `create` refusing a PAID invoice, which
leaves one real window: a charge captured on-device whose `confirm` never
arrives (the app is killed, the network drops). The invoice stays unpaid, and
nothing stops a second tap charging the card again. The stable key used to block
that by accident — indiscriminately, since it could not distinguish "already
charged" from "last card declined", which is exactly why it had to go.

The fix is the `PaymentIntent`-shaped record the original prompt specified and
the backend never grew. **The app half is implemented and shipped** — it uses
the contract below where the backend offers it and falls back silently where it
doesn't, so this can land whenever you're ready.

### The contract

**`POST payments/create/` gains `attempt_id` in the response.** A new value per
call, recorded as an open attempt against the invoice. The app passes it to
Square as `paymentAttemptId` verbatim (`PaymentContext.attemptId`); if the field
is absent it derives its own and nothing else changes, so nothing breaks before
this lands. Keep it inside Square's 45-character limit, and keep it
invoice-derived so a charge is still traceable in the Square dashboard —
`f"taptopay-inv-{invoice_pk}-{uuid4().hex[:8]}"` is fine.

**`POST payments/create/` refuses while an attempt is open.** Return **409** with
a cashier-facing `detail`, and write it for a person standing at a checkout desk:
*"This invoice may already have been charged — a payment was started at 3:42pm and
never finished. Check it in Square before charging again."* The app surfaces that
text verbatim through its existing error path, so no app change is needed and the
wording stays yours. Age attempts out (a few minutes) so a wedged record can't
strand an invoice forever.

**`POST payments/attempt/close/` — new, and load-bearing.**
Body `{"attempt_id": "...", "outcome": "canceled" | "failed"}`; 204 or a small
JSON body, either is fine. The app calls it on every path where the SDK returned
without capturing: cancel, decline, timeout, authorize failure, any SDK error.

> Without this endpoint the whole feature backfires. Declines are routine; a
> declined card would leave the attempt open, `create` would refuse the retry,
> and the cashier would be blocked from the one action that is definitely
> correct. That is the same failure this part exists to remove, moved one step
> later. The app treats the call as best-effort and never shows the cashier a
> bookkeeping error, so a 404 on an older deployment is harmless.

**`confirm` closes the attempt** as `captured`, alongside what it already does.

### What this buys

One window, and it is the only one left: a charge captured on-device whose
`confirm` never arrives — the app is killed, the network drops — leaves the
invoice unpaid with nothing to stop a second tap charging the card again. The
old stable idempotency key blocked that by accident, indiscriminately, which is
exactly why it had to go. This blocks it on purpose, and tells the cashier the
one thing that matters: *check Square before tapping again.*
