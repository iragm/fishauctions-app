# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part T — TSPL printer profile (VEVOR Y486BT and TSC-compatible printers)

**Verified on hardware 2026-07-26.** Real lot labels print correctly from a
VEVOR Y486BT over BLE with the row below. This is the highest-priority item
here: the app currently carries this profile in
`bundled_printer_profiles.dart` as a cold-start fallback, and the bundle is
supposed to mirror the seed rows, not diverge from them.

**Why it was needed:** none of the three existing profiles can drive a
TSC-compatible label printer. Both D11s rows are a 96-dot head speaking a
vendor `10 ff …` protocol, and `escpos-raster` sends `GS v 0`. The Y486BT —
and the large family of rebadged 4″ Chinese label printers it belongs to —
speaks **TSPL / CPCL / ZPL, never ESC/POS**. Choosing `d11s-aiyin` for one
produced the reported symptom, "The printer didn't confirm the print
finished": the D11s stop opcode means nothing to it, its `AA` ack never
arrives, and the `on_timeout: warn` branch fires.

### Two ways to add it

1. **Django admin (no deploy)** — create a `ThermalPrinterProfile` with the
   fields below. This is the designed path; a new printer should never need an
   app release.
2. **Seed migration (permanent)** — append to `SEED_PROFILES` in
   `auctions/printer_programs.py` plus a data migration, matching the existing
   three. Do this one, since the app bundles the same row.

### The row

```python
{
    "slug": "tspl-raster",
    "name": "TSPL label printer (VEVOR Y486BT, TSC-compatible)",
    "priority": 100,  # ahead of escpos-raster (900), behind the D11s rows
    "ble_name_patterns": ["^y486", "^y468"],
    "model_patterns": ["^y486"],
    # Deliberately empty. The Y486BT's Device Information Service reports
    # "Feasycom" / "FSC-BT986" — its *radio module*, which ships in dozens of
    # unrelated products. Matching on it would claim other vendors' hardware.
    "manufacturer_patterns": [],
    # VERIFIED GATT ids. The Y486BT is a Feasycom FSC-BT986 running Microchip's
    # transparent-UART service. These MUST be pinned: the service's first
    # *writable* characteristic is …6daa…, the module's CONTROL channel, so
    # discovery-by-guessing writes label rasters into the radio's configuration
    # instead of printing. The data pipe is …8841….
    "service_uuid": "49535343-fe7d-4ae5-8fa9-9fafd205e455",
    "write_characteristic_uuid": "49535343-8841-43f4-a8d4-ecbe34729bb3",
    "notify_characteristic_uuid": "49535343-1e4d-4bd9-ba61-23c647249616",
    # A 3x2 label at 203 dpi is ~31 KB; a 4x6 is ~124 KB. 200-byte chunks at
    # 20 ms would spend ~12 s in pure pacing delay. The app still clamps every
    # chunk to the live ATT MTU (185 on this unit), so this is a pacing hint.
    "chunk_size": 500,
    "chunk_delay_ms": 5,
    "prefer_write_with_response": True,
    "print_width_px": 832,  # 4.09" head at 203 dpi
    "dpi": 203,
    # TSPL BITMAP prints on a *0* bit ("one = not painted, zero = painted"),
    # the opposite of ESC/POS. Without this every label comes out solid black,
    # which burns through a roll fast.
    "invert_raster": True,
    "max_label_width_mm": 104.0,
    "max_label_height_mm": None,
    "print_program": [
        {"tx_text": "SIZE {width_mm} mm,{height_mm} mm\r\nDIRECTION 0\r\nREFERENCE 0,0\r\nCLS\r\n"},
        # BITMAP x,y,width_in_BYTES,height_in_DOTS,mode — the binary raster
        # follows the comma immediately, then PRINT terminates the job.
        {"tx_text": "BITMAP 0,0,{width_bytes},{height_px},0,"},
        {"tx_raster": True},
        {"tx_text": "\r\nPRINT {copies},1\r\n"},
    ],
    # TSPL real-time status query <ESC>!? → one status byte. VERIFIED on
    # hardware: 0x00 ready, 0x07 with the lid open. See "Status byte" below —
    # these masks are a lossy fit and the app compensates by ordering.
    "status_program": [{"tx": "1b 21 3f"}],
    "status_flags": {
        "byte": 0,
        "flags": {"cover_open": "01", "paper_jam": "02", "out_of_paper": "04", "printing": "20"},
    },
    # Empty on purpose — see "Media size" below.
    "label_size_program": [],
    "label_size_parse": {},
    "notes": "TSPL/TSC-compatible direct thermal. Verified against a VEVOR Y486BT 2026-07-26.",
}
```

