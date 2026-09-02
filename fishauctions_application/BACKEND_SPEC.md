# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part TTP-8 — the invoice page offers Tap to Pay on a settled invoice

Template-only, one line. `invoice.html` gates on `invoice.status != "PAID"`, which misses **settled but not PAID**: a zero balance, a balance already covered by recorded payments, or a seller the club owes. The cashier is offered a card charge with nothing to collect.

`quick_checkout_htmx.html` already gets this right via `invoice.show_square_button`, which tests `rounded_net_after_payments >= 0`. Suggested fix — keep `offers_tap_to_pay` and add the balance test:

```django
{% if request.is_mobile_app and invoice.status != "PAID" and invoice.auction.offers_tap_to_pay and invoice.rounded_net_after_payments < 0 %}
```

Deliberately *not* switching wholesale to `show_square_button`: this is the cashier collecting in the room, so the question is whether the auction's Square account can take a card at all, not whether *online* payments have opened (`enable_square_payments`). Only the balance half is missing. Keep `status != "PAID"` too — an invoice marked paid in cash has no `InvoicePayment` row.

`TapToPayButtonCopyTests` already covers both templates and is the natural home for the regression test.

Not fixable app-side: the app has no invoice balance until `/payments/create/` answers, which is after the button is pressed.

---

## Part TTP-10 — call `tapToPayWarm` from the pages that render the pay button

Apple's requirement 1.5 wants the reader warmed at launch/foreground and 5.6 wants the prompt on screen within a second. The app warms at mount and on resume, but a resume can be hours before the charge, so **the page that renders the pay button is the last honest moment to warm**.

The app exposes a bridge handler. Call it from `quick_checkout_htmx.html` and `invoice.html`, next to wherever the `fishauctions://pay/<pk>` button is rendered and under the same condition:

```js
if (window.flutter_inappwebview) {
  window.flutter_inappwebview.callHandler('tapToPayWarm').catch(function () {});
}
```

- **Fire-and-forget.** It resolves `{warmed: true|false}`; nothing on the page should depend on the answer, and `false` just means the throttle swallowed it (one warm-up per 2 minutes).
- **Always catch.** An older app build has no such handler and the promise rejects; that must not break the page.
- **Only render the call where the button renders.** Warming asks the backend for eligibility, so calling it on pages with no pay button is a wasted request per view.
- Safe to ship before/without any app change — a build without the handler just rejects.

**Why the server drives this**: the app deliberately does not guess which pages are checkout pages from the URL. The awareness modal used to guess from a URL prefix and announced a merchant feature to people who had none; it now waits to be told (`tapToPayOffer`), and this follows the same rule.

---
