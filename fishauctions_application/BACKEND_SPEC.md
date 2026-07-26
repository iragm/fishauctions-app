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
nothing breaks and nothing is recorded.

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