### Deliberate omissions, and what to tune if a unit misbehaves

Each of these is an admin edit, not a release:

- **No `GAP` command.** The Y486BT calibrates its own gap on power-up, and a
  wrong `GAP` makes it feed blank labels hunting for a notch. If a user
  reports mis-feeds on die-cut stock, add `GAP 2 mm,0 mm\r\n` to the first
  `tx_text`.
- **No `await` step.** TSPL has no print-completion ack, so the profile must
  not wait for one. Adding an `await` here would resurrect exactly the
  "couldn't confirm the print finished" warning this row exists to fix.
- **`DIRECTION 0`** is the TSPL default. Flip to `1` if labels come out upside
  down on some unit.

### Status byte — `status_flags` can't express what TSPL actually returns

**Measured, not theorised.** A VEVOR Y486BT with its lid open and a full roll
loaded answers `<ESC>!?` with **`0x07`**. TSPL's status byte is an
*enumeration*, not a set of independent bits:

```
00 normal         01 head open          02 jam          03 jam + head open
04 out of paper   05 no paper + open    06 no ribbon    07 no ribbon + open
08 no ribbon + jam                      0A no ribbon + no paper
10 pause          20 printing           80 other error
```

`status_flags` only supports bitmasks, so `0x07` decodes as `cover_open` **and**
`paper_jam` **and** `out_of_paper` at once — and the first version of this told
the user to load labels that were already in the printer.

**App-side mitigation (already shipped):** `ProfilePrinterStatus.blocker`
reports `cover_open` before anything else. Every odd value in that table means
"head open", so the 0x01 bit is correct regardless of how the rest decodes, and
a shut-lid `0x04` / `0x02` still reports out-of-paper / jam properly. Verified
end to end: lid open → "The printer cover is open. Close it, then try again." →
lid closed → `0x00` → prints.

**Optional backend improvement.** If more TSPL printers arrive, give
`status_flags` an explicit value form so the enumeration is expressed rather
than survived:

```jsonc
"status_flags": {
  "byte": 0,
  "kind": "value_map",          // default stays "bitmask" — existing rows unaffected
  "mask": "0f",                 // low nibble carries the enumeration
  "values": {                   // decimal key → flag names
    "1": ["cover_open"],        "2": ["paper_jam"],
    "3": ["paper_jam", "cover_open"],
    "4": ["out_of_paper"],      "5": ["out_of_paper", "cover_open"],
    "7": ["cover_open"]
  },
  "bits": {"printing": "20", "paused": "10", "error": "80"}  // these really are bits
}
```
`_validate_status_flags()` would need to accept `kind`/`values`/`bits`, and the
app a matching branch in `_decodeStatus`. Until then the ordering above is
correct for every state that matters.

### `paper_jam` — new status flag, no backend change needed

`status_flags.flags` had no jam concept; the vocabulary was `printing`,
`cover_open`, `out_of_paper`, `low_battery`, `overheated`. TSPL reports jams
(bit `0x02`), and a jam is the most common thing that stops a check-in table.

`_validate_status_flags()` accepts any flag name with a valid hex mask, so the
row above already validates as-is. Recorded here only so the vocabulary is
documented in one place. App side is done: `paper_jam` maps to "The printer
has a label jam. Open the cover, remove the jammed label, close it, then try
again.", and is checked *before* `cover_open` — printers commonly report both,
and "close the cover" is the wrong instruction while a label is stuck.

---

## Part U — Adding new printers without an app release

The goal: **collect what a printer is from the app, push a profile to the web,
done** — with no "pick your printer type" dialog in front of the user.

Most of this already works. `printers/profiles/` is fetched (and cached) by
every install, `printers/observed/` records unknown printers, and the app
matches BLE name → DIS model/manufacturer → service UUID. Three gaps remain.

### U1. Store what the printer answered — `probe_replies` on `ObservedPrinter`

