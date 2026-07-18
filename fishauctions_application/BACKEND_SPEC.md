# Backend Spec — Web-Configurable Printing, Push Notifications & AR Lot Mapping

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

# Status

Parts 1 and 2 are fully implemented on the backend (including the follow-up
items that used to be listed here: the `/lots/my-last-auction/` shortcut
redirect, the `firebase` block in `MobileConfigView`, the notification+data
hybrid FCM message, and the `escpos-raster` 384 px seed fix). Part 2 stays
inert per deployment until `FIREBASE_CREDENTIALS_JSON` is set and the app
ships real FCM tokens (see `PUSH.md`).

**Part 3 (AR lot scanning & location mapping, below) is the outstanding
work** — nothing from it exists on the backend yet.

---

# Part 1 — Printing

## Product requirements (recap)

- Main menu → **Label printing** (`/printing/`, the existing `UserLabelPrefsView`
  page) is the one and only place printing is configured. No separate printer
  setup page.
- On that page, a **print method dropdown** with 3 options:
  1. **PDF** (default) — behaves like the website today: label PDFs are generated
     and downloaded/opened.
  2. **System printer** — the same PDFs, but the app hands them to the OS print
     dialog (Android print framework / AirPrint) instead of opening them.
  3. **Bluetooth** — native thermal printing over BLE.
- **Mismatch warnings** when the label size preset and print method don't agree
  (thermal roll + system printer, sheet labels + Bluetooth, …).
- Picking Bluetooth (in-app) shows the connected printer with an **Unpair**
  button, or walks through permissions → scan → connect. All launched from within
  the `/printing/` page.
- **New thermal printers are added as Django admin rows** (`ThermalPrinterProfile`)
  that carry the exact byte sequences to send — no app release.
- Where the printer supports it, **read the loaded label size** from the printer
  and use it.

## What already exists (no work needed)

| Piece | Where | Status |
|---|---|---|
| `/printing/` prefs page | `UserLabelPrefsView` + `UserLabelPrefsForm` | exists; gains one field + warnings + a BT card |
| Label size presets incl. thermal | `UserLabelPrefs.PRESETS` (`sm`, `lg`, `thermal_sm`, `thermal_very_sm`, `custom`) | reused as-is |
| PDF generation | `LotLabelView` (+ bulk/unprinted/single variants, WeasyPrint) | reused as-is for PDF *and* System printer methods |
| Rendered label image for BT | `GET /api/mobile/labels/<pk>/?fmt=png&resolution=WxH&dpi=N` | exists |
| In-app page detection | `request.is_mobile_app` middleware (`FishAuctionsApp` UA token) | exists |

The app currently hardcodes one printer (Fichero/AiYin D11s: BLE UUIDs, 96 px
head, `10 FF`-prefixed command protocol, chunk pacing). That knowledge moves into
seed data for the new model (§1.3) and the app becomes a generic interpreter.

## 1.1 `UserLabelPrefs.print_method` (new field)

```python
class UserLabelPrefs(models.Model):
    ...
    PRINT_METHODS = (
        ("pdf", "PDF download"),
        ("system", "System printer"),
        ("bluetooth", "Bluetooth label printer"),
    )
    print_method = models.CharField(max_length=20, choices=PRINT_METHODS, default="pdf")
    print_method.help_text = (
        "PDF downloads a file to print later. System printer sends the PDF straight "
        "to a printer configured on your phone. Bluetooth prints directly to a "
        "thermal label printer. System printer and Bluetooth only work in the app."
    )
```

