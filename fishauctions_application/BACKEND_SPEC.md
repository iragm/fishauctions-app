# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---


## Part TTP-10 — don't offer the Tap to Pay palette row to non-Apple clients

`auctions/command_palette.py:_app_deep_link_items` offers `fishauctions://tap-to-pay`
to any client with `request.is_mobile_app`, varying only the *label* on
`request.is_ios_app`. The screen behind that link is Apple's flow end to end —
Apple's terms sheet, Apple's education sheet, and copy that says "Tap to Pay on
iPhone" throughout — so it is iOS-only by design: the app gates both of its own
entry points (the drawer tile and its offline palette's row) on `Platform.isIOS`.

The link was the one entry point with no such gate. On Android, tapping the row
opened the iPhone setup screen, which asked an uninitialized Square SDK for its
authorization state and **killed the process** (fixed app-side in
`webview_screen.dart` and `square_payment_service.dart`; the app now shows a
snackbar pointing at the invoice's own button instead).

Change: gate the row on `request.is_ios_app`, not `is_mobile_app`.

```python
if (not ql or _TAP_TO_PAY_QUERY.search(ql)) and getattr(request, "is_ios_app", False) and _can_take_payments(user):
```

The `is_ios_app` branch inside the row's label then becomes unconditional, and
`app_destinations_for_prompt` should drop the Tap to Pay destination on Android
for the same reason — otherwise the assistant still answers "take me to tap to
pay" with a link that does nothing there.

Android merchants lose nothing: they take cards from the invoice page's own
button, which is a different code path and unaffected. There is no Android
equivalent of the setup screen because there is nothing to set up — no Apple
account link, no terms, no education sheet.