**The problem this solves.** When a printer matches no profile, the only
evidence anyone had to author one from was its BLE name and its DIS strings —
and on the Y486BT the DIS is `Feasycom` / `FSC-BT986`, the radio module. That
is not enough to write a profile, so somebody has to own the hardware.

The app now asks the print engine itself. On the identify path it sends the
standard read-only status/identity query of each command language and records
what answers (`lib/services/printer_probe.dart`). Which query answers *is* the
command language, and the payloads often carry a model string or media size.
It rides along in the `printers/observed/` POST:

```jsonc
POST /api/mobile/printers/observed/
{
  "ble_name": "Y486BT_AB10-BLE",
  "manufacturer": "Feasycom", "model": "FSC-BT986", "hardware": "1.3",
  "service_uuids": ["1800", "1801", "180a", "49535343-…", "fff0", "fee7"],
  "profile_slug": "tspl-raster",
  "matched_by": "bleName",

  // NEW — both optional, absent when the printer was matched without probing.
  "probe_replies": {                       // only queries that got an answer
    "tspl_status": {"hex": "00", "ascii": "."}
  },
  "probed_language": "tspl"                // tspl|escpos|zpl|cpcl|d11s|null
}
```

**Backend work:**
- `ObservedPrinter.probe_replies = models.JSONField(default=dict, blank=True)`
- `ObservedPrinter.probed_language = models.CharField(max_length=20, blank=True, default="", db_index=True)`
- Accept both in `ObservedPrinterSerializer` as optional; keep the existing
  "truncate rather than 400" behaviour.
- Surface them in the admin list. `probed_language` is the single most useful
  column for triaging unsupported printers — it says which profile family a
  new row belongs in.

**Until this lands** the app still sends the fields; DRF drops unknown keys, so
nothing breaks and nothing is recorded. **That silent drop is the reason this
is the highest-value item in Part U**: the app has been collecting exactly the
evidence needed to author profiles, and the server has been discarding it on
arrival. Part Y adds three more fields to the same payload and depends on this
one being accepted first.

### U2. `matched_by` needs a `probe` choice

`MATCHED_BY_CHOICES` is a strict `ChoiceField`, so an unknown value 400s the
whole report. The app therefore reports probe-derived matches as `deviceInfo`
today (`ProfileMatch.wireName`).

Add `("probe", "Command-language probe")` to `MATCHED_BY_CHOICES`, then delete
the `wireName` mapping in `lib/models/printer_profile.dart` so the two agree.
Without it, "the printer told us over GATT" and "we worked out its language by
asking it" are indistinguishable in the admin.

### U3. `command_language` on `ThermalPrinterProfile` — kills the picker

This is the one that removes the dialog for most printers.

The app auto-selects a profile when a probe identifies a language and **exactly
one** profile speaks it. Today it works out a profile's language by reading its
own print program (`PrinterProfile.inferredLanguage` — TSPL if the program
contains `BITMAP`, ESC/POS if `1d7630`, and so on). That is honest, since the
bytes *are* the language, but it's inference over data the backend could just
state.

**Backend work:**
```python
COMMAND_LANGUAGE_CHOICES = [
    ("tspl", "TSPL / TSPL2 (TSC-compatible)"),
    ("escpos", "ESC/POS"),
    ("zpl", "ZPL"),
    ("cpcl", "CPCL"),
    ("d11s", "D11s vendor protocol"),
    ("other", "Other / vendor-specific"),
]
command_language = models.CharField(
    max_length=20, choices=COMMAND_LANGUAGE_CHOICES, blank=True, default=""
)
```
Serialize it into the `raster` block's sibling — top level is fine:
`"command_language": profile.command_language`. Seed values: `tspl-raster` →
`tspl`, `escpos-raster` → `escpos`, both D11s rows → `d11s`.

The app should then prefer the declared value and fall back to inference for
older deployments.

**Why uniqueness is the rule:** knowing a printer speaks TSPL does not tell you
its printhead width or GATT ids, so picking one of several TSPL profiles at
random would drive it wrong. One candidate means there is nothing to get wrong;
more than one is a genuine question and the only case worth putting to a user.

### U4. Profile names are user-facing — rename `escpos-raster`

When the app does have to ask, it shows `profile.name`. "Raw ESC/POS raster
(GS v 0)" is meaningless to an auction volunteer. Profile names should read as
*printers*, not protocols — the user is looking at a box on a table.