- Migration: default `"pdf"` — existing users see no behavior change.
- Add to `UserLabelPrefsForm` layout as the **first row** of the form, before
  `preset` (it's the primary choice on the page now).
- The dropdown is shown on desktop web too (a user can pre-configure before
  opening the app); only the Bluetooth *connect card* is app-only (§1.2).

## 1.2 `/printing/` page changes (template + form)

All of this is Django template/form work so UX copy and rules iterate server-side.

### Mismatch warnings

Add a `warnings` list to the view context (and to the prefs API, §1.4), computed
server-side from the saved prefs. Initial matrix — adjust freely later, that's
the point of it being server-side:

| Condition | Warning |
|---|---|
| `print_method in (pdf, system)` and `preset in (thermal_sm, thermal_very_sm)` | "Your label size is a thermal roll. Regular printers usually take letter/A4 label sheets — pick a sheet preset like Avery 18262, or switch the print method to Bluetooth." |
| `print_method == bluetooth` and `preset in (sm, lg)` | "Avery sheet presets won't fit a thermal label printer. Pick a thermal preset (or Custom matching your roll)." |
| `print_method == bluetooth` and `preset == custom` and label bigger than any enabled profile's `max_label_width_mm/height` | "No supported Bluetooth printer takes labels this large." (optional, nice-to-have) |

Render as a dismissable Bootstrap `alert-warning` under the dropdown. These are
warnings, not blockers — never prevent saving.

Also re-render the warning live on dropdown change (the form already posts on
save; an HTMX `hx-trigger="change"` partial or a small JS map of
`(method, preset) → warning` embedded in the template both work).

### Bluetooth printer card (app-only)

When `request.is_mobile_app`, render a card under the dropdown (shown only when
`print_method == "bluetooth"`, toggled by the same change handler):

- The card talks to the app over the existing `flutter_inappwebview` JS bridge.
  Contract (app implements the handlers; page JS lives in the Django template so
  the UX can change server-side):

```js
// Page → app. Returns:
// { supported: bool,            // false on web / old app builds
//   connected: bool,
//   name: string|null, address: string|null,
//   profile: string|null,       // matched ThermalPrinterProfile.slug
//   labelSize: {width_mm, height_mm}|null }   // printer-reported, if readable
await window.flutter_inappwebview.callHandler('printerGetState');

// Page → app: opens the native connect flow (permission prompts → scan →
// pick device) as a bottom sheet OVER the current page. Resolves with the
// same state object when the sheet closes.
await window.flutter_inappwebview.callHandler('printerConnect');

// Page → app: disconnect + forget the saved printer. Resolves with state.
await window.flutter_inappwebview.callHandler('printerUnpair');
```

- Card states:
  - No printer: "No printer connected" + **Connect a printer** button →
    `printerConnect`.
  - Connected/saved: printer name, matched profile name, reported label size if
    any, + **Unpair** button → `printerUnpair`.
  - `supported: false` (desktop web or the handler throws): "Bluetooth printing
    works in the FishAuctions app — install it and come back to this page."
- When `printerGetState` returns a `labelSize` that differs from the saved
  prefs, offer one-tap adoption: "Printer reports 40 × 30 mm labels —
  [Use this size]" → posts the prefs form with `preset=custom`, converted
  dimensions, `unit` unchanged. This is the "read the current size and go" flow;
  size *detection* is the app's job (§1.3 `label_size_query`), size *storage*
  stays in `UserLabelPrefs` so PDFs match too.

### Print buttons elsewhere on the site

No template changes needed for the main flows: label print actions keep
producing PDFs exactly as today. In-app, the WebView already intercepts
downloads; the app branches on the user's `print_method` (fetched via §1.4):

- `pdf` → download/open as today.
- `system` → route the same PDF bytes into the OS print dialog.
- `bluetooth` → in-app label pages deep-link `fishauctions://print/<lot_pk>`
  (existing scheme) to the native raster path.

The only backend nicety: on label-printing pages, when `request.is_mobile_app`
and the user's `print_method == "bluetooth"`, prefer emitting the
`fishauctions://print/<lot_pk>` link for per-lot print buttons (bulk sheet-PDF
buttons can stay PDF regardless — a 200-label run over a 96 px BLE printer is a
per-lot workflow anyway). Expose the user's `print_method` to templates via the
existing userdata/context patterns.

## 1.3 `ThermalPrinterProfile` model — printers as admin rows

New model (suggest `auctions/models.py`, admin-registered with list editing).
One row = one printer family the app can drive. Adding support for a new
printer = adding a row, no app release.

```python
class ThermalPrinterProfile(models.Model):
    """A Bluetooth thermal label printer the mobile app knows how to drive.

    The app downloads all enabled profiles and interprets them; every byte
    sent to a printer is defined here, not in the app."""

    slug = models.SlugField(unique=True)          # stable id the app caches/reports
    name = models.CharField(max_length=100)      # "Fichero / AiYin D11s"
    enabled = models.BooleanField(default=True)
    priority = models.PositiveIntegerField(default=100)  # match order, low wins
    schema_version = models.PositiveIntegerField(default=1)  # command-program schema

    # ── Matching (how the app decides a scanned BLE device uses this profile) ──
    # JSON list of case-insensitive regexes tested against the advertised name,
    # e.g. ["^D11", "^Fichero"]. Empty list = never auto-matched (manual pick only).
    ble_name_patterns = models.JSONField(default=list, blank=True)
    # Optional exact GATT ids; blank = discover (first writable characteristic).
    service_uuid = models.CharField(max_length=40, blank=True, default="")
    write_characteristic_uuid = models.CharField(max_length=40, blank=True, default="")
    notify_characteristic_uuid = models.CharField(max_length=40, blank=True, default="")

    # ── Transport pacing ──
    chunk_size = models.PositiveIntegerField(default=200)        # bytes per BLE write
    chunk_delay_ms = models.PositiveIntegerField(default=20)     # gap between chunks
    prefer_write_with_response = models.BooleanField(default=True)

    # ── Raster geometry ──
    print_width_px = models.PositiveIntegerField(default=96)     # printhead dots
    dpi = models.PositiveIntegerField(default=203)
    invert_raster = models.BooleanField(default=False)           # 1 = white printers
    max_label_width_mm = models.FloatField(null=True, blank=True)
    max_label_height_mm = models.FloatField(null=True, blank=True)

    # ── Command programs (JSON, schema in §1.3.1) ──
    print_program = models.JSONField()            # required
    status_program = models.JSONField(default=list, blank=True)   # optional pre-flight
    status_flags = models.JSONField(default=dict, blank=True)     # byte/bit → condition
    label_size_program = models.JSONField(default=list, blank=True)  # optional size read
    label_size_parse = models.JSONField(default=dict, blank=True)

    notes = models.TextField(blank=True, default="")  # admin-facing: quirks, sources
```

### 1.3.1 Command program schema (v1)

A program is a JSON list of steps, executed in order. The app substitutes
placeholders, writes bytes over the profile's transport pacing, and honors
delays/awaits. Deliberately declarative and tiny — no loops other than
`repeat_per_copy`, no conditionals.

Step types:

```jsonc
{"tx": "10 ff fe 01"}                 // send hex bytes (whitespace ignored)
{"tx_text": "SIZE {width_mm} mm,{height_mm} mm\r\n"}  // send ASCII w/ placeholders (TSPL/ZPL/ESC-POS text)
{"tx_raster": true}                   // send the packed 1-bit bitmap body
{"delay_ms": 50}
{"await": {"any_hex_prefix": ["AA", "4F4B"],  // resolve when a notify frame starts with any listed prefix
           "timeout_ms": 60000,
           "on_timeout": "warn"}}     // "warn" (continue, tell user to check output) | "fail"
{"repeat_per_copy": [ ...steps... ]}  // run the nested steps once per requested copy
```

Placeholders (usable in `tx` and `tx_text`; numeric ones render as ASCII decimal
in `tx_text` and as bytes in `tx` via the typed forms):

| Placeholder | Meaning |
|---|---|
| `{width_px}` `{height_px}` | raster dimensions in dots |
| `{width_bytes}` | `ceil(width_px / 8)` |
| `{u16le:width_bytes}` `{u16le:height_px}` `{u16le:width_px}` | little-endian 16-bit, as 2 bytes (for `tx`) |
| `{width_mm}` `{height_mm}` | label physical size (from prefs or printer-reported) |
| `{density}` | 0–2, app setting (default 1) |
| `{paper_type}` | profile/app setting (default 0) |
| `{copies}` | copy count |

`status_flags` maps conditions to a byte+mask in the (final) status reply frame:

```json
{"byte": -1, "flags": {"printing": 1, "cover_open": 2, "out_of_paper": 4,
                       "low_battery": 8, "overheated": 80}}
```

(`byte: -1` = last byte of the frame; masks in hex-as-int or string hex, pick one
and document it. `overheated` here is `0x10|0x40` folded — allow a list of masks
per flag if that's cleaner.)

`label_size_parse` handles printers that answer a size query (e.g. TSPL
`SIZE?`-style or RFID-roll printers):

```jsonc
{"kind": "ascii_regex",                 // or "bytes" with offsets
 "pattern": "(?<w>\\d+(\\.\\d+)?)\\s*mm?,\\s*(?<h>\\d+(\\.\\d+)?)",
 "unit": "mm",                          // "mm" | "in" | "dots"
 "timeout_ms": 3000}
```

If `label_size_program` is empty the app skips size read-back and uses the
user's prefs — that's the graceful default; most cheap BLE printers won't
support it, and it costs nothing to add to a profile later when a unit that
does shows up.

**Versioning:** the app ships knowing schema v1. `GET .../profiles/` includes
each profile's `schema_version`; the app ignores profiles with a version it
doesn't know (and falls back to its bundled copy of the D11s profile if nothing
matches). New step types ⇒ bump the version on profiles using them.

### 1.3.2 Seed data (data migration)

Port the current in-app D11s driver verbatim so day one behavior is identical.
Two rows (the enable/stop pairs differ by internal board):

```jsonc
// slug: "d11s-aiyin", name: "Fichero / AiYin D11s", priority: 10
// ble_name_patterns: ["^d11", "^fichero", "^aiyin"]
// service_uuid: "000018f0-0000-1000-8000-00805f9b34fb"
// write_characteristic_uuid: "00002af1-0000-1000-8000-00805f9b34fb"
// notify_characteristic_uuid: "00002af0-0000-1000-8000-00805f9b34fb"
// chunk_size: 200, chunk_delay_ms: 20, print_width_px: 96, dpi: 203
{
  "print_program": [
    {"tx": "10 ff 10 00 {density}"}, {"delay_ms": 100},
    {"tx": "10 ff 84 {paper_type}"}, {"delay_ms": 50},
    {"repeat_per_copy": [
      {"tx": "00 00 00 00 00 00 00 00 00 00 00 00"}, {"delay_ms": 50},
      {"tx": "10 ff fe 01"}, {"delay_ms": 50},
      {"tx": "1d 76 30 00 {u16le:width_bytes} {u16le:height_px}"},
      {"tx_raster": true}, {"delay_ms": 500},
      {"tx": "1d 0c"}, {"delay_ms": 300}
    ]},
    {"tx": "10 ff fe 45"},
    {"await": {"any_hex_prefix": ["AA", "4F4B"], "timeout_ms": 60000, "on_timeout": "warn"}}
  ],
  "status_program": [{"tx": "10 ff 40"}],
  "status_flags": {"byte": -1, "flags": {"printing": "01", "cover_open": "02",
    "out_of_paper": "04", "low_battery": "08", "overheated": "50"}}
}
// slug: "d11s-lujiang": identical except enable "10 ff f1 03" / stop "10 ff f1 45",
// priority 20 (tried second on ambiguous name match — user can pick manually).
```

A generic **"Raw ESC/POS raster (GS v 0)"** fallback row (empty
`ble_name_patterns`, no wrapper commands, just the `1d 76 30` header +
raster + feed) is worth seeding too — it's what "other printers fall back to
the first writable characteristic" does today, made explicit and editable.

## 1.4 Mobile API additions

All under `/api/mobile/`, JWT-authed, `mobile_api` throttle scope, same patterns
as existing views.

### `GET /api/mobile/printers/profiles/`

Returns every enabled profile, priority-ordered:

```jsonc
{
  "schema_version_max": 1,
  "profiles": [
    { "slug": "d11s-aiyin", "name": "Fichero / AiYin D11s",
      "schema_version": 1, "priority": 10,
      "match": {"ble_name_patterns": ["^d11", "^fichero"],
                "service_uuid": "000018f0-…", "write_characteristic_uuid": "…",
                "notify_characteristic_uuid": "…"},
      "transport": {"chunk_size": 200, "chunk_delay_ms": 20,
                    "prefer_write_with_response": true},
      "raster": {"print_width_px": 96, "dpi": 203, "invert": false,
                 "max_label_width_mm": null, "max_label_height_mm": null},
      "print_program": [ … ], "status_program": [ … ], "status_flags": { … },
      "label_size_program": [ … ], "label_size_parse": { … } }
  ]
}
```

The app caches the response (secure storage) and refreshes it opportunistically —
printing must work offline at an auction hall. `updated_at`/ETag on the response
is a cheap win for that.

### `GET /api/mobile/labels/prefs/` and `PATCH`

Serializes the user's `UserLabelPrefs` (auto-created if missing) plus the
computed warnings so app and web always show the same ones:

```jsonc
// GET →
{ "print_method": "bluetooth", "preset": "thermal_sm", "unit": "in",
  "label_width": 3.0, "label_height": 2.0, "empty_labels": 0, "print_border": true,
  "warnings": ["Avery sheet presets won't fit a thermal label printer. …"] }

// PATCH accepts any writable subset; used by the app’s “use printer-reported
// size” confirmation:
{ "preset": "custom", "unit": "cm", "label_width": 4.0, "label_height": 3.0 }
```

Warning computation lives in one function used by both this serializer and the
`/printing/` template.

### `GET /api/mobile/labels/<pk>/?fmt=pdf`

Add a `pdf` renderer to the existing mobile label endpoint: a single-lot PDF
rendered with the user's `UserLabelPrefs` — same WeasyPrint pipeline as the web
`SingleLotLabelView`, JWT-authed, same `_can_access` rule. This is what the
native `fishauctions://print/<lot_pk>` screen fetches when `print_method` is
`pdf`/`system`, so a lot printed from the deep link matches a lot printed from
the website exactly.

(The PNG path is unchanged; the app requests
`?fmt=png&resolution={print_width_px}x{height}&dpi={profile.dpi}` so barcodes
render crisp at native width instead of being downscaled.)

## 1.5 Out of scope for the backend (app work, listed for context)

- `printing` Flutter package (or platform channel) for the OS print dialog;
  WebView download interception branches on `print_method`.
- Generic profile interpreter replacing the hardcoded `D11sDriver`; bundled
  fallback copy of the D11s profiles for cold-start/offline.
- The three JS-bridge handlers (`printerGetState/Connect/Unpair`), with the
  connect flow presented as a bottom sheet over `/printing/` (permissions →
  scan → pick), replacing the standalone `/settings/printer` screen and drawer
  entry.
- Android 12+ scan permission is already `neverForLocation`; ≤11 still prompts
  location before scanning, matching the requested "prompt location permissions →
  BT connect" flow.

## 1.6 Tests to ship with the backend changes

- `print_method` migration default + form round-trip.
- Warning matrix: each cell of the table above.
- Profiles endpoint: only enabled profiles, priority order, schema shape
  (validate seed data JSON against a checked-in JSON Schema for the program
  format — cheap guard against admin typos bricking prints).
- Program JSON validation on model `clean()`: unknown step keys, bad hex,
  unknown placeholders rejected in the admin, not on the printer.
- Prefs GET/PATCH: auto-create, permissions (own prefs only), warning presence.
- Labels PDF: auth matrix mirrors the PNG tests; output content-type; honors
  prefs dimensions.

---

# Part 2 — Push Notifications

## Product requirements (recap)

- App users can opt to receive **push notifications instead of emails** for
  everything **except account-related email** (verification, password reset,
  security warnings — always email).
- The **weekly promo email is not sent** to push users. Instead: **one push per
  promoted auction within the user's configured distance**, sent no earlier than
  **24 h after the auction is created** and (nominally) **a week before it
  starts**.
- **Auction stats track push notifications sent** (like
  `weekly_promo_emails_sent` does for email).

> Interpretation to confirm: "min 24 hours after it's created, and a week before
> it starts" is implemented as `send_at = max(date_posted + 24h, date_start - 7d)`,
> and never after `date_start`. So: normally the push lands a week before start;
> an auction created closer than 8 days to its start gets the push 24 h after
> creation; an auction created less than ~24 h before start gets nothing.

Note the existing `push_notifications_when_lots_sell` (django-webpush, browser
push for in-person bidding) is a separate live-websocket feature and is left
untouched; this spec adds *mobile* (FCM) push as an email replacement.

## 2.1 FCM infrastructure

- Dependency: `firebase-admin` (server SDK; HTTP v1 API — the legacy FCM key API
  is dead). New settings/env:
  - `FIREBASE_CREDENTIALS_JSON` (path or inline JSON of a service-account key;
    absent ⇒ push disabled globally, everything falls back to email — same
    graceful-degradation pattern as `email_routing_enabled()`).
- One Firebase project with three Android apps registered (the app's
  `applicationId` flavors: `com.fishauctions.app`, `.dev`, `.staging`). iOS/APNs
  is wired through the same project later; nothing in this spec is
  Android-specific.
- A Celery task does the actual send (never send inline in a request):

```python
@shared_task
def send_push_to_user(user_pk, *, title, body, url, category,
                      collapse_key=None, auction_pk=None, invoice_pk=None):
    """Send to every push-enabled device of the user; prune dead tokens.

    FCM data message keys: title, body, url (absolute), category.
    On messaging.UnregisteredError / invalid-token: clear that device's token.
    Logs one PushNotificationSent row per successful device send."""
```

`url` is the deep destination (e.g. the invoice page); the app opens it in the
WebView on tap. `collapse_key=category` for chatty categories (chat replies) so
a phone that was off shows one notification, not thirty.

## 2.2 Model changes

```python
class MobileDevice(models.Model):
    ...
    fcm_token = models.TextField(blank=True, default="", db_index=False)
    fcm_token_updated_at = models.DateTimeField(null=True, blank=True)
    push_enabled = models.BooleanField(default=True)   # per-device kill switch

class UserData(models.Model):
    ...
    push_notifications_instead_of_email = models.BooleanField(default=False, blank=True)
    push_notifications_instead_of_email.help_text = (
        "Get notifications in the FishAuctions app instead of emails, for everything "
        "except account emails like password resets. Requires the app to be installed "
        "and signed in. The weekly promo email is replaced by a notification for "
        "promoted auctions near you."
    )

class Auction(models.Model):
    ...
    promo_push_notifications_sent = models.PositiveIntegerField(default=0)
    promo_push_notifications_sent.help_text = (
        "Number of push notifications sent promoting this auction"
    )

class PushNotificationSent(models.Model):
    """One row per push actually handed to FCM — dedupe + stats."""
    user = models.ForeignKey(User, on_delete=models.CASCADE)
    device = models.ForeignKey(MobileDevice, null=True, on_delete=models.SET_NULL)
    category = models.CharField(max_length=40, db_index=True)
    auction = models.ForeignKey(Auction, null=True, blank=True, on_delete=models.SET_NULL)
    invoice = models.ForeignKey(Invoice, null=True, blank=True, on_delete=models.SET_NULL)
    sent_at = models.DateTimeField(auto_now_add=True)
    class Meta:
        indexes = [models.Index(fields=["user", "category", "auction"])]
```

`user_prefers_push(user)` helper: `push_notifications_instead_of_email` AND at
least one device with a non-empty `fcm_token` and `push_enabled` AND push
configured globally. Expose it on `UserData` — the send sites below all use it.

The preferences toggle goes on the existing `/preferences/` page
(`UserData` form) — zero app work, and the app's WebView shows it natively.
Show it disabled with an explanatory tooltip when the user has no registered
device with a token, rather than hiding it.

## 2.3 Email → push routing

One choke point, applied at each send site:

```python
def notify_user(user, *, category, title, body, url, send_email: Callable[[], None]):
    """Push if the user prefers push and `category` is push-eligible; else email."""
    if category in PUSH_EXEMPT_CATEGORIES or not user_prefers_push(user):
        send_email()
        return
    send_push_to_user.delay(user.pk, title=title, body=body, url=url, category=category)
```

Integration points (each keeps its existing email exactly as-is for non-push
users; each gains a short push title/body since email templates don't translate
to a 2-line notification):

| Send site | Category | Push example |
|---|---|---|
| allauth account emails, `show_email_warning_sent`-type security notices | `account` | **never pushed** (exempt list) |
| `tasks.send_invoice_notification` | `invoice` | "Your invoice for {auction} is ready — $41.50" → invoice URL |
| `sendnotifications` (watched-lot / online-auction ending reminders) | `watched` | "{auction} ends soon — you're watching 4 lots" |
| `auctiontos_notifications` (join/location confirmations) | `auction_confirm` | "You're confirmed for {auction} at {location}" |
| `email_unseen_chats` (lot comments/replies) | `chat` (collapse) | "New messages on {lot}" |
| `tasks.send_club_member_email` (welcome/renewal/expiring) | `membership` | "Your {club} membership was renewed" |
| `auction_emails` (auction-creator reminders) | `auction_admin` | "Reminder: invoices for {auction} are ready to send" |
| `weekly_promo` | — | replaced entirely, §2.4 (the command additionally **skips** any user where `user_prefers_push()` is true) |

Bookkeeping that currently means "emailed" (e.g. `Invoice.email_sent`,
`AuctionHistory` entries) is set the same way when the push path is taken — the
notification was delivered, just via a different channel; note it in the history
string ("push notification sent to …").

## 2.4 Promo pushes (weekly-promo replacement)

New Celery beat task, e.g. hourly (add to `setup_celery_beat`):

```python
@shared_task(bind=True, ignore_result=True)
def promo_push_notifications(self): ...
```

Algorithm:

1. Candidate auctions: `is_deleted=False`, `promote_this_auction=True`,
   `use_categories=True` (mirror the weekly-promo email filters),
   `date_start > now`, and `now >= max(date_posted + 24h, date_start - 7d)`.
2. Candidate users: `user_prefers_push()` true, `has_unsubscribed=False`,
   location known (`latitude/longitude` not 0), and the relevant existing
   opt-in still respected — `email_me_about_new_auctions` (+ its distance) for
   online auctions, `email_me_about_new_in_person_auctions` (+ its distance)
   for in-person. The prefs keep their meaning; push users just get them as
   notifications per-auction instead of a weekly digest.
3. Distance: nearest `PickupLocation` of the auction vs. user location, via the
   existing `distance_to` annotation (same query shape as `weekly_promo`),
   compared against the user's configured distance for that auction type.
4. Dedupe: skip if `PushNotificationSent(user, category="promo", auction)`
   exists — **one push per auction per user, ever** (edits/restarts don't
   re-notify).
5. Send: "{title} — {distance} miles away, starts {date}" → auction URL.
   `F()`-increment `Auction.promo_push_notifications_sent` per push sent.

Surface `promo_push_notifications_sent` wherever `weekly_promo_emails_sent`
appears (auction stats page / `update_auction_stats` cached stats). Click
tracking is out of scope for v1 (would need a redirect URL like the email
clicks counter; note as future work).

## 2.5 Mobile API changes

- `POST /api/mobile/devices/register/` — request/response gain `fcm_token`
  (optional string). Upsert semantics unchanged; a token seen on a *different*
  `device_uuid` row is cleared from the old row (FCM tokens follow app installs,
  not users — prevents cross-account leakage on shared devices).
- `POST /api/mobile/devices/unregister/` — new; body `{"device_uuid": "…"}`,
  auth required, clears `fcm_token` (keep the row for stats). The app calls it
  during sign-out, right before dropping the JWT. Signing out must stop pushes:
  a signed-out phone showing "your invoice is ready" for the previous user is a
  privacy bug.
- Registration is already called after login and app-start; the app will also
  re-register on FCM `onTokenRefresh`.

## 2.6 Out of scope for the backend (app work, for context)

- `firebase_messaging` plugin, per-flavor `google-services.json`,
  Android 13+ `POST_NOTIFICATIONS` runtime prompt (asked when the user flips
  the preference toggle in the WebView — bridged like the location prompt, or
  simply on next app start), notification channel setup, tap → open `url` in
  the WebView, sign-out unregister call.
- iOS: APNs key + entitlement, later, through the same Firebase project.

## 2.7 Tests to ship with the backend changes

- `notify_user`: push-preferring user gets no email + task queued; exempt
  `account` category always emails; no-token user falls back to email; global
  FCM-unconfigured falls back to email.
- Invoice task: `email_sent`/history set identically on the push path;
  idempotency preserved.
- `weekly_promo`: push-preferring users excluded; everyone else unchanged.
- Promo push timing: created-yesterday-starts-in-6-days → sends now;
  created-today → not yet; starts-in-9-days → not yet; started → never;
  dedupe on second run; distance in/out of range per auction type; counter
  increments; unsubscribed/no-location users excluded.
- Device register with token upsert; token moved between device rows; unregister
  clears token and stops sends.
- Dead-token pruning on FCM unregistered error (mock the admin SDK).

---

# Part 3 — AR Lot Scanning & Location Mapping

## Product requirements (recap)

- The auction rules page gets an **"AR Lots"** button next to "View Lots",
  visible to all users but **app-only** (`request.is_mobile_app`).
- In AR mode the app's camera scans lot QR codes and overlays each visible
  lot's name (or just a dot when many labels are in frame). The dot/chip is a
  **star** when the current user watches the lot and **green** when the lot is
  recommended for them.
- When a single lot is visible and roughly centered, the app shows a card with
  the lot picture (if any) and the **custom fields that print on labels in that
  lot's auction**, plus an "open lot page" button. Opening the page records a
  view with `src=ar`, which must also count as "QR scanned".
- As users scan, the app measures each label's direction from the camera and
  reports those observations; the **server** fuses them into a relative 2D map
  of lot locations. Recent scans outweigh old ones (lots get moved mid-auction)
  and nonsensical measurements are dropped.
- **Nothing may depend on the printed size of the QR code.** Sellers print on
  arbitrary label sizes, so apparent-size ranging is banned by design; all
  measurements are angles (bearing + gravity-referenced depression), which are
  size-independent and pixel-accurate.
- Auction admins get a **2D lot map** page: all located unsold lots, a
  "locate a lot" search, a "clear all locations" button, and a "% of unsold
  lots with a known location" indicator. Lots marked sold disappear from it.
- The lot detail page gets an app-only **"Locate with AR"** button that opens
  AR mode aimed at that lot; the app walks the user through scanning nearby
  labels until it can point at the target.

Division of labor, same as Parts 1–2: the app is a dumb sensor + display. It
turns QR sightings into `(bearing, depression)` angle measurements and renders
overlays from server-provided metadata; **all fusion, scoring, and history
live here.**

## What already exists (no work needed)

- QR content: `Lot.qr_code` → `https://<domain>/qr/<pk>/` (`models.py:7491`),
  route `lot_by_pk_qr` → `LotQRView` redirecting to `lot_link?src=qr`
  (`views.py:1505`). The app parses the pk straight out of the scanned URL.
- Scan tracking: the lot page's beacon POSTs `src` to `PageViewCreate`
  (`views.py:2166`) into `PageView.source`. No new plumbing — the app opens
  `lot_link?src=ar` and the beacon does the rest (one aggregate tweak below).
- App detection: `MobileAppMiddleware` sets `request.is_mobile_app`
  (`middleware.py:5`); `auction.html` already uses it.
- Watched: `Watch` rows (`models.py:9022`); recommended:
  `get_recommended_lots(...)` (`filters.py:994`).
- Custom label fields: `Auction.label_print_fields` +
  `custom_field_1_name` / `custom_checkbox_name` / `custom_dropdown_name`, and
  the per-lot `custom_field_1` / `custom_checkbox_label` /
  `custom_dropdown_label` properties (`models.py` ~2523–2563, ~7659).
- Admin plumbing: `AuctionViewMixin` (`views.py:319`) + `auction_ribbon.html`.

## 3.1 Models (new, `auctions/models.py`)

```python
class LotObservation(models.Model):
    """One AR sighting of a lot label from a phone camera frame.

    Raw solver input, pruned aggressively — this is a rolling measurement
    buffer, not history. All detections sharing (session_id, frame_id) were
    seen in the same camera frame, which is what makes them mutually
    constraining."""

    auction = models.ForeignKey(Auction, on_delete=models.CASCADE, related_name="ar_observations")
    lot = models.ForeignKey(Lot, on_delete=models.CASCADE, related_name="ar_observations")
    user = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL)
    session_id = models.UUIDField()          # one per AR screen mount
    frame_id = models.CharField(max_length=32)  # unique per camera frame within a session
    captured_at = models.DateTimeField()     # client clock, clamped to <= now on ingest
    created_at = models.DateTimeField(auto_now_add=True)
    bearing_deg = models.FloatField()        # horizontal angle in that frame's camera coords, +right
    depression_deg = models.FloatField()     # ray angle below horizontal (gravity-referenced), +down
    quality = models.FloatField(default=1.0) # 0..1, detection sharpness
    fov_calibrated = models.BooleanField(default=False)  # bearings from device-reported FOV?

    class Meta:
        indexes = [
            models.Index(fields=["auction", "captured_at"]),
            models.Index(fields=["session_id", "frame_id"]),
        ]


class LotPosition(models.Model):
    """Solved 2D position of a lot in an auction-local frame.

    Coordinates are meters in an arbitrary but solve-to-solve stable frame
    (origin/orientation pinned by priors, §3.2). Layout is bearing-accurate;
    absolute scale comes only from the soft phone-height prior (±30%), so
    treat as a relative map."""

    lot = models.OneToOneField(Lot, on_delete=models.CASCADE, related_name="ar_position")
    auction = models.ForeignKey(Auction, on_delete=models.CASCADE, related_name="ar_positions")
    x = models.FloatField()
    y = models.FloatField()
    confidence = models.FloatField(default=0)   # 0..1
    observation_count = models.IntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)
```

## 3.2 Solver (`auctions/ar_mapping.py`, new)

**Dependency:** add `numpy` + `scipy` to `requirements.in`. (GTSAM was
considered; a 2D bearing-graph doesn't need it, and the gtsam wheel is a
heavyweight C++ dependency. `scipy.optimize.least_squares` with a robust loss
covers this.)

Formulation — **bearing-dominant bundle adjustment** (triangulation, not
ranging), solved from scratch each pass over the observation window. Bearings
from QR corner centroids are good to ~0.1° regardless of how the label was
printed; that precision, across frames taken from different standing spots, is
what pins landmarks — there are no measured ranges anywhere.

- **Variables:** one camera pose `(x, y, θ)` per distinct `(session_id,
  frame_id)`; one landmark `(x, y)` per lot with surviving observations; one
  **height nuisance `h_j` per session** (phone height above the label plane,
  prior `0.65 ± 0.3 m` — standing phone ≈ 1.4 m, table labels ≈ 0.75 m).
- **Bearing residual** (the strong one): per observation,
  `wrap((atan2(Ly−Cy, Lx−Cx) − θ) − bearing_ccw) / σ_b`, where
  `bearing_ccw = −radians(bearing_deg)` and `σ_b = 0.01 rad` for
  `fov_calibrated` observations, `0.02` otherwise.
- **Depression pseudo-range** (the weak one — fixes scale and helps chain
  single-detection frames): when `depression_deg > 8°`, the label-plane model
  gives `r̃ = h_j / tan(depression)`; residual `(‖L − C‖ − r̃) / (0.5 · r̃)`.
  Level views (small depression) contribute no range information — correct,
  since a distant label and a near one look the same there.
- **Weights:** everything above additionally scaled by
  `w = quality · exp(−age_hours / 3)`. Observations older than 24 h or with
  `w < 0.05` are excluded — the "recent scans win" knob: a moved lot's old
  sightings fade on a ~3 h half-life and vanish within a day.
- **Frame chaining:** consecutive frames of one session within 10 s get a weak
  motion prior (soft residual on camera displacement beyond ~3 m, no heading
  prior). This lets single-detection frames chain A…B sweeps; frames with ≥2
  detections constrain lots directly through their bearing differences.
- **Gauge / stability:** each lot that already has a `LotPosition` gets a weak
  prior (weight ~0.1) pulling its landmark toward the previous solution, so
  the map doesn't rotate/flip between solves and the admin page doesn't swim.
  Cold start (no priors): pin the first landmark at the origin and the second
  to the +x axis.
- **Robustness:** `least_squares(loss="soft_l1")`; after convergence drop
  observations whose residual norm exceeds 3× the median and re-solve once
  ("dropping measurements that make no sense"). Provide `jac_sparsity` — the
  problem is very sparse and this keeps a 500-lot auction subsecond.
- **Output:** rewrite `LotPosition` rows for solved landmarks (confidence from
  surviving-observation count and mean residual; suggested
  `min(1, n_obs / 5) · exp(−mean_residual)`), delete positions whose lot no
  longer has surviving observations.

**Trigger & pruning:** the observations endpoint sets a cache flag
`ar_dirty_<auction_pk>`; a beat task `update_ar_positions` (every 60 s, same
pattern as `endauctions` in `fishauctions/celery.py`) solves flagged auctions
and deletes `LotObservation` rows older than 24 h. A 60 s cadence is plenty —
the map is an admin overview, not a live tracker.

**Accuracy & scale:** relative positions within a well-scanned cluster land in
the centimeter-to-decimeter band (bearing-limited); that's what the app's
ghost marker projects from, and it is scale-free. Absolute meters come only
from the soft height prior, so treat them as ±30% — fine for the admin map
(relative layout) and the "about N m" locate readout, and it never distorts
the layout itself.

## 3.3 Mobile API (`auctions/mobile/`, three new endpoints)

All: `permission_classes = [IsMobileAuthenticated]`,
`throttle_classes = [ScopedRateThrottle]` with a **new scope**
`"mobile_ar": "240/min"` (an active AR session ships a metadata fetch or an
observation batch every few seconds; `mobile_api`'s 1000/hour would starve it —
same reasoning that created `mobile_search`). Routes in `mobile/urls.py`:
`ar/lots/`, `ar/observations/`, `ar/positions/`.

### `GET /api/mobile/ar/lots/?auction=<slug>&lots=<pk,pk,...>`

Overlay + card metadata for up to **50** scanned pks per call. Any
authenticated user — this returns nothing beyond what the public lot page
shows, plus the caller's own watch/recommendation state.

```json
{
  "auction": {"slug": "tfcb-2026", "title": "TFCB Annual Auction"},
  "lots": [
    {
      "pk": 123,
      "in_auction": true,
      "lot_number": "45",              // Lot.lot_number_display
      "name": "Apistogramma cacatuoides pair",
      "thumbnail_url": "https://…",    // Lot.thumbnail image URL or null
      "watched": true,
      "recommended": false,
      "sold": false,                    // Lot.sold
      "removed": false,                 // banned or is_deleted or deactivated
      "lot_url": "/lots/123/apisto-pair/",  // Lot.lot_link (path)
      "label_fields": [{"label": "Table", "value": "3"}],
      "has_position": true
    }
  ]
}
```

- `auction` resolves by slug (404 if missing).
- `watched`: one `Watch.objects.filter(user=…, lot_number__in=…)` query.
- `recommended`: membership in `get_recommended_lots(user=…, auction=…,
  qty=25)` — compute the recommended-pk set once and cache per
  `(user, auction)` for 5 min; it's an ordering annotation, not a flag, and is
  too expensive per-scan otherwise.
- `label_fields`: only the auction's **custom** fields, only when present in
  `auction.label_print_fields`, in that field-list's order:
  `custom_field_1` (label = `auction.custom_field_1_name`),
  `custom_checkbox_label` (label = `auction.custom_checkbox_name`),
  `custom_dropdown_label` (label = `auction.custom_dropdown_name`). Skip
  fields whose per-lot value is empty. Reuse the existing Lot properties — do
  not re-derive display strings.
- pks not in this auction (someone scans a stray label): return the row with
  `in_auction: false` and name/thumbnail only — the app shows a neutral chip
  and sends no observations for it. Deleted/unknown pks: `in_auction: false`,
  `removed: true`, `name: null`.
- `has_position`: whether a `LotPosition` row exists (drives the app's
  "this lot hasn't been mapped yet" message in locate mode).

### `POST /api/mobile/ar/observations/`

```json
{
  "auction": "tfcb-2026",
  "session_id": "0d0f6c9e-…",
  "fov_hdeg": 68.4,
  "frames": [
    {
      "frame_id": "f000123",
      "captured_at": "2026-07-17T15:04:05.123Z",
      "detections": [
        {"lot": 123, "bearing_deg": -12.5, "depression_deg": 28.9, "quality": 0.8}
      ]
    }
  ]
}
```

- `fov_hdeg` (optional): the device-reported camera horizontal FOV the
  bearings were computed against. Present ⇒ store `fov_calibrated=True` on the
  batch's rows (tighter bearing σ in the solver); absent ⇒ the app used its
  assumed-FOV fallback.
- Limits: ≤50 frames/call, ≤10 detections/frame. Sanity bounds enforced
  server-side: `−90 ≤ bearing_deg ≤ 90`, `−90 ≤ depression_deg ≤ 90`,
  `0 < quality ≤ 1`; `captured_at` clamped to `now()`. Violations drop the
  detection, not the batch.
- Detections whose lot isn't in the auction (or is deleted/banned) are
  silently dropped — buyers scanning stray labels mustn't 400 the batch.
- Creates `LotObservation` rows, sets the dirty flag, returns
  `202 {"accepted": <n>}`. Any authenticated user: every scanning attendee is
  a data source, not just admins.

### `GET /api/mobile/ar/positions/?auction=<slug>`

```json
{
  "updated_at": "2026-07-17T15:04:05Z",
  "positions": [{"lot": 123, "x": 1.2, "y": -3.4, "confidence": 0.7}],
  "unsold_total": 210,
  "unsold_with_position": 140
}
```

- Positions only for lots that are **not sold and not removed** (`Lot.sold`,
  `banned`, `is_deleted`, `deactivated`) — selling a lot removes it here and on
  the admin map with no extra bookkeeping.
- Any authenticated user (locate mode needs it). `updated_at` = latest
  `LotPosition.updated_at` for the auction, null when empty.

## 3.4 Web template changes

- **`auction.html`** (Quick Actions, next to "View Lots" ~line 163): app-only
  sibling button —
  `{% if request.is_mobile_app %}<a href="fishauctions://ar/{{ auction.slug }}"
  class="btn btn-primary btn-sm w-100"><i class="bi bi-badge-ar"></i>
  AR Lots</a>{% endif %}`. Visible to every user (not admin-gated).
- **Lot detail page** (`view_lot_images.html` button row): app-only
  `{% if request.is_mobile_app and lot.auction %}<a
  href="fishauctions://ar/{{ lot.auction.slug }}?locate={{ lot.pk }}" …>
  <i class="bi bi-geo-alt"></i> Locate with AR</a>{% endif %}`.
- **Scan counting:** `Auction.number_of_lots_with_scanned_qr`
  (`models.py:3645`) currently filters `pageview__source__icontains="qr"`;
  widen to also count AR opens:
  `Q(pageview__source__icontains="qr") | Q(pageview__source__iexact="ar")`.
  The app opens lot pages as `lot_link?src=ar`; nothing else to record.

## 3.5 Admin lot map page (web, works on desktop too)

- **URL:** `auctions/<slug>/lot-map/` (name `auction_lot_map`), view
  `AuctionLotMap(LoginRequiredMixin, AuctionViewMixin, TemplateView)` —
  admin-only (default `allow_non_admins = False` path raises), template
  `auction_lot_map.html` with `{% include 'auction_ribbon.html' %}`; add a
  "Lot map" `dropdown-item` to the ribbon's More menu.
- **Data:** `auctions/<slug>/lot-map/data/` (admin-only JSON, same view module)
  returning the §3.3 positions payload plus `lot_number`/`name` per row and
  the full unsold-lot list `[{pk, lot_number, name, has_position}]` for the
  locate search. The page polls it every ~10 s.
- **Render:** inline SVG sized to the position extent (padded viewBox, equal
  axis scale). One dot per located unsold lot, `lot_number_display` as the dot
  label, confidence → opacity, click → small popover with lot name + link.
  No basemap — the frame is relative, there's nothing to draw under it.
- **Controls:**
  - *Locate a lot:* search/datalist over the unsold-lot list; selecting one
    with a position pans/highlights its dot (pulse animation); without one
    shows "no location known yet".
  - *Clear all locations:* POST `auctions/<slug>/lot-map/clear/` (CSRF,
    JS confirm) → deletes the auction's `LotObservation` + `LotPosition` rows.
  - *Coverage stat:* "140 of 210 unsold lots located (67%)" from the data
    payload.

## 3.6 Settings / infra summary

- `DEFAULT_THROTTLE_RATES["mobile_ar"] = "240/min"`.
- `requirements.in`: `numpy`, `scipy`.
- Beat schedule: `update_ar_positions` every 60 s.
- Migration for the two models + indexes.
- **Optional but high-leverage: print the label QR larger.** Nothing in the
  math uses QR size, but *decode distance* scales linearly with printed size —
  a ~15 mm code decodes at roughly 1 m, a 40 mm one at 2.5 m+ (the app scans
  at 2560×1440). A bump to the label template's `qr_from_text size=…` is the
  cheapest way to make AR usable from further back; entirely a product knob,
  no contract impact.

## 3.7 Out of scope for the backend (app work, for context)

- Camera + QR detection (`mobile_scanner` at 2560×1440), angle measurement
  from QR corner centroids + the gravity vector against the device-reported
  camera FOV (platform channel; assumed-FOV fallback), observation batching,
  the overlay/card UI — all in the app, already implemented against this
  contract.
- Locate mode is app-side too: bearing-only resection from ≥3 mapped lots
  gives the coarse compass arrow, and when mapped lots are on screen the app
  fits a map→screen homography and projects the target directly into the
  camera view (the "ghost pin") — that path never touches ranges or scale, so
  its precision is the map's local accuracy.
- The app degrades gracefully until Part 3 lands: scanning still overlays
  lot pks parsed from the QR itself and the lot-page button still works;
  metadata/observations/positions calls that 404 simply disable those layers.

## 3.8 Tests to ship with the backend changes

- `ar/lots/`: JWT required; batch cap; watched/recommended flags per-user;
  `label_fields` honors `label_print_fields` + auction custom-field names and
  skips empty values; cross-auction pk → `in_auction: false`; deleted pk →
  `removed: true`.
- `ar/observations/`: JWT required; rows created with clamped `captured_at`;
  out-of-range angles dropped while valid siblings persist; cross-auction
  lots dropped; frame/detection caps enforced; `fov_hdeg` present/absent →
  `fov_calibrated` set/cleared; dirty flag set; 202 shape.
- `ar/positions/`: sold/banned/deleted lots excluded; unsold counters right;
  empty auction → empty payload with null `updated_at`.
- Solver (`ar_mapping`) unit tests, synthetic geometry: a square of 4 lots
  observed from a few poses is recovered up to a similarity transform
  (compare shape, not meters — scale is prior-driven); an outlier observation
  is rejected; a "moved lot" converges near its new spot once fresh
  observations outweigh stale ones; a second solve with priors keeps the old
  frame (no rotation/flip); depression + height prior recovers roughly
  metric scale for a synthetic standing-height session.
- Web: map page + data + clear are admin-only (403 for a buyer); clear wipes
  both tables; `number_of_lots_with_scanned_qr` counts `src=ar` PageViews.
