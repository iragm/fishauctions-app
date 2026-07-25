# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part 8 — Printer identification (open)

**Problem.** Pairing a Bluetooth printer asks the user "what kind of printer is
this?" whenever the advertised BLE name matches no profile's
`ble_name_patterns`. That's most printers: the name is user-editable, and the
same board ships as "D11", "Fichero", "AiYin" and whatever the reseller typed.
The user is the worst possible source for this answer — picking wrong sends a
different command language and prints garbage.

**App side (done).** On a name miss the app now connects, reads the printer's
GATT Device Information Service (0x180A: manufacturer 0x2A29, model 0x2A24,
firmware 0x2A26, hardware 0x2A27) and the services it exposes, and matches on
that. Ladder in `matchProfileForDeviceInfo`: model/manufacturer patterns first,
then a service UUID *only if exactly one profile claims it* (`18f0` is shared
by half the cheap-printer market, and by both D11s profiles, so it can't
disambiguate them). Still no match ⇒ the same manual dialog, now showing what
the printer reported, with a copy button.

Two backend pieces make that self-improving:

### 8.1 Match on what the printer reports

Add to `ThermalPrinterProfile`, alongside `ble_name_patterns`:

```python
model_patterns = models.JSONField(default=list, blank=True)
manufacturer_patterns = models.JSONField(default=list, blank=True)
```

Case-insensitive regexes, same semantics as `ble_name_patterns`. Serve them in
the `match` section of `GET /api/mobile/printers/profiles/`:

```json
"match": {
  "ble_name_patterns": ["^d11", "^fichero", "^aiyin"],
  "model_patterns": ["^d11"],
  "manufacturer_patterns": ["aiyin"],
  "service_uuid": "000018f0-0000-1000-8000-00805f9b34fb",
  ...
}
```

The app already parses both keys and treats them as empty when absent, so this
ships without an app release — and once seeded, a renamed printer of a known
model pairs with no questions asked. **Seed the two D11s rows** with whatever
`model`/`manufacturer` real units report (the reports below will say), and keep
`bundled_printer_profiles.dart` in sync.

### 8.2 `POST /api/mobile/printers/observed/` — build the list of what works

Fired once per successful pairing, fire-and-forget (the app ignores the
response, and a 404 disables it for the process, so shipping this is optional
and non-breaking).

```
POST /api/mobile/printers/observed/
  Body: {
    "ble_name": "D11-4C21",
    "manufacturer": "AiYin",          // omitted when the printer didn't say
    "model": "D11S",
    "firmware": "1.0.3",
    "hardware": "V2",
    "service_uuids": ["18f0", "180a", "1800"],
    "profile_slug": "d11s-aiyin",     // null when the user cancelled out
    "matched_by": "bleName" | "deviceInfo" | "serviceUuid" | "manual"
  }
  Returns: 200/201, body ignored.
```

Store one row per (user, ble_name, model, profile_slug) with a `last_seen` and
a count — or just append; volume is a handful of rows per auction. What matters
is the admin list it produces:

- **`matched_by: "manual"` rows are the work queue.** Each one is a printer
  nobody had a profile for. The `model`/`manufacturer` in it is exactly what
  goes into `model_patterns` on a new (or existing) profile — after which that
  printer auto-pairs for everyone.
- **`matched_by: "deviceInfo"`/`"serviceUuid"` rows confirm** the patterns are
  working, and which printers people actually own.
- **Rows with a null `profile_slug` or an empty `model`** are printers that
  identify themselves as nothing; those need the BLE-name route, or a new
  profile driven by whatever protocol they turn out to speak.

Nice-to-have: a `printed_ok` flag posted after the first successful print, so
"what works" means *printed*, not just *paired*. Not implemented app-side yet —
say the word and it's a small addition.