Suggested: **"Other thermal printer (ESC/POS)"**, and as more printers are
catalogued via U1, add model-named rows ("MUNBYN ITPP941", "Phomemo M120")
even where they share a command program. The app already sorts likely matches
first and explains that a test label will confirm the choice.

---

## Part V — `/printing/` page: reach the printer settings when connected

Small, and it blocks the feature that makes profile-picking safe.

The Bluetooth card renders a **"Connect a printer"** button only while
disconnected. Once a printer is connected the card shows its name and
**Unpair** — so there is no way back into the native sheet, and the sheet is
where **Print test label** lives. Today the only route to a test print is to
unpair and re-pair, which is exactly the wrong instruction to give someone
whose printer is misbehaving.

**Change:** always render a button that calls the existing `printerConnect` JS
handler — labelled "Connect a printer" when disconnected and **"Printer
settings"** (or "Test print") when connected. No new bridge handler is needed;
`printerConnect` already opens the sheet and resolves with the current state.

While there: the card's connected state can also show the driver in use. The
handler already returns `profile` (the slug), and "which profile is driving
this" is the setting most likely to be wrong.

---

## Part W — Multi-lot Bluetooth printing (the app side has landed)

**The blocker is gone: `fishauctions://print/?lots=…` is implemented in the app
as of 2026-07-26, so the template change is safe to ship.** Previously a
Bluetooth user who tapped a *bulk* label button got a PDF sheet they can't feed
to a thermal printer, and the deep link wasn't handled — this part is what
closes that.

### W1. Emit the lot set for Bluetooth users

```
fishauctions://print/?lots=<comma-separated lot pks>
```

Built from the same querysets the PDF views already use — `AuctionTOS.print_labels_qs`
/ `AuctionTOS.unprinted_labels_qs` (and `Auction.unprinted_labels_qs` for the
auction-wide button) — **in the same order the PDF prints them**, since that's
the order the labels come out of the printer.

Emit it *instead of* the web label URL when
`user_print_method == 'bluetooth'` (the `label_print_method` context processor
already exposes this) **and** `request.is_mobile_app`. Everyone else keeps the
PDF, unchanged.

What the app does with it: connects once, then loops the existing single-lot
raster path over the list, showing a progress count with a **Stop** action.
There is no screen — see W3.

Places that build a bulk label link, all of which need the switch:

| Where | What it builds |
| --- | --- |
| `AuctionTOS.print_labels_link_html` / `print_unprinted_labels_link_html` (models.py) | the users-table anchors — server-rendered HTML, so this is a one-line branch per property |
| `Auction.label_print_link` / `label_print_unprinted_link` (models.py) | `?printredirect=` links |
| `auction.html`, `user_labels.html`, `lot_user_table_header.html`, `bulk_add_lots_auto.html` | `{% url 'print_my_labels' … %}` / `print_labels_by_bidder_number` buttons |
| `BulkAddLots` redirect (views.py ~6279, the `printredirect=` branch) | print-after-adding-lots |

**`printredirect` needs one extra change.** The base.html handler deliberately
rejects anything that isn't same-origin (`url.origin === window.location.origin`),
so a `fishauctions:` value is silently dropped. Allow the scheme through when
`request.is_mobile_app` — synthesizing the same `<a>` click, which is exactly
how the per-lot deep link already reaches the app — or keep `printredirect`
same-origin and gate at the *view* instead (below).

**Keep a link under ~2000 characters** (≈300 pks). Beyond that prefer the
unprinted variant; the app itself has no cap (it prints serially, cancellable),
but URL length limits vary by platform. Note the PDF path's own 100-label cap
does not apply here — nothing is being laid out on a page.

**Alternative worth considering: gate in `LotLabelView.dispatch` instead of in
N templates.** Every bulk entry point — buttons, `printredirect`, the command
palette, a bookmarked URL — funnels through that one view, and the app already
intercepts the *single*-lot equivalent (`/lots/print/<pk>/`) for exactly this
reason: gating templates one by one leaves entry points behind. If you go that
way, respond with a small HTML page that navigates to the deep link rather than
a 302 to a custom scheme — a JS/anchor navigation is the path the app is known
to intercept today, a custom-scheme redirect is not, and it should be verified
against a build before shipping.

