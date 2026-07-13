# Backend Spec — Web-Configurable Printing & Push Notifications

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

# Amendments (post-implementation)

Part 1 is implemented on the backend and verified against staging (2026-07).
Part 2 is also implemented server-side (`notifications.py` choke point,
`send_push_to_user` / `promo_push_notifications` tasks, `UserData.
push_notifications_instead_of_email`, firebase-admin) but is inert until
`FIREBASE_CREDENTIALS_JSON` is provisioned and the app ships real FCM tokens
(see CLAUDE.md "What's NOT Done Yet" → Push notifications for the app-side
list). Two small backend items are still owed:

**`GET /lots/my-last-auction/` — redirect for the app's home-screen shortcut.**
The app registers a "Lots in my last auction" quick action (long-press the
launcher icon; `ShortcutService`). Only the server knows
`userdata.last_auction_used`, so the shortcut points at this URL:

- `login_required`. 302 to `/lots/?auction=<userdata.last_auction_used.slug>`
  when set (and the auction isn't deleted); plain `/lots/` otherwise.
- No template, no query params in, nothing else — a `RedirectView`-sized view.
- Until it lands, that one shortcut 404s in the WebView (the other two,
  `/selling/` and `/invoices/`, already exist).

**Push: two backend changes — see `PUSH.md` Part D for the exact prompt.** The
app side is implemented and reads its Firebase *client* config from
`/api/mobile/config/` (public values, same as `square_application_id`; the
secret `FIREBASE_CREDENTIALS_JSON` stays server-side). Owed server-side:
(1) add a flat, per-platform, self-tagged `firebase` block to `MobileConfigView`
(shape in `PUSH.md`), and (2) make `send_fcm_message` a **notification+data
hybrid** (add `notification=messaging.Notification(title, body)`, keep `data`
for tap-routing, add an `apns` block for sound/priority) so the OS displays it
in background/terminated on both platforms — the current data-only message never
displays on iOS. `FIREBASE_CREDENTIALS_JSON` itself is already wired; just set it
per deployment.

**`escpos-raster` seed row: `print_width_px` should be 384, not 96.**
(Still owed.)
`auctions/printer_programs.py` `SEED_PROFILES` seeds the generic
"Raw ESC/POS raster (GS v 0)" fallback with `print_width_px: 96` — that's the
D11s's 12 mm head, not a generic ESC/POS geometry. Nearly every BLE ESC/POS
printer is a 58 mm unit with a 384-dot head @ 203 dpi; at 96 px it prints a
~12 mm-wide strip. Change the row to `print_width_px: 384` (the app's bundled
copy already says 384). Since migration 0320 already ran, edit the value in
`SEED_PROFILES` **and** update the existing row (Django admin edit on each
deployment, or a tiny data migration re-running the seed's `update_or_create`).
The other seed fields now match the app bundle byte-for-byte — keep it that way
when editing rows the bundle mirrors (`d11s-aiyin`, `d11s-lujiang`,
`escpos-raster`).

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