### W2. `POST /api/mobile/labels/printed/` — mark labels printed

New endpoint. Without it, "print unprinted labels" never shrinks for anyone
printing natively: the PDF views set `label_printed` as a side effect of
rendering (`LotLabelView.get_context_data` → `bulk_update`), and neither
`labels/<pk>/` nor the deep-link path goes through them. That's a pre-existing
gap for single-lot native prints; a batch of 40 makes it obvious.

```
POST /api/mobile/labels/printed/
  Body:    { "lots": [12, 13, 14] }
  Returns: { "marked": 3 }
```

- Permission per lot, same rule as `labels/<pk>/` (`_can_access`: the lot's
  seller TOS owner, an auction admin, or the lot's own user). Silently skip
  lots the user can't touch rather than failing the batch — some already
  printed fine.
- Sets `label_printed = True` and `label_needs_reprinting = False`, matching
  the PDF views exactly.
- Idempotent; a re-print posting the same pks is normal.

**The app already calls this** (`LabelPrintService.markPrinted`, after the
labels that actually went out — including the ones sent before a failure or a
cancel). It is fire-and-forget and self-disabling: a 404 turns it off for the
process, so a deployment without the endpoint behaves exactly as today.

### W3. What changed in the app, in case it affects the page copy

- **Bluetooth printing has no screen.** No preview before, no confirmation
  after: the label is sent and the user keeps their place, with a
  non-blocking progress message over the page they were on. Only failures
  interrupt — and a soft warning (the printer never acked) still surfaces.
  A `/printing/` page that promises a preview should stop.
- **The "System printer" method now goes straight to the OS print dialog** for
  a single lot, instead of a preview screen with a print button in it.
- **First print with no printer paired sends the user to `/printing/`** —
  once, per device. After that it's a "No printer connected" message with a
  **Set up** action. Unpairing resets it. So `/printing/` is now a landing
  page people arrive on mid-task, having tapped print somewhere else: the
  Bluetooth card wanting to be findable without scrolling matters more than it
  used to (and Part V's "reach the sheet while connected" is the other half of
  that).

---

## Part X — Command-program schema v2 (the app side has landed)

**The app already interprets v2** (`PrinterProfile.supportedSchemaVersion = 2`,
shipped 2026-07-26). Nothing uses it yet, and that is deliberate: an app can
only run a schema it was built with, so the reader has to ship *before* the
first row that needs it or the row costs a release after all. Everything below
is additive — every v1 row keeps working unchanged, and v1 remains the correct
`schema_version` for a profile that needs none of it.

Bump a profile to `schema_version: 2` **only** when it uses one of these.
Older app builds will then correctly ignore it rather than mis-drive a printer.

### X1. `{total_bytes}` placeholder + `{u32le:…}` width

**This is what unblocks ZPL, i.e. Zebra, i.e. the largest label-printer family
we currently cannot support at all.** ZPL's graphics command is:

```
^GFa,{total_bytes},{total_bytes},{width_bytes},<data>
```

`total_bytes` is `width_bytes × height_px`, and the schema has no arithmetic,
so no v1 profile can express it. Same shape appears in CPCL and several vendor
protocols.

- New scalar placeholder `total_bytes`, valid in `tx_text` (ASCII decimal) and
  in `{u32le:total_bytes}` (four-byte little-endian).
- New `u32le` function alongside `u16le`. `U32LE_PLACEHOLDERS = {total_bytes,
  width_bytes, height_px, width_px}` — 16 bits overflows on a real raster
  (a 4″ × 6″ at 203 dpi is ~270 kB).

**Validator change with teeth:** a *bare* `{name}` in a `tx` hex template
renders as a single byte, so only genuinely byte-sized values may appear there.
The app now rejects `{total_bytes}`, `{width_bytes}`, `{height_px}` and
`{width_px}` in that position **unconditionally** — not only when the value
happens to exceed 255. A size-dependent check would let a profile authored
against a small test label validate and then truncate a length field on the
first 4×6, printing half a label for a reason nobody can see. Please mirror
this in `_check_placeholders` so the admin form rejects it at authoring time:

```python
BARE_BYTE_PLACEHOLDERS = frozenset({"density", "paper_type", "copies"})
# every other scalar must be used via u16le:/u32le: inside a `tx`
```

### X2. `tx_raster` with an encoding

```jsonc
{"tx_raster": true}                       // v1, unchanged: raw bytes
{"tx_raster": {"encoding": "binary"}}     // v2, same thing, explicit
{"tx_raster": {"encoding": "hex"}}        // v2: uppercase ASCII hex
```

ZPL `^GFA` and CPCL `EG` carry the bitmap as ASCII hex rather than bytes and
cannot be driven without this. Hex doubles the bytes on the wire, so it stays
opt-in per profile. Validator: accept `true` or an object whose `encoding` is
`binary`/`hex`; reject `false` (a step that does nothing is a typo, not an
instruction to omit the label body).

### X3. `status_flags.values` — exact codes instead of a bitmask

**This is the one that pays for the Part Y capture flow**, and it fixes a real
wart in the current TSPL row.

```jsonc
"status_flags": {
  "byte": 0,
  "values": {                       // NEW: exact status byte → conditions
    "00": [],
    "01": ["cover_open"],
    "02": ["paper_jam"],
    "03": ["paper_jam", "cover_open"],
    "04": ["out_of_paper"],
    "05": ["out_of_paper", "cover_open"],
    "06": ["no_ribbon"],
    "07": ["no_ribbon", "cover_open"]
  },
  "flags": {"cover_open": "01", "paper_jam": "02"}   // kept as the fallback
}
```

Lookup order in the app: exact `values` match (hex key, `"0a"` style — a
decimal string key is also accepted) → else the `flags` bitmask → else ready.
So a partial `values` map is fine.

**Why:** TSPL's `<ESC>!?` answers an *enumeration*, not independent bits. A
Y486BT with nothing but its lid open answers `07`, which a bitmask reading
decodes as out-of-paper **and** jammed **and** open — telling the user to load
labels that are sitting right there. The app currently survives this by
checking `cover_open` first (every odd value in that table means head open),
which is a real trick that works but only for this one table. `values` states
the truth instead.

Recognised condition names: `cover_open`, `out_of_paper`, `paper_jam`,
`overheated`, `low_battery`, `printing`, and **`no_ribbon`** (new — the app now
has a message for it: "The printer is out of ribbon.").

The `tspl-raster` seed row in Part T should carry the `values` map above.

---

## Part Y — Turning an unknown printer into a profile automatically

The ask this answers: *pick a printer → it either works, or we collect
everything we can and generate a request to add it.* Part U covers what the app
can learn by **asking** the printer. This part covers the one thing no query can
discover — **what its status byte means** — plus getting the rest somewhere a
human can act on it.

**The app side has landed** (`lib/services/printer_characterization.dart`,
`lib/widgets/printer_characterize_sheet.dart`). A "Improve support" button in
the connect sheet walks the user through four physical states, capturing the
printer's status reply in each:

| step id | user does | means |
|---|---|---|
| `ready` | labels loaded, cover closed | (no conditions) |
| `cover_open` | opens cover, labels still in | `cover_open` |
| `no_labels_cover_open` | takes the roll out | `cover_open`, `out_of_paper` |
| `no_labels` | closes cover, still empty | `out_of_paper` |

Because each state's meaning is known in advance, the byte it produces is a
*derivation*, not a guess — the app computes the `status_flags.values` map from
X3 and sends it pre-built. Working this out for the Y486BT took someone with the
hardware and an afternoon; this is that afternoon as four button presses, done
by whoever happens to own the printer.

### Y1. Accept the extra fields on `printers/observed/`

All optional, all additive to the Part U1 payload:

```jsonc
POST /api/mobile/printers/observed/
{
  // … Part U1 fields (ble_name, model, probe_replies, probed_language, …)

  "gatt": [                          // full service/characteristic tree
    {"uuid": "49535343-fe7d-4ae5-8fa9-9fafd205e455",
     "characteristics": [
       {"uuid": "49535343-8841-43f4-a8d4-ecbe34729bb3",
        "properties": ["write", "writeNR"]},
       {"uuid": "49535343-1e4d-4bd9-ba61-23c647249616",
        "properties": ["notify"]}
     ]}
  ],

  "status_captures": {               // per state, per query
    "ready":                {"tspl_status": {"hex": "00", "ascii": "."}},
    "cover_open":           {"tspl_status": {"hex": "01", "ascii": "."}},
    "no_labels_cover_open": {"tspl_status": {"hex": "05", "ascii": "."}},
    "no_labels":            {"tspl_status": {"hex": "04", "ascii": "."}}
  },

  "derived_status_values": {         // ready to paste into a profile row
    "00": [], "01": ["cover_open"],
    "05": ["cover_open", "out_of_paper"], "04": ["out_of_paper"]
  },

  "status_ambiguities": [            // present only when the printer can't
    "01: cover_open and no_labels_cover_open are indistinguishable"
  ]
}
```

**Backend work:**
- `ObservedPrinter.gatt = models.JSONField(default=list, blank=True)`
- `ObservedPrinter.status_captures = models.JSONField(default=dict, blank=True)`
- `ObservedPrinter.derived_status_values = models.JSONField(default=dict, blank=True)`
- `ObservedPrinter.status_ambiguities = models.JSONField(default=list, blank=True)`
- `characterized = models.BooleanField(default=False)` — set when
  `status_captures` is non-empty. This is the admin's work queue filter:
  a characterized row has everything needed to write a profile.
- Same leniency as the rest of the endpoint: cap the JSON size, never 400.

**`gatt` matters on its own.** A profile's `service_uuid` /
`write_characteristic_uuid` / `notify_characteristic_uuid` can only be filled
in by someone who can see this tree, and picking them wrong is *silent* — the
Y486BT's first writable characteristic is its radio module's control channel,
so labels went nowhere. Until now that tree existed only in a logcat buffer on
the user's phone.

### Y2. Admin action: "Draft a profile from this observation"

The payoff. On a characterized `ObservedPrinter`, one action that creates a
disabled `ThermalPrinterProfile` pre-filled from the row:

| profile field | from |
|---|---|
| `slug` / `name` | model or BLE name, slugified — editable |
| `model_patterns` | `^` + the reported model, escaped |
| `manufacturer_patterns` | the reported manufacturer |
| `service_uuid`, `write_characteristic_uuid`, `notify_characteristic_uuid` | `gatt`: the vendor service, its writable characteristic, its notify characteristic (skipping `1800`/`1801`/`180a`/`180f`) |
| `command_language` | `probed_language` (Part U3) |
| `print_program`, `status_program` | the language's template (see below) |
| `status_flags` | `{"byte": 0, "values": derived_status_values}` |
| `schema_version` | 2 when the template or status map needs it |
| `notes` | the raw `probe_replies` + any `status_ambiguities`, verbatim |
| `enabled` | **False** — a human confirms, then the user's next print picks it up |

Keep a small dict of per-language `print_program` templates (the TSPL one is
Part T's; ESC/POS is the `escpos-raster` row's; ZPL is now expressible with
X1+X2). `print_width_px` and `dpi` are the only fields that still need human
judgement, and they can be read off the printer's spec sheet.

Left disabled by default because a drafted profile is a hypothesis: the person
who submitted it is the one holding the printer, and **"Print test label"** in
the app is what confirms it.

### Y3. Optional, later: tell the user when their printer lands

An `ObservedPrinter` knows its `user`. When a profile whose `model_patterns`
match a previously-`manual` observation is enabled, that user's next connect
will silently start matching properly — but a notification ("your printer is
supported now, reconnect it on the printing page") closes a loop that otherwise
looks to them like nothing happened. Rides the Part 2 push pipeline; skip until
that is live.

---

## Media size — why there is no auto-detection

Asked for, investigated, **not possible on this printer.**

TSPL has no standard "what media is loaded" query. The Y486BT was probed
directly with the TSPL system commands `~!T` (model/version) and `~!I` (code
page): **no notify frame came back at all**, while `<ESC>!?` on the same link
answered immediately. Its automatic label recognition is internal and never
reported over the wire. So the label size has to keep coming from the user's
`UserLabelPrefs`.

The plumbing is already in place and costs nothing to leave: `label_size_program`
+ `label_size_parse` (an `ascii_regex` with `w`/`h` named groups) →
`PrinterProfileDriver.readLabelSize()` → the `/printing/` page's offer to adopt
the reported size. For a printer that *does* answer — ZPL's `~HS` host status
returns media settings, and some CPCL units answer `getvar` — filling those two
fields in is a Django row edit. `PrinterProbe` now collects exactly the replies
needed to write that regex, so U1 is what makes this feasible for printers
nobody here owns.
