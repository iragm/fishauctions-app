# CLAUDE.md — FishAuctions Flutter App

## What This Is

A Flutter mobile client for the FishAuctions auction platform. The app is architecturally a **thin WebView shell + native hardware layer**:

- WebView loads the existing Django web UI (authenticated via JWT injected as cookies/headers)
- Native Flutter code handles hardware the web can't reach: Square Tap to Pay, Bluetooth label printing, barcode scanning

The Django backend lives at https://github.com/iragm/fishauctions. Do not rewrite it — extend it via the `/api/mobile/` namespace.

**A local checkout of that backend repo is available at `/home/user/staging/fishauctions`.** Use it as a reference — read its code, check what `/api/mobile/` endpoints actually exist/return, confirm model fields, etc. — instead of guessing or relying solely on this file staying in sync.

- **Never edit files in `/home/user/staging/fishauctions`.** It's a separate repo outside this app's scope. If backend changes are needed (a new endpoint, a field, a migration), write up the spec (endpoint shape, request/response, model change) and hand it to the user to implement there — do not open Edit/Write against that path under any circumstances.
- **Prefer the web backend over native/local app logic.** When a feature could be done either by adding logic/state to the Flutter app or by extending the Django backend and having the WebView/API surface it, default to the backend. Only keep something local in the app if there's a concrete reason it must be — hardware access the web can't reach (Bluetooth, NFC/Tap to Pay, camera/barcode scanning), true offline requirements, or a native platform API with no web equivalent. This matches the WebView-first architecture below: the web UI is the source of truth for business logic and display.

## Running the App

```bash
# Android — --flavor picks the applicationId; --dart-define picks the backend.
flutter run --flavor dev -t lib/main.dart --dart-define=FLAVOR=dev          # staging backend
flutter run --flavor staging -t lib/main.dart --dart-define=FLAVOR=staging  # staging backend
flutter run --flavor prod -t lib/main.dart --dart-define=FLAVOR=prod        # production

# iOS — no --flavor (no Xcode schemes; env selection is dart-define only).
flutter run -t lib/main.dart --dart-define=FLAVOR=staging
```

Three Android flavors are configured in `android/app/build.gradle.kts`:
- **dev**: `com.fishauctions.app.dev`
- **staging**: `com.fishauctions.app.staging`
- **prod**: `com.fishauctions.app`

`lib/config/environment.dart` maps `--dart-define=FLAVOR` → API base URL (dev
and staging both point at `https://staging.auction.fish`; there is no localhost
target — a phone can't reach one anyway). iOS state and remaining setup:
`IOS.md`.

## Architecture

```
lib/
  config/         # EnvironmentConfig (dev/staging/prod URLs, feature flags)
  models/         # Dart data classes (freezed)
  screens/        # UI: login, webview shell, payment, printing
  services/       # API client, auth service, printing service, payment service
  widgets/        # Shared UI components
  utils/          # Logger, error handling
```

**State management:** Riverpod (flutter_riverpod + riverpod_generator)  
**Navigation:** go_router  
**HTTP:** Dio  
**Secure storage:** flutter_secure_storage (JWT tokens)

## Backend API — /api/mobile/

Base URL is set per flavor in `EnvironmentConfig.apiBaseUrl`.

All endpoints (except login/refresh) require `Authorization: Bearer <access_token>`.

### Authentication

```
POST /api/mobile/auth/login/
  Body:    { "credential": "username_or_email", "password": "..." }
  Returns: { "access": "...", "refresh": "..." }

POST /api/mobile/auth/refresh/
  Body:    { "refresh": "..." }
  Returns: { "access": "...", "refresh": "..." }   ← rotation enabled

GET /api/mobile/auth/me/
  Returns: { "id", "username", "email", "first_name", "last_name", "is_staff", "date_joined" }
```

**Token config:** Access tokens expire in 60 min. Refresh tokens expire in 30 days with rotation — every refresh call returns a new refresh token; old one is blacklisted.

**Token storage:** Store both tokens in `flutter_secure_storage`. Never in SharedPreferences or memory only.

### Device Registration

```
POST /api/mobile/devices/register/
  Body:    { "device_uuid": "...", "device_name": "...", "platform": "ios"|"android", "app_version": "..." }
  Returns: { "id", "device_uuid", "device_name", "platform", "app_version", "created_at", "last_seen" }
```

Call this after login. Upserts by `device_uuid` — safe to call repeatedly.

### Label Printing

Printing is configured on the `/printing/` web page (print-method dropdown:
PDF default / System printer / Bluetooth) and the app branches on the user's
`print_method`. Full backend contract in `BACKEND_SPEC.md` Part 1; both sides
are implemented and live.

**Never send a binary `Accept` header to `/api/mobile/`.** DRF negotiates
content in `APIView.initial()` *before* authentication, against
`DEFAULT_RENDERER_CLASSES` — which the deployment leaves at JSON + browsable
HTML. `Accept: application/pdf` / `image/png` therefore 406s before the view
runs; that was the production "Could not load the label" bug (fixed 2026-07-25
by sending `*/*`, see `LabelService._accept` and `BACKEND_SPEC.md` Part 9).

```
GET  /api/mobile/labels/<lot_pk>/                   # RGB PNG (default fmt)
GET  /api/mobile/labels/<lot_pk>/?fmt=png&resolution=WxH&dpi=N   # exact raster
GET  /api/mobile/labels/<lot_pk>/?fmt=pdf           # single-lot PDF (WeasyPrint, user's prefs)
GET  /api/mobile/labels/prefs/   + PATCH            # UserLabelPrefs + computed warnings
POST /api/mobile/labels/printed/                    # mark label_printed (live)
GET  /api/mobile/printers/profiles/                 # ThermalPrinterProfile rows (ETag'd)
```

- **Bluetooth printing has no screen at all.** A print needs no confirmation:
  the shell (`LabelPrintService`) connects, renders and sends over whatever
  page the user was on, showing a non-blocking progress message (with a
  **Stop** action for a batch) and nothing else. Only a failure interrupts —
  with the printer's own message and a Retry. `PrintLabelScreen` survives for
  the **PDF** method only (its preview *is* the deliverable); **System
  printer** now goes straight to the OS print dialog and pops.
- **Printing with no printer paired takes the user to `/printing/` — once**
  (`PrinterSetupPrompt`, device-local since pairing is per device; unpairing
  resets it). Every time after, a "No printer connected" snackbar with a **Set
  up** action, because a print button that keeps yanking the user off their
  page is worse than no printer.
- **Multi-lot works end to end, and Part W is done** (verified 2026-08-19;
  this used to say the backend still owed it). `fishauctions://print/?lots=12,13,14`
  (`lotPksFromPrintLink`) loops the single-lot raster path with one connect and
  a progress count, and the backend now emits it: `LotLabelView.get()` returns
  `label_bluetooth_redirect.html` — a page whose script clicks the deep link and
  then goes `history.back()` — instead of the PDF, gated on
  `is_mobile_app and print_method == 'bluetooth'` in the **view** rather than in
  each template, so every bulk entry point (users table, `?printredirect=`, the
  palette, print-after-bulk-add, a bookmark) routes to the printer. Capped at
  `MAX_DEEP_LINK_LOTS`, with the page telling the user to use "print only
  unprinted labels" for the rest. `labels/printed/` is live too, so natively
  printed labels now clear the website's unprinted lists.
- **A batch link with unreadable prefs prints anyway** (fixed 2026-08-19). The
  old fallback was "not the Bluetooth method ⇒ the page is stale ⇒ reload it",
  which is right when prefs say *some other* method and an infinite loop when
  prefs are simply **null** (an offline or failed `labels/prefs/` fetch): the
  reload re-renders the same handoff page, whose script clicks the same link,
  and the fetch fails again. A batch link only exists because the server decided
  this user prints over Bluetooth, so a null answer defers to the server.
- **PDF / System printer** — the same WeasyPrint PDFs the website makes;
  System routes them into the OS print dialog (`printing` package), both from
  WebView downloads and the `fishauctions://print/<lot_pk>` deep link.
- On the Bluetooth method the shell also intercepts plain navigations to the
  website's own `/lots/print/<pk>/` (`SingleLotLabelView`) and prints them
  natively, so a single-lot label prints natively from *any* entry point — the
  users table, the command palette, a bookmark — not just the one lot-page
  button that emits `fishauctions://print/<pk>`. The *bulk* label URLs can't
  be intercepted this way (the app can't know which lots they'd print), which
  is why Part W puts the lot set in the link. Web label links are otherwise
  widely hidden in the app; un-hiding them is `BACKEND_SPEC.md` Part A.
- **Bluetooth** — server-rendered PNG at the printer's exact raster → 1-bit
  pack (`LabelRaster`) → `PrinterProfileDriver` interprets the printer's
  declarative command program (JSON steps: `tx`/`tx_text`/`tx_raster`/
  `delay_ms`/`await`/`repeat_per_copy`, schema v1). Printers are **Django
  admin rows** served by `printers/profiles/`; adding one needs no app
  release. Bundled seed profiles (`bundled_printer_profiles.dart`: D11s
  AiYin/Lujiang, TSPL, raw ESC/POS) cover cold-start/offline and must stay in
  sync with the backend seed rows.
- **Not every label printer speaks ESC/POS — most 4″ ones don't.** The
  `tspl-raster` profile drives the VEVOR Y486BT and TSC-compatible printers
  generally (verified on hardware 2026-07-26). Two things about TSPL invert
  the usual assumptions: the raster is inlined in an *ASCII* `BITMAP` command
  rather than `GS v 0`, and **a `0` bit prints black**, so the profile sets
  `invert`. Driving one with a D11s profile is what produced "The printer
  didn't confirm the print finished" — the D11s stop opcode means nothing to
  it, so its ack never came. TSPL has no completion ack at all, hence no
  `await` step. The backend seed row is `BACKEND_SPEC.md` Part T.
- **A profile must name its GATT ids whenever it can, because "first writable
  characteristic" is actively wrong on the common serial-bridge modules.** The
  Y486BT is a Feasycom FSC-BT986 running Microchip's transparent UART, whose
  first writable characteristic (`…6daa…`) is the module's *control* channel;
  the data pipe is `…8841…`. Discovery picked the control channel and the
  label silently went nowhere. `BluetoothService._knownDataCharacteristics`
  now tries the documented data pipes (Microchip, Nordic UART, `ff02`, `fff2`)
  before guessing, and the fallback skips the SIG housekeeping services
  (`1800`/`1801`/`180a`/`180f` — `1801` publishes a writable characteristic
  that sorts first).
- **The profile's GATT ids beat the remembered ones on reconnect.** A saved
  printer caches whatever discovery picked at pairing time; preferring that
  cache meant a corrected profile could never reach an already-paired printer
  and the only cure was unpair/re-pair.
- **A dual-mode printer appears twice, and only one entry can work.** Android's
  bonded list includes classic (BR/EDR) pairings — which is what you get
  pairing a label printer in Settings — and this app is BLE-only, so a GATT
  connect to the classic radio times out with the printer sitting right there.
  The BLE side advertises separately, commonly with a `-BLE` suffix and a
  *different* MAC. The connect timeout message says so.
- **A BLE write can't exceed `MTU − 3` bytes, and both platforms reject an
  oversized one rather than splitting it.** An un-negotiated link sits at the
  spec minimum MTU of 23 → 20 usable bytes, so a profile pacing at 200-byte
  chunks failed on its first *raster* chunk while the short setup commands
  sailed through — surfacing as "Lost connection to the printer while
  printing" on a printer sitting right there (fixed 2026-07-25:
  `BluetoothService._negotiateMtu` requests 512 on Android, tolerating a
  refusal, and `_maxWritePayload` clamps every chunk to the *live* `mtuNow` —
  live because iOS settles its MTU after connect returns). The profile's
  `chunk_size` is a pacing hint, never a licence to exceed the link.
- **Raster geometry is `mm × dpi / 25.4`, capped at the printhead**
  (`LabelRasterSpec`), never the printhead width scaled by the label's aspect
  ratio — that older math rendered a 76×51 mm label as 96×64 px (32 effective
  dpi, illegible) on a 12 mm D11s head. `LabelRasterSpec.exceedsHead` reports
  a label size that simply doesn't fit the printer — which no amount of
  resampling can fix — as the print job's warning (there's no preview screen
  left to put it on, and it outranks any driver warning: it explains a label
  the user is holding and can see is cropped).
- The `/printing/` page's Bluetooth card drives the native connect/unpair
  bottom sheet through JS-bridge handlers `printerGetState` /
  `printerConnect` / `printerUnpair` (each resolves with
  `{supported, connected, name, address, profile, labelSize}`).
- **Which profile drives a printer** is resolved in `printer_connect_sheet.dart`
  cheapest-first: advertised BLE name → what the printer reports over GATT
  (Device Information Service; `BluetoothService.identify`, matched by
  `matchProfileForDeviceInfo`) → **what command language it answers in**
  (`PrinterProbe`, matched by `matchProfileForLanguage`) → ask the user. The DIS
  step exists because the BLE name is user-editable and OEM-inconsistent; a
  service UUID alone is only trusted when exactly one profile claims it (`18f0`
  is shared by both D11s profiles).
- **A profile that declares no way to be recognised is never auto-matched**
  (`PrinterProfile.isGenericFallback` — no name/model/manufacturer patterns and
  no service UUID). `escpos-raster` is a manual option whose 384 px head and
  blank GATT ids are placeholders, not facts; without the exclusion it was the
  unique ESC/POS speaker and language matching handed it every printer that
  answers `DLE EOT`.
- **The scan list is ranked, never filtered** (`_sortedDevices`): filtering by
  name or service UUID would hide exactly the unknown printers this flow exists
  to onboard. Recognised printers first, then anything with a name, then bare
  MAC addresses; already-bonded entries say so, since on Android those are
  mostly *classic* pairings a BLE connect can only time out on.
- **The probe is the step that removes the "what kind of printer is this?"
  dialog.** DIS often describes the *radio module*, not the printer (a Y486BT
  says "Feasycom FSC-BT986"), but the print engine will still answer the status
  query of whatever language it speaks. `PrinterProbe` sends the read-only
  status/identity request of TSPL, ESC/POS, ZPL, CPCL and D11s and records what
  answers; a language matching **exactly one** profile is auto-selected
  (`matchByLanguage`). Ambiguity is a real question and still goes to the user.
  Every query must stay read-only — this runs against uncharacterised hardware.
- **Adding a printer is meant to be a data task**, so pairing POSTs everything
  needed to author a profile to `printers/observed/` — DIS strings, service
  UUIDs, the probe replies, and the full GATT tree
  (`BluetoothService.lastGattTree`, which the ids in a profile can only be read
  off). `BACKEND_SPEC.md` Part U covers the fields the backend still needs
  (`probe_replies`, `probed_language`, a `probe` choice for `matched_by`, and a
  declared `command_language`); **DRF silently drops undeclared keys, so all of
  this is currently discarded on arrival** — Part U1 is what turns the
  collection back on.
- **The one thing no query can discover is what a status byte means**, because
  no command makes a printer run out of labels. `PrinterCharacterization` +
  `printer_characterize_sheet.dart` ("Improve support" in the connect sheet)
  walk the user through four physical states — loaded, cover open, roll out,
  closed-and-empty — capturing the status reply in each. Since each state's
  meaning is known up front, the resulting `status_flags.values` map is
  *derived*, not guessed, and ships pre-built in the report along with a
  copyable summary (which is the deliverable even when the endpoint 404s or the
  phone is offline). Working this out for the Y486BT cost an afternoon with the
  hardware; `BACKEND_SPEC.md` Part Y is the backend half, including the admin
  "draft a profile from this observation" action.
- **Command-program schema v2 is implemented and deliberately unused**
  (`PrinterProfile.supportedSchemaVersion`). An app only runs a schema it was
  built with, so the reader has to ship *before* the first row needing it or
  that row costs a release anyway. v2 adds `{total_bytes}` + `{u32le:…}` (ZPL's
  `^GF` carries a raster length no v1 placeholder can express — this is what
  unblocks Zebra), a hex-encoded `tx_raster` (ZPL `^GFA`, CPCL `EG`), and exact
  `status_flags.values` maps. Bare `{…}` placeholders in a `tx` hex template are
  now restricted to genuinely byte-sized values, rejected per-profile rather
  than per-label-size so a small test label can't hide the mistake. Details:
  `BACKEND_SPEC.md` Part X.
- **Label rendering stays image-only on the server.** ZPL was the obvious
  candidate for "let the backend emit the printer bytes"; it isn't, because
  that would move printhead width, invert polarity and MTU chunking behind a
  network call at an auction hall with bad wifi. The schema absorbs the new
  languages instead.
- **"Print test label"** (`PrinterTestLabel`, in the connect sheet) is what
  makes a guessed profile safe: it renders on-device — deliberately, since it
  must work while pairing, possibly offline, before any lot exists — and proves
  the language, the raster geometry, the `invert` polarity and the orientation
  in one 5-second loop. It is currently only reachable from the connect sheet,
  which the `/printing/` card can't open while connected (`BACKEND_SPEC.md`
  Part V).
- **No media-size auto-detection on TSPL.** Probed directly: the Y486BT ignores
  `~!T` and `~!I` entirely while answering `<ESC>!?` on the same link. The
  `label_size_program`/`label_size_parse` plumbing stays for printers that do
  answer (ZPL `~HS`, some CPCL) — filling it in is a Django row edit.

### Lot Scanning (internally "AR")

**Called "Lot scanning" in every user-facing string** (renamed 2026-07-29). "AR"
survives only where users never read it: the `fishauctions://ar/<slug>` deep-link
scheme, `/api/mobile/ar/*`, `?src=ar`, file and identifier names. The web copy
still says "AR" in places — that's `BACKEND_SPEC.md` Part S, a template-only
change needing no app release. The command palette still *matches* the queries
"ar" and "augmented reality" as aliases.

Camera screen (`ar_lots_screen.dart`) that scans lot-label QR codes
(`https://<domain>/qr/<pk>/`) and overlays lot names — with the lot photo in
the chip while ≤2 are in frame, or dots when >3 are (star = watched, green =
recommended; a QR that isn't a lot label gets a grey "invalid" dot). One label
centered/close pops a card (photo + the auction's custom label fields + "open
lot page", which loads `lot_link?src=ar` in the WebView so the page-view
beacon records the scan). Entry: app-only web buttons →
`fishauctions://ar/<auction_slug>` (rules page) and `?locate=<lot_pk>` (lot
page "Locate with AR").

Each chip and the detail card also draw the lot's **other** name under its own
(`ArLotMeta.secondLine`): a lot called "Yellow lab" gets *Labidochromis
caeruleus* under it, one called "Labidochromis caeruleus" gets "Yellow lab", and
the scientific half is italicised. The rule is the backend's — `scientific_name`
and `common_name` on `ar/lots/` are `Lot.scientific_name_line` /
`Lot.common_name_line`, one display rule with two halves, at most one filled —
so the app never has to know whether a blank means hardware, a mixed lot, or an
auction with `use_scientific_name` off. Worth the space in a way almost nothing
else on a chip is: in a hall you can read a lot's name across the room but not
its label, and the species is what a buyer is scanning for.

Interactions are reported to `ar/events/` (de-duped per lot per type per
session): `scanned` when a label is read, `zoomed` when the user aims at one
label up close, `zoomed_full` when the detail card opens. The backend stores
each as a lot `PageView` with source `ar_scan` / `ar_zoom` / `ar_zoom_full`
and breaks them out on the lot page ("In AR: 4 scanned, 2 zoomed in…").

Each sighting also yields an **angle-only** `(bearing, depression)`
measurement (QR corner centroids + gravity against the device-reported camera
FOV — deliberately nothing depends on the printed QR size, since sellers print
arbitrary label sizes; `ar_geometry.dart`, `PlatformBridge.cameraHorizontalFovDeg`)
batched to the backend (`ar_session.dart`/`ar_api.dart`), where a
bearing-dominant solver triangulates everyone's scans into a per-auction 2D
lot map (recency-weighted, outlier-dropping; scale from a phone-height prior)
with an admin map page. Locate mode asks for scans until it can point at the
lot, then switches to a **beacon**: a pin in the camera view (an edge arrow
when the lot is off screen) placed either from a map→screen homography fitted
on the mapped labels currently in frame — scale-free, centimeter-class near a
scanned cluster — or, when too few are visible, from the bearing/distance of
the bearing-only resection (≥3 sighted mapped lots) with an assumed table
height for its on-screen height. Locating **one** lot the user explicitly
asked for is the only thing the map drives.

**Back closes the card before it leaves the screen** (`PopScope`, `canPop:
_cardPk == null`), which covers the app-bar arrow too since that routes through
`Navigator.maybePop`. And **back from a lot page opened out of scanning returns
to scanning**, aimed at that lot — which had been dead code: it keyed on the
`?src=ar` marker in the current URL, and `base_page_view.html` runs a
`history.replaceState` on every page load that strips `src` (and `uid`), so the
marker is gone before the user can press anything. It now keys on the path, and
the screen pops an `ArLotPageRequest` carrying the real **pk** instead of the
shell re-deriving one from the URL — which it could not do: an in-auction lot's
URL is `/auctions/<slug>/lots/<lot_number>/<lot-slug>/`, where the segment after
`lots/` is `lot_number_display` (often `BOB-1`, and a *different* integer from
the pk when it is numeric). The web page's own "Back to scanning" bar renders in
the wrong template block and appears at the bottom of the page — backend,
`BACKEND_SPEC.md` Part AR-1.

**This is the only screen in the app that raises an OS permission dialog
directly** (`_offerLocation`, 700 ms after the camera view paints, and only if
location is undecided — never after a permanent denial). Someone on this screen
is standing in an auction hall, which is where location finally earns the ask:
the fix feeds `CheckinService.ping()` so the server can recognize the arrival and
check them in, and seeds the distance figures the listings show later. Declining
costs nothing — scanning, the overlay, the map and locate mode are all camera
geometry and have never used GPS (`updateLocation`/`ArFrame.latitude` were
removed 2026-07-24).

**Removed 2026-07-25:** bottom **Watched** / **Recommended** checkboxes that
put the same beacon on *any* mapped lot within 6 ft. The map isn't precise
enough for unprompted "you're standing next to this" claims. Nothing it needed
was torn out — `ArSessionController.lotsWithin`, the pose solve, and the
`watched`/`recommended` flags on `ArLotMeta` all remain — so it's a small
re-add if the solver tightens up (see `ar_lots_screen.dart` history). The
in-frame chip markers still show watched (star) and recommended (green): those
key off the label actually being read, not off a solved position. Consequence:
the pose solver now only has positions to work with in locate mode.

```
GET  /api/mobile/ar/lots/?auction=<slug>&lots=<pks>   # overlay/card metadata
POST /api/mobile/ar/observations/                     # measured sightings
POST /api/mobile/ar/events/                           # scan/zoom interactions
GET  /api/mobile/ar/positions/?auction=<slug>         # solved lot positions
```

**Backend status: v1 implemented** on `iragm/fishauctions` (models, scipy
solver in `auctions/ar_mapping.py`, the three endpoints, 60 s beat task). The
app still degrades gracefully on deployments without it: pk-only overlay
chips, observation upload disables itself on 404, locate mode reports lots as
unmapped. Every per-frame sensor channel beyond angle-only detections is now
implemented app + backend: gyro `yaw_deg` heading odometry (so
single-QR-at-a-time sweeps chain across tables), GPS `latitude`/`longitude`
island anchoring, absolute compass `heading_deg` island orientation, and
`odo_x_m`/`odo_y_m` planar dead-reckoning from the device's step counter
(pedometer, `ar_lots_screen.dart`'s `_initPedometer` → `ArSessionController`'s
`recordSteps`/`invalidateOdometry`) — the last one as of 2026-07-21. **Still
open:** island (connected-component) detection/labeling/merging — v1 cannot
relate lots that were never co-visible in a frame, and overlaps unconnected
islands at the origin. The app already parses `component` on positions rows
and refuses cross-island locate fixes/ghost anchors.

### Offline Auction Management

Native mirrors of the web users / bulk-add-lots / set-winners pages
(`offline_users_screen.dart` + add-user/add-lots/set-winners screens) that
keep an **in-person auction running with no connection**, for the operator's
**last admin auction only** (no offline auction creation, no invoice math, no
images). While online, `OfflineSyncService` periodically pulls a compact
snapshot (users + lots) into `OfflineStore` (two JSON files in the app
documents dir); changes made offline queue as idempotent ops (client UUIDs;
offline-created rows are referenced `op:<uuid>` so server renumbering can't
misroute later ops) and push automatically when the connection returns.
Conflicts (lot sold to a different winner on the server, duplicate user,
invoice already closed) are **never silently overwritten — the server copy
wins** and the rejected op surfaces as a notification (shell snackbar + red
banner on the offline screens). Entry points: drawer "Offline mode" tile
(shown once a snapshot exists) and the WebView's page-load-failure banner;
sign-out wipes the offline files.

```
GET  /api/mobile/offline/snapshot/   # last admin auction: users + lots
POST /api/mobile/offline/sync/       # replay queued ops, per-op results + fresh snapshot
```

**Backend status: implemented** on `iragm/fishauctions` (both endpoints live
in `auctions/mobile/`). The app still degrades gracefully on deployments
without them: a 404 disables sync for the process and offline mode reports
"no offline data yet".

### Voice set-winners

Hands-free lot selling on `/auctions/<slug>/lots/set-winners/`: the operator
taps a mic button on the web page and calls out "lot forty two … bidder
seventeen … twenty five dollars … sold". Full design and the v1 post-mortem:
**`VOICE.md`**; the web half is `BACKEND_SPEC.md` Part VOICE.

**Both halves are live** — the page landed (VOICE-4) and the app answers its
bridge.

- **Capability and permission are different questions, and conflating them
  broke this outright** (fixed 2026-08-08). `voiceGetState` runs on *page
  load*, so nothing it touches may prompt. It used to call `speech_to_text`'s
  `initialize()`, which on Android **requests `RECORD_AUDIO`** and then returns
  whether that permission is held — so the microphone dialog appeared the
  instant the page rendered, and `supported: false` came back on every phone
  that hadn't already granted it, hiding the button for good ("Voice is not
  available on this phone"). Capability is now a permission-free native check
  (`PlatformBridge.speechRecognitionAvailable` →
  `SpeechRecognizer.isRecognitionAvailable` / `SFSpeechRecognizer`), optimistic
  on any error because a hidden button on working hardware is the worse
  failure. The microphone is requested in `SpeechBackend.prepare`, reached only
  from `voiceStart` — i.e. the Listen tap. `speech_to_text`'s `initialize()`
  then takes its "already has permission" path and prompts for nothing.
- **No voice bridge handler may throw.** A rejected `callHandler` promise is
  indistinguishable, on the page, from an app build with no voice handlers —
  its catch says "Voice is not available on this phone", which is wrong and
  unactionable. Failures resolve as a state map carrying `error`. Guarding the
  *body* isn't enough: `voiceStart` threw before reaching its `try` and
  answered every tap on Listen with that exact sentence until 2026-08-09 — see
  the JS-bridge argument rule under WebView Integration Notes, which is where
  the general version of this lives.
- **One microphone, one recognizer, arbitrated by `Microphone`.** Two
  `SpeechToText` objects contend for the same platform service rather than
  giving you two (`ERROR_RECOGNIZER_BUSY`, or silence on iOS). Voice
  set-winners and palette dictation overlap on exactly one screen — the palette
  opens *over* the set-winners page — so a claim takes the microphone and stops
  the previous holder. The last thing tapped wins.
- **The app owns only the microphone.** Native because iOS `WKWebView` has no
  Web Speech API and the shell denies the WebView's mic outright. The page
  keeps owning the form — validation, submit, undo, queue auto-advance — and
  the app writes into `#lot`/`#price`/`#winner` over the `voice*` JS bridge
  (`voiceGetState`/`voiceStart`/`voiceStop`, plus pushed events to a page
  receiver `window.fishauctionsVoice.onEvent`).
- **The old Vosk attempt failed for three reasons that weren't Vosk**, and
  they're why the rewrite looks like it does: the model was never deployed
  (only a placeholder is committed; the weights are gitignored), the number
  parser concatenated digits so "twenty five" became `205`, and a `GAIN = 5`
  on float samples clipped the audio. It also cost the page its analytics,
  ads and CDN assets to get SharedArrayBuffer.
- **Values are matched against a closed vocabulary, not parsed out of free
  text.** `AuctionTOS.bidder_number` is a `CharField` and is routinely text,
  which in seller-dash auctions spills into lot numbers (`f"{bidder}-{n}"[:9]`
  → `BOB-1`), so anything assuming digits is wrong for real auctions. Instead
  the auction's actual identifiers are expanded into their spoken forms —
  cardinal, digit-by-digit, letter names, NATO, with/without a spoken "dash" —
  and the utterance is looked up in that index. "Fifteen" vs "fifty" stops
  being a coin flip when only one of them is a real bidder.
- **Confidence is computed, never taken.** `speech_to_text` reports `-1` ("not
  available") constantly — iOS on-device results and Android partials both —
  so the score combines anchor-keyword quality, vocabulary-match quality and
  agreement between the n-best alternates, with the platform's number as one
  flattened input. Three of the four signals are ours.
- **Every value slot needs an anchor keyword** (`lot`/`bidder`/`dollars`), which
  is v1's one good idea kept: a bare number writes nothing, so the auctioneer's
  chant can't corrupt a field. **`sold` is guarded** — it submits only when all
  three fields are filled and confident, otherwise it arrives with `blocked_by`
  populated and the page says what's missing.
- **Only one of the four ways a phrase can end produces a final result, and
  set-winners acts on final results only — so a whole command could be heard
  and silently discarded** (`PlatformSpeechBackend._flushPendingAsFinal`,
  fixed 2026-08-09). `ERROR_NO_MATCH` (what Android answers for a *short* or
  noisy utterance), `ERROR_SPEECH_TIMEOUT`, and the platform simply reporting
  done all leave the words sitting in the last partial; `VoiceCommandService`
  parses finals only, deliberately, because writing every partial into a field
  reads as the app typing nonsense. Worse, a **continuous** session's
  `_endOfUtterance` emits no event at all, so the caller had no way to notice
  and finalize for itself. This is why "lot five" — two words, the most
  no-matchable length there is — never filled anything while longer phrases
  worked. The backend now promotes the last partial when a phrase ends without
  a final, which is what Web Speech's `stop()` does and what
  `DictationService._finalizePending` was already doing one layer up. Not on an
  explicit `stop()`: that never routes through `_endOfUtterance`, because
  switching the microphone off is cancelling, not submitting.
- **A missed anchor loses the whole command, so anchor matching forgives the
  confusions the *speaker* makes** (`boundedEditDistance(…, ignoreVoicing:
  true)` in `VoiceParser._fuzzyAnchor`, added 2026-08-09). The first thing
  reported from real use was "bitter" for "bidder" — which is not an acoustic
  model failing: American English flaps both consonants to the same sound, so
  there is nothing in the audio distinguishing them, and "ladder"/"latter" go
  the same way. At two plain edits it was invisible to a fuzzy pass capped at
  one, and with no anchor the bidder slot never opened and the utterance was
  dropped in silence. Substitutions *within a voicing pair* (t/d, s/z, p/b,
  k/g, f/v) now cost nothing, which buys the homophones without buying every
  two-edit neighbour — "collars" is still not "dollars". Values are matched
  with plain distance, deliberately: a vocabulary exists precisely so "ten"
  and "den" are different answers. A fuzzy anchor still scores 0.6, so the
  field fills and visibly asks rather than being trusted. A **trailing plural**
  is checked first and at any length (`_singular`, 0.8): it's the same word
  rather than a guess about which word, and it's the only way `lot` — three
  characters, so excluded from the fuzzy pass entirely — tolerates anything at
  all, which mattered because it is the most-used anchor in the grammar.
- **The grammar is served data** (`voice` block in `/api/mobile/config/`, over
  `bundled_voice_grammar.dart`), same pattern as `ThermalPrinterProfile`. Which
  words a given auctioneer uses is exactly what we'll be wrong about on day one,
  and v1 had no tuning loop at all.
- **Three settings sit on top of that, device-local, movable mid-auction**
  (`VoiceSettings` + `voiceGetSettings`/`voiceSetSettings`; the page half is
  `BACKEND_SPEC.md` Part VOICE-7): a confidence slider (0.6–0.9 → `confidentAt`),
  "process on this phone" (`preferOnDevice`) and "bias towards lower numbers"
  (`biasLowPrices`). Device-local is the one place the "prefer the backend" rule
  doesn't apply — these describe a phone in a room, its microphone, its language
  pack, its noise floor, and syncing them would fight an operator with two
  handsets. **Every field is nullable and null means "whatever the deployment
  served"**: a device that stamped a copy of today's defaults the first time the
  panel opened would never see a central retune again. `VoiceCommandService.grammar`
  composes served + overrides on *read*, so a change lands on the next utterance
  rather than the next session.
- **Prices *can* be biased separately from bidders and lots, and the APIs are
  the reason it looks impossible.** `contextualStrings` (iOS) and
  `EXTRA_BIASING_STRINGS` (Android) are each one flat array for the whole
  utterance with no slot, category or weight — but both bias **phrases**, and
  `"seventeen dollars"` is a different string from `"lot seventeen"`. Anchoring
  each biased value to its keyword buys per-slot biasing out of an API offering
  none, the same trick as the anchored grammar. `VoiceBiasPhrases` builds the
  list against Apple's ~100-phrase / one-to-two-word guidance, spending the
  budget by expected value: non-numeric bidder ids (`NM`, `BOB` — no general
  recognizer produces these unprompted) first, then low prices, then seller-dash
  lots, then numeric bidders. Plain numeric lot numbers come last and usually
  don't fit, which is right — they're what a recognizer already gets right.
- **`speech_to_text` cannot deliver phrase biasing at all**, which is why the
  app now drives its own recognizer: `SpeechListenOptions` has fixed fields,
  neither native half touches either API, and the only extension point
  (`initialize(options:)`) is per-process and reads exactly one name
  (`noBluetooth`). `BiasedSpeechBackend` + `BiasedSpeechBridge.kt` /
  `BiasedSpeechBridge.swift` own `android.speech.SpeechRecognizer` and
  `SFSpeechRecognizer` directly over `com.fishauctions.app/speech`(`_events`),
  and **`biased` is now the default** (`VoiceGrammar.backend`) — a build or
  device without the native side falls back to `platform` silently in
  `Microphone.backendFor`, and `"backend": "platform"` in the served config is
  the kill switch, a Django row edit rather than a release.
- **The native halves handle exactly one utterance and know nothing about
  sessions.** Re-arming, the two silence windows, the on-device fallback, the
  three-strikes rule and promoting a last partial all live in
  `RestartingSpeechBackend`, which both backends extend — that logic is
  identical on both platforms and has already been wrong three times, so a
  second copy would mean fixing the fourth bug twice. The native sides also
  report `speech_to_text`'s own `error_*` strings, so error classification
  happens in one place for both backends and both platforms.
- **`supportsPhraseBias` is a runtime question on Android.**
  `EXTRA_BIASING_STRINGS` is API 33 and `minSdk` is 28, so a real share of
  phones get the new recognizer without its point (still fine — it recognizes
  speech), and the settings panel is told rather than assuming. iOS has
  `contextualStrings` since iOS 10, well under the deployment target, so it's
  unconditionally true there.
- **Two races the handoff has to get right, both found by construction rather
  than on hardware.** A recognizer asked to stop keeps calling back for a
  moment, so Android tags each utterance and ignores a predecessor's callbacks
  (`BiasedSpeechBridge.Utterance`) — otherwise the old one's `onResults` tears
  down the new one. And Dart's pause timer closes the utterance and waits for
  the *platform's* answer rather than declaring the phrase over itself:
  stopping a recognizer is asking for its final result, and ending the phrase
  first would flush a partial, re-arm, and land the real final inside the next
  utterance. A 1.5 s watchdog covers a recognizer that answers a stop with
  nothing at all, which would otherwise be a lit microphone that has quietly
  stopped listening.
- **Swapping backends stops the current holder first** (`Microphone._swapTo`).
  Voice selects its backend *before* it claims the microphone — it has to,
  since a refused permission mustn't evict palette dictation — so disposing the
  outgoing backend is the moment dictation's event stream would otherwise close
  under it.
- **The low-price tie-break is a separate mechanism that works today.** Biasing
  changes what the recognizer *offers*; the tie-break picks between readings it
  already returned. A price scores `keyword × match` with `match` pinned at 1, so
  "seventeen dollars" and "seventy dollars" tie **exactly** and the winner was
  whichever the platform happened to list first. Prices only, permanently: bidder
  and lot numbers have no such distribution, and quietly preferring the lower of
  two candidate bidders is how the wrong person gets charged.
- **The recognizer is swappable** (`SpeechBackend`). `platform` is the only one
  today; `biased` (phrase biasing over a platform channel), `cloud` and a
  fixed-grammar spotter are the named upgrade paths, selected by config.
- **`speech_to_text` is per-utterance, not a session** — Android ends after
  each phrase, iOS caps a request at ~1 min — so `PlatformSpeechBackend` owns a
  restart loop and treats `error_no_match`/`error_speech_timeout` as the normal
  end of a phrase. Naive continuous listening dies at the first silence.
- **Whether a session outlives one utterance is the backend's call**
  (`SpeechSessionOptions.continuous`), not the caller's, because **most ways a
  phrase can end produce no transcript**: silence, a no-match on a cough, the
  platform just reporting `notListening`. Dictation stopping itself on the
  final result was therefore stopping on the rarest of them, which is why the
  palette's microphone stayed lit until it was tapped a second time (fixed
  2026-08-08). Everything that ends a phrase now goes through
  `_endOfUtterance`, which re-arms or ends according to that one flag.
- **On-device recognition is a request, and a phone can accept it and then be
  unable to do it.** `SpeechRecognizer.isOnDeviceRecognitionAvailable` reports
  the *service*, not a downloaded language pack, so a phone that passes every
  availability check answers the first listen with
  `ERROR_LANGUAGE_UNAVAILABLE`. Voice asks for on-device (an auction hall's
  wifi is bad) and dictation doesn't — which is exactly why set-winners
  reported "no speech recognition available" on a phone whose palette
  microphone worked in the same breath. The first such failure now drops to
  network recognition for the rest of the process, silently; the page's
  "Listening (online)" comes from the `on_device` flag that goes with it.
- **Android's `permanent` flag on an error means nothing** — the plugin writes
  `speechError.put("permanent", true)` on *every* error it forwards, with no
  value behind it — so believing it ended a half-hour auction at the first
  network hiccup. A session now ends on a permission refusal, or after three
  consecutive failures; the ones in between are retried and not reported,
  since a failure the next re-arm fixes two seconds later isn't news and
  putting it on screen resets the button while the microphone is coming back.
- **Both recognizers write money as a symbol, and that alone kept the price
  field empty on every phone** (fixed 2026-08-19). iOS
  `SFTranscription.formattedString` and Android's `RESULTS_RECOGNITION` are
  *formatted* transcripts: "twenty five dollars" comes back as `$25`. The digits
  are an improvement; losing the word is not, because the price slot is a
  **suffix**-anchored one and "dollars" is the anchor. Then `normalizePhrase`
  strips the symbol, leaving a bare number — which the grammar correctly refuses
  to write anywhere. `VoiceParser._spellOutCurrency` reads a currency symbol
  immediately in front of a number as the anchor it stands for, before
  tokenizing, using the *canonical* word of `anchors["price"]` so a renamed
  anchor still works. Everything downstream is untouched: the seam with an open
  lot/bidder slot, cents, `only_whole_dollar_bids`.
- **On iOS `.duckOthers` is illegal on the `.record` category**, and
  `setCategory` rejecting it lands in the same `catch` as everything else —
  reported as `error_audio_error` and ending the session before the audio engine
  has started. It bought nothing either (`.record` already interrupts other
  audio), so it's gone; the error now carries the platform's own text.
- **The event channel is subscribed once per backend and never re-subscribed.**
  `prepare()` runs twice per session (`VoiceCommandService.start` calls it, then
  `RestartingSpeechBackend.start` does), and it used to cancel and re-listen
  each time. Cancelling a broadcast subscription doesn't wait for
  `EventChannel`'s `onCancel`, which both messages the platform *and* clears the
  binary messenger's handler for the channel name — the one the new subscription
  just installed under the same name.
- **A recognizer that says nothing at all is the one failure it cannot report**
  (`BiasedSpeechBackend.platformSilenceTimeout`, 6 s). Both native halves emit a
  `status` the instant they start and a level stream after that, so silence
  longer than that is a broken pipe, not a quiet room — and the UI it produces is
  the worst one available: the page says "Listening", iOS shows its microphone
  indicator, the meter sits at zero, and the operator keeps talking to a dead
  microphone. It now ends the session with a message instead.
- **Every final transcript is logged with what it parsed to**
  (`VoiceCommandService._handleResult`), including the vocabulary size on an
  empty parse. From outside the app "it misheard me" and "it never got a final
  result" look identical — the page shows a transcript either way — and this is
  the only place the difference is visible. `flutter logs` / the Xcode console
  is the first stop for any voice report.
- **No offline fallback for the vocabulary**, deliberately: it never reads
  `OfflineStore`. Offline mode is where a bug means a stuck auction, and it
  stays small.

### Proximity Check-in ("welcome to the auction")

While the shell is up, `CheckinService` POSTs the phone's position (only when
location permission already exists — it never prompts) at mount/resume and
every 10 min; the server decides whether the user just arrived at an
in-person auction and returns display-ready actions the shell surfaces:
join offer (Join without rules-scrolling → lands on rules page),
auto-check-in confirmation, and the admin "set location for this auction from
my phone" offer (auctions with `exact_location_set` false). All copy comes from
the server; unknown action types are ignored.

```
POST /api/mobile/checkin/ping/           # {latitude, longitude} → {actions: [...]}
POST /api/mobile/checkin/join/           # join + auto-checkin → {joined, checked_in, bidder_number, rules_url}
POST /api/mobile/checkin/set-location/   # admin: pin auction location to phone position
```

**The bidder number is the deliverable, and the app used to throw it away**
(fixed 2026-08-19). `checkin/join/` has always returned it; `CheckinJoinResult`
parsed three fields and not that one, so the app said "you're checked in!" and
never said the number — which is the one thing the user needs, because *nothing
a just-arrived bidder can reach shows it*: not the rules page they land on, not
`auction.html`, not the app. (`invoice.html` and the bulk-add-lots pages do, but
those belong to people who have already bought or are selling;
`self_check_in.html` is the door kiosk, on an admin's screen.) It is read as a
**string** — `AuctionTOS.bidder_number` is a `CharField` and is routinely text —
and any message carrying one gets a 12-second snackbar instead of the default
four, because it is something to read off the screen in a noisy room and there
is no way to bring it back.

**A nudge is an OS notification, not a modal** (changed 2026-08-19;
`LocalNotificationService`). These arrive on the *ping loop's* schedule — mount,
resume, every ten minutes — which has nothing to do with what the user is
looking at, and a bottom sheet fired at that moment landed on top of whatever
screen was up, the lot-scanning camera included. A tray notification is the
right shape for news that arrives on someone else's schedule: it waits, it
survives the app being backgrounded, and the user opens it when they choose. It
also fixes the bidder number properly — a notification stays in the shade until
it's swiped, where the 12-second snackbar above expired with nowhere to look the
number up.
- **Nothing about this prompts.** The plugin is initialized with every
  `request*Permission` off, and posting reports `false` rather than asking. The
  app still asks for notifications in exactly the two places `PushPromptService`
  documents, and arriving at an auction is not one of them.
- **So the in-app fallback has to stay**, and for most users it's the live path
  (no notification permission ⇒ nothing would be displayed). It is deferred, not
  dropped: `_deferredCheckin` holds it until the shell is the *visible* route
  (`ModalRoute.isCurrent`), draining on resume and on return from AR, so a join
  prompt still cannot land over the camera.
- **The tap has to work after the app is dead.** Android routinely kills the
  process that posted a notification, so the whole action is carried in the
  payload (`CheckinAction.notificationPayload`, the server's own JSON shape, so
  it comes back out of `tryParse`) rather than held in memory, and the cold-start
  tap is read from `getNotificationAppLaunchDetails` exactly like
  `FirebaseMessaging.getInitialMessage`.

**The admin location pin takes a *precise* fix, and refuses a bad one**
(`LocationService.precisePosition`, added 2026-08-19). Everything else here
reads a position to answer "roughly how far away is this?", where
`LocationAccuracy.medium` and a stale cached fallback are the right trade — but
this coordinate is stored permanently and from then on *is* the 500 ft geofence
every attendee is measured against, so a fix 100 m out (or one taken at the last
place the phone happened to look) is worse than the geocoded street address it
replaces. It asks for the best fix, waits 30 s, takes no cached fallback, and
rejects anything worse than 50 m or older than 2 minutes. This is also the one
place the coarse-location loophole bites: Android "Approximate" and iOS "Precise
Location: off" both leave `hasPermission()` true while returning a
city-block-grade fix, and the accuracy check is the only thing that notices.

**Backend status: implemented** — all three views are live in
`auctions/mobile/urls.py` (this section previously said otherwise; that was
stale). The app still self-disables pings on a 404, so an older deployment costs
nothing. Note that check-in still only ever fires when location permission
*already* exists — the two places that ask for it are the listings banner and
entering lot scanning.

**One backend defect outstanding: the candidate query doesn't filter on
`promote_this_auction`** (`BACKEND_SPEC.md` Part CHECKIN-1). Every auction is
created unpromoted, so an unlisted one currently pushes its full title and a
working Join button to any signed-in app user within two miles during its
window. One line in `evaluate_ping`. Deliberately not filterable app-side — the
app sends a position and renders what comes back; which auction, which band and
which nudge are all the server's call, which is why the copy lives there too.

Two things that *are* right and are easy to doubt: the admin `set_location_offer`
**is** geofenced (the candidate query excludes anything past `ADMIN_RADIUS_MI`,
2 mi), and the whole thing **is** time-boxed — `Auction.in_welcome_window` runs
from 3 h before `date_start` to `date_end` (or `date_start + 12 h` for a plain
in-person event), so an auction weeks away or already finished never nudges
anyone. Note that's tighter than `pretty_much_over`, which is a different
question (24 h after wind-down) used for the palette and stray lots.

### Notification opt-in (when the app asks)

`PushService.init` no longer prompts (changed 2026-07-29). It brings Firebase and
the message listeners up silently and reads the FCM token **only if the OS already
allows notifications** — the second half matters because the backend treats "a
`MobileDevice` row with an `fcm_token`" as "this user can receive push" (it's what
un-disables the preferences checkbox), and a token from a phone that will drop
every notification makes that read wrong.

The dialog is raised from two places, both running the identical opt-in
(`PushPromptService.enable` → OS permission → `devices/register/` → both
`UserData` toggles):

- **`/preferences/`** — matched from the URL in the shell, so it works with no web
  change. Offered on every visit while permission is missing: that page *is* the
  notification settings screen, and its "app instead of email" checkbox is
  server-disabled until this phone has a token, so the app is supplying the
  control the page is missing.
- **A lot page in an in-person auction** — the app can't tell that from a URL and
  doesn't guess. The page calls `pushPromptOffer('lot_selling_soon')` over the JS
  bridge; offered at most once per device. `pushGetState` / `pushEnable` are also
  exposed so a page can render its own control. `BACKEND_SPEC.md` Part N.

Both toggles are written through `notifications/prefs/`
(`notification_prefs_service.dart`, **not implemented yet** — Part N). Until it
lands the OS half still completes and the user is pointed at `/preferences/` to
finish; the app never claims success it didn't get.

### Payments (Square Tap to Pay)

Uses the official **`square_mobile_payments_sdk`** Flutter plugin (the Mobile
Payments SDK — successor to the Reader SDK). Tap to Pay completes the charge
**on-device** via Square; there is no client-side card nonce. The app authorizes
the SDK with OAuth credentials the Django backend already holds.

App-side code: `lib/services/square_payment_service.dart` (SDK wrapper) and
`lib/screens/payment_screen.dart` (checkout UI; mirrors the web "quick checkout"
page but taps instead of scanning a QR).

Credentials are resolved **per invoice** on the backend (the invoice's
`club.effective_square_seller` / auction creator), so they ride along in the
`create` response — the app never stores a Square token.

```
POST /api/mobile/payments/create/
  Body:    { "invoice_pk": 123 }
  Returns: { "invoice_pk", "amount" ("15.00"), "currency",
             "location_id", "access_token",
             "square_environment", "idempotency_key",
             "reference_id" }   ← reference_id: app MUST tap with this exact value
  (Requires the authenticated operator to be an auction/club admin.)
  ← the deployment's PUBLIC Square app id comes from GET /api/mobile/config/
    (`square_application_id`); the app initializes the SDK with it at startup.
    If the create response also carries `square_application_id` it's used only
    as a fallback when the config fetch failed. NOT the secret access_token.

POST /api/mobile/payments/confirm/
  Body:    { "invoice_pk": 123, "payment_id": "<Square payment id>",
             "idempotency_key": "<from create>" }   ← payment_id, NOT source_id
  Returns: { "payment_id", "status", "receipt_number" }
```

The cashier launches the charge by tapping the checkout page's **"Tap to Pay"
button** (the `fishauctions://pay/<pk>` deep link the WebView intercepts). We
deliberately do **not** auto-start on invoice load: a Square charge takes over
the whole screen (its own full-screen Android Activity — mandatory, per Square's
docs), so the cashier opts in with an explicit tap rather than being dropped
into a full-screen prompt the instant the invoice renders. Once the sheet is
open the tap proceeds automatically (create → authorize → charge); the button is
also the retry after a cancel.

**Payment flow:**
1. App initializes the Square SDK with `square_application_id` from
   `GET /api/mobile/config/` (warmed at WebView mount; once per process, via
   the `com.fishauctions.app/platform` channel → `MobilePaymentsSdk.initialize`;
   the Flutter plugin doesn't expose `initialize`)
2. `/payments/create/` → per-invoice amount + seller `access_token` +
   `location_id` + `reference_id`; the app then calls
   `authorize(accessToken, locationId)` (re-auth if the device was authorized
   for a different seller)
3. SDK runs the Tap to Pay prompt **with the backend's `reference_id`** →
   captures the card on-device → completed `Payment` with an id
4. App posts the Square `payment_id` to `/payments/confirm/`
5. Backend verifies via Square's GetPayment API, checks the `reference_id`
   matches what it issued, and marks the invoice PAID. A mismatched (or
   client-invented) reference_id is rejected.

**Why the app id comes from the backend:** so a single app binary can serve any
deployment (a fork's own Square account/env) without baking Square config in —
the same reason the backend URL is moving to runtime config. The
`square_application_id` is the deployment's *public* integrator app id (it ships
in every build by design; the web SDK embeds it in page HTML), distinct from the
secret `access_token`. It is environment-specific (sandbox-sq0idb-… vs
sq0idp-…), so it must agree with `square_environment`. The SDK has no
re-initialize, so the app initializes once per process and refuses a *different*
app id mid-session (switch deployments → restart).

**Backend status:** the `create`/`confirm` endpoints are implemented on
`iragm/fishauctions`, and `GET /api/mobile/config/` serves the deployment's
`square_application_id`/`square_environment`. `confirm` verifies the
on-device `payment_id` via Square's GetPayment — checking status, amount, and
the issued `reference_id` — then records it idempotently and marks the invoice
PAID.

Runtime Tap to Pay still needs: a real NFC device on API 31+ (Android) or an
iPhone XS+ on iOS 16.4+, Square production approval for Tap to Pay, and — on
iOS — Apple's proximity-reader entitlement (code is wired on both platforms;
the iOS checklist is in `IOS.md`). None of that is testable in CI; CI only
verifies the app compiles and links.

**Apple reviews Tap to Pay apps against a published checklist, and it drives
real code.** `TAPTOPAY.md` tracks every item of the *Tap to Pay on iPhone App &
Marketing Requirements and Review Guide* (v1.6) with its status; the backend
half is `BACKEND_SPEC.md` Part TTP. We hold the **development** entitlement
(dev only, 2026-07-31); the **publishing** entitlement — required for
TestFlight *and* the App Store — is granted only after that review. The parts
that shaped the app:

- **Merchant education is Apple's, not ours** (`ProximityReaderDiscovery`,
  iOS 18+, `ios/Runner/TapToPayEducation.swift`). Requirement 4.1 mandates it,
  and using it satisfies 4.4/4.6/4.7/4.8 at a stroke because Apple keeps the
  content current and localized. No entitlement is involved — it presents
  education, unlike `PaymentCardReader` — so it works in dev builds, which is
  what makes it recordable for the entitlement video.
- **Never draw Tap to Pay artwork, and never shorten the name.** The guide bars
  developing custom images/videos/illustrations depicting iPhone or the
  capability; only the Marketing Toolkit's assets qualify. So the awareness
  modal and education fallback are type-only, and the app ships **no icon** on
  its Tap to Pay controls — requirement 5.5 permits only SF Symbols'
  `wave.3.right.circle[.fill]`, and a lookalike (Material's `Icons.contactless`
  very much included) fails it. `tapToPaySymbolAsset` in
  `widgets/tap_to_pay_branding.dart` is the slot for the real export.
- **The reader is warmed at launch and on resume** (`TapToPayService.prepare`,
  requirement 1.5) — which means *authorizing* the SDK, since that's what
  starts the reader preparing. Authorization used to happen per invoice, at the
  instant the cashier pressed the button, which also made 5.6 ("Tap to Pay UI
  within one second, 90% of the time") unreachable. Needs the new
  `payments/authorization/` endpoint; self-disables on 404.
- **Terms-acceptance status is asked of Apple every time** (requirement 1.6
  forbids a local cache — a merchant can unlink their Apple Account from iOS
  Settings at any moment). Don't memoize `isAppleAccountLinked()`.
- **Enablement and education live outside checkout** (3.6, 4.3) — the drawer's
  Tap to Pay entry → `/tap-to-pay` (`screens/tap_to_pay_screen.dart`), shown
  only to merchants the backend calls eligible, since the guide's advice for a
  mixed consumer/merchant app is to limit the feature to the right user type.
  Nearly every user here is a bidder. Making the entry visible to everyone with
  a "nothing to set up here" screen was tried on 2026-08-19 and reverted the
  same day: a drawer row every bidder sees, advertising a merchant capability
  they can't have, is the thing 3.8/4.3 are steering away from.
- **The awareness modal is gated on `canCharge`, not `eligible`, and on an
  auction page** (changed 2026-08-19; it used to fire on whatever page a
  merchant happened to land on, which is how it appeared unannounced). `eligible`
  only means "administers some auction or club", which is true of every organizer
  including the ones with no Square account — and an announcement about taking
  card payments is noise to someone with nothing to take them into. `canCharge`
  is the backend saying it issued live seller credentials, i.e. exactly "Square is
  connected and ready and the only thing missing is this phone". The URL prefix
  was a stand-in for the real question — *is the site showing its own Square
  card here?* — which only the server can answer. **It now does, and the
  stand-in is gone** (2026-08-29): `auction_ribbon.html` calls the
  `tapToPayOffer` bridge handler when `Auction.offers_tap_to_pay` is true
  (the auction's effective Square seller is connected *and* in-person capable),
  and that handler is the modal's **only** caller — `_isAuctionPath` and the
  `onLoadStop` path are deleted. No app-side fallback on purpose: guessing is
  what the guess got wrong, so an older deployment whose ribbon never calls the
  handler simply shows no unprompted modal. `canCharge` is still checked on top,
  because it answers the other half — the ribbon knows the *auction* can take a
  card, `canCharge` knows *this device's* operator was issued live credentials.
  A null there is usually the warm-up fetch racing a cold start onto an auction
  page; it costs one impression, not the feature, since nothing is claimed and
  the ribbon fires on every admin auction page.
- **A declined charge must still be able to send the customer a receipt**
  (5.10, "approved *or* declined"), via SMS/email/QR/Activity view — the share
  sheet is an Activity view, so that's what it uses. This is why the success
  view no longer auto-dismisses after four seconds: a window that closes itself
  isn't a way to offer an action.
- **"Update your iOS" and "this iPhone will never work" are different
  messages** (requirement 1.4). Square collapses both into
  `isDeviceCapable() == false`, so the OS version is read natively and anything
  below iOS 17.6 — the boundary Apple names — is reported as an update.
- **Square OAuth onboarding must not leave the app** (2.2 + the General
  Requirements' "without needing other apps"). It runs in an authentication
  session rather than the system browser: that's the surface Apple counts as
  in-app, and it shares Safari's cookies so a merchant whose Square login is
  Google SSO still works — which it would *not* in the shell's own WebView,
  since Google blocks embedded WebViews. **The website now renders those
  connect links in the app** (TTP-1, landed; this used to be called the
  likeliest rejection). The callback also ends on a page offering a
  `fishauctions://square-connected` link back into the app, which nothing
  receives — the app registers no OS handler for that scheme on purpose, and
  this is the one page emitting such a link that renders in the browsing
  session rather than the shell's WebView, so there is no
  `shouldOverrideUrlLoading` to catch it (`BACKEND_SPEC.md` Part TTP-7 replaces
  the button with "close this window"). The merchant returns by tapping Done,
  and the on-resume warm-up picks up the new credentials. Square is now one of
  five providers sharing one mechanism — see **Connect flows** below.

### Connect flows (Square, PayPal, Mailchimp, Google Calendar, Discord)

`utils/connect_flows.dart` (which URLs) + `services/connect_flow_service.dart`
(how). Reworked 2026-09-02, from the report that **connecting anything signed
the user out**.

- **The authentication session carries Safari's cookie jar, not the shell
  WebView's** — which is exactly why it was chosen, and exactly why our own
  half of the flow could not run in it unaided. Every connect view is
  `LoginRequiredMixin`, so it 302s to `/login/`: a sign-in page inside a
  signed-in app, which is what "it signed me out" turned out to mean. Signing
  in again there doesn't help either, because each flow stashes its OAuth state
  (club slug, CSRF nonce) in the Django session before redirecting, so a
  callback landing in a *different* session dies on "your connection session
  expired" no matter who is signed in to it.
- **So the session is minted, not inherited**: `POST auth/web-session/` →
  open the consume URL with `next=<connect path>?return_to_app=1`. `next` is
  percent-encoded (an unencoded `&` is eaten by the query parser and the server
  falls back to home) and site-relative (off-host is rejected). `return_to_app`
  is nearly redundant now — consuming a handoff marks the session
  app-originated server-side, which is the same switch the Square callback's
  closing page reads — but it costs a query parameter and covers the path where
  the mint failed.
- **Mint immediately before opening, and mint again on every retry.** The token
  is single-use with a 300 s TTL, and the consume view answers a replayed one
  by redirecting to `/login/` — i.e. by reproducing the exact bug. A token is
  never stored, never cached, never retried. The one exception is the
  browser-view fallback inside a single attempt, which reuses the token the
  auth session never consumed (`resolve` / `openResolved`).
- **The launcher is intercepted in the shell, before it navigates**
  (`startsConnectFlowInShell`). `/square/connect/` and friends render nothing —
  they write session state and 302 — so letting one run in the shell is what
  splits the round trip across two sessions in the first place. The Discord
  settings page is deliberately *not* a launcher: it is a real page with forms
  and belongs in the shell, and is listed only so a handoff is minted if
  something opens it outside one.
- **A dismissal is not a failure.** Only Square ends with a
  `fishauctions-oauth://` redirect that closes the sheet by itself. Mailchimp,
  PayPal and Google Calendar *succeed* and leave the user on one of our pages
  with the sheet open; they tap Done, and the platform reports that to us as a
  user cancellation. It cannot be told apart from a real back-out, and both
  mean the same thing — re-read the state from the server (reload, re-warm) and
  say nothing. Never show "connection failed" on a cancel.
- **Not awaited from the navigation callbacks.** `_openExternally` now stays on
  the stack for as long as the user is in the sheet — minutes on a consent
  screen — and WKWebView holds its decision handler open until
  `shouldOverrideUrlLoading` returns.

### What must never be read as a sign-out

The JWT pair and the Django session cookie are independent, and conflating them
is how a hiccup became "signed out". There are exactly three real signals:
a completed **POST** `/logout/`, account deletion, and
`auth/refresh/` answering **401** for a token that was not concurrently
rotated. Everything else leaves the session alone.

- **A GET of `/logout/` is a confirmation page, not a sign-out.** allauth
  renders one there, so intercepting the GET signed people out for merely
  visiting the URL. The POST is caught by `_webLogoutHook` (a `UserScript` that
  hooks the submit) with a native `action.request.method == 'POST'` check as
  the fallback, since Android makes no promise about surfacing a POST
  navigation to `shouldOverrideUrlLoading`. Account deletion is caught at
  `/account/deleted/` instead — it redirects *through* `/logout/` after logging
  the web session out server-side, so the GET interception used to be what
  carried it.
- **Landing on `/login/` is never a sign-out** — it means the cookie session
  lapsed while the native one is fine, so `_reconcileWebSession` re-mints the
  handoff and resumes the intended page. The repair is bounded so a failed
  handoff can't loop, but the counter now resets on any page that renders (and
  on a returning connect flow), because a shell that has been up for hours
  would otherwise sit on the web login form the second time a session lapsed.
- **`auth/refresh/` narrowed to 401 only** (verified against staging: an
  invalid, expired or blacklisted refresh token is 401; a **400** is a missing
  field, i.e. a client bug). 400/403/5xx/timeouts/offline no longer wipe
  anything. **429 never signs out either** — the endpoint is throttled per IP
  and an auction hall is a room full of these phones behind one NAT — it backs
  off with jitter (honouring `Retry-After`, capped) and retries.
- **A 401 for a token that was rotated mid-flight is ignored.** Rotation makes
  a stale rejection possible: a sign-in or an earlier refresh may have replaced
  the pair while the request was in the air, and wiping the fresh one would be
  the bug. The stored token is re-read and compared before anything is cleared.
- Single-flight refresh was already in place and is load-bearing here: an OAuth
  detour easily outlives the 60-minute access token, so the whole app 401s at
  once on return.

## Django Backend Notes (from CLAUDE.md in iragm/fishauctions)

- Stack: Django 5.x, DRF, allauth, Bootstrap 5, HTMX, MariaDB, Redis, Celery, Docker
- Main app: `auctions/` (~5k line models.py, ~8k line views.py)
- Web auth uses allauth/session — completely separate from JWT; do not touch it
- Mobile endpoints live in `auctions/mobile/` (views, serializers, services, urls)
- Backend dev setup requires Docker: `docker compose up -d`, access at `http://127.0.0.1`

## What's NOT Done Yet (gaps from backend audit)

- **Tests:** When adding mobile features, push backend tests alongside the endpoints.
- **PaymentIntent model:** The prompt specified a standalone PaymentIntent model but the backend uses `InvoicePayment` directly. This works — just don't expect a `/payments/<id>/status/` endpoint to exist yet.
- **iOS:** project config (bundle id, iOS 16 target, Info.plist keys) is done; the Mac-only work — first signed build, Google iOS OAuth client, the Square platform channel in AppDelegate, and the Tap to Pay entitlement — is checklisted in `IOS.md`.
- ~~Printing backend endpoints~~ — landed (`printers/profiles/`, `labels/prefs/`, `labels/<pk>/?fmt=pdf`, `UserLabelPrefs.print_method`, the `/printing/` page's dropdown + BT card are live on staging). The app still degrades gracefully when offline: bundled printer profiles, print method defaults to PDF, prefs fetch returns null.
- **Printer onboarding (`BACKEND_SPEC.md` Parts T/U/V/X/Y):** app side is done and verified on a VEVOR Y486BT, and now also ships the schema v2 interpreter and the guided characterization flow. Outstanding backend work, all small and all data: the **`tspl-raster` seed row** (Part T — the app bundles it, so the two are out of sync, and it means the one printer added since the profile mechanism landed was in fact added by app release), `probe_replies`/`probed_language` on `ObservedPrinter` plus a `probe` choice for `matched_by` (Part U — until then DRF drops both), a declared `command_language` on `ThermalPrinterProfile`, a user-facing rename for "Raw ESC/POS raster (GS v 0)", a `/printing/` card button that reaches the native sheet **while connected** (Part V) — without it the only route to "Print test label" is to unpair and re-pair — the v2 validator changes (Part X), and the characterization fields + "draft a profile" admin action (Part Y).
- ~~Multi-lot printing + printed-marking (`BACKEND_SPEC.md` Part W)~~ — **both halves landed** (backend verified 2026-08-19: `LotLabelView.bluetooth_deep_link_response` + `label_bluetooth_redirect.html`, and `MobileLabelsPrintedView` at `labels/printed/`). This entry previously said the backend still owed them; that was stale.
- **Printing from a computer to the phone's printer (`BACKEND_SPEC.md` Part R):** **app side is done** (`RemotePrintService`, 2026-08-19); the backend owes R1–R6. The load-bearing fact is in R0 — **the phone cannot be summoned**: Android blocks starting an Activity from the background, iOS silent push won't reach a force-quit app, and this app's BLE link lives in a UI-scoped provider that a headless isolate doesn't have. So the feature is "the app is open on the phone", measured by a heartbeat and *said out loud on the `/printing/` checkbox*, rather than a push fired into the void. The app now beats every 5 min (mount/resume/periodic) with `print_ready` — which means *paired **and** its profile resolves*, not "the account's print method is Bluetooth" — runs a `print_labels` data push through the ordinary `LabelPrintService.printLots` with its usual progress snackbar and Stop action, and posts throttled progress plus a result carrying the app's own failure text unedited. It reports nothing on the phone at the end: the person who asked is at the computer. The heartbeat's first 404 switches the whole feature off for the process, so until the backend lands, nothing changes anywhere.
- **Push notifications:** app *and* backend *and* the config endpoint are all done and verified on hardware (2026-07-27) — `firebase_messaging` is wired, `PushService.currentToken()` is not a stub, and both deployments' `/api/mobile/config/` serve a complete `firebase` block. **`PUSH.md` and the code are the truth here.** Two remaining blockers, both server-side: `FIREBASE_CREDENTIALS_JSON` set per deployment (unset ⇒ `push_configured()` false ⇒ silent email fallback), and `UserData.push_notifications_instead_of_email` actually toggled on — which is what the new contextual opt-in above exists to do, once `notifications/prefs/` (`BACKEND_SPEC.md` Part N) lands. Testing trap: the **dev flavor can never receive push against staging** (staging's config targets `…app.staging`, so `PushService.init` goes inert by design) and a signed-out app never initializes push at all.
- ~~Terms & privacy links / account deletion (App Store blockers)~~ — **both landed on the backend** (verified 2026-08-01; this entry previously said neither existed, which is stale). `PrivacyPolicyView` serves `/privacy/` (a `BlogPost` seeded by migration, rendered at a stable path rather than redirected — the app opens it inside the signed-out signup WebView against an allow-list, so a redirect would eject the user mid-signup), and `/api/mobile/config/` returns both `terms_url` and `privacy_policy_url`. Account deletion is a web page (`account_delete.html`), which needs no app change — the shell's `/logout/` interception turns the resulting web sign-out into a full native one. The app renders both legal links on the login and signup screens (`widgets/legal_links.dart`).
- **Square Tap to Pay (runtime):** Backend endpoints are done; charging still needs a real NFC device on API 31+ and Square production approval (sandbox works for the full flow). Not exercisable in CI. Android is verified working in production builds; iOS has the **development** entitlement only (2026-07-31).
- **Tap to Pay publishing entitlement / App Review (`TAPTOPAY.md`):** the app side of Apple's checklist is implemented — awareness moment, setup/education screen, Apple's education sheet, reader-progress indicators, receipt sharing, launch/resume warm-up, OS-version-aware messaging. **The backend half is done too** (verified 2026-08-29; this entry used to list TTP-1/2/3 as review blockers, which is stale): the Square connect links render in the app (`SquareOnboardingInAppTests`), the checkout button says `Tap to Pay on iPhone` / `Tap to Pay` with no icon and sits above the QR block (`TapToPayButtonCopyTests`), `GET /api/mobile/payments/authorization/` is live (`PaymentAuthorizationEndpointTests`), `confirm` returns `receipt_url` (TTP-4, and `payment_sheet.dart` already shares it), and the launch email/push command exists (TTP-5). What remains is Apple's: the **publishing** entitlement, granted only after review. **Recording the onboarding video on 2026-09-01 found three faults in Square connect that reading the code had not** — two of them fixed app-side, and the entry that used to sit here called the third "harmless", which it is not.

  - **The browser view carries Safari's cookies, not the app's** — which is exactly why it was chosen (Google blocks SSO in embedded WebViews, so a merchant whose Square login is Google needs Safari's jar), and exactly why *our* half of the flow could not run in it. `/square/connect/` is `LoginRequiredMixin`, so the merchant was bounced to the **web login form** the instant they tapped connect, with the full site navbar, inside what read as a broken handoff. The app now bridges the session the same way the shell bootstraps its own WebView: mint an `auth/web-session/` handoff token and open the browser view at the consume URL with the connect path as `next`. Same-host only; a null handoff falls through to the bare URL, i.e. the old behaviour rather than a new failure.
  - **A plain browser view cannot close itself or tell the app anything**, so the flow ended with the merchant parked on an auction.fish success page whose only exit was a system Done button that nothing mentioned. Seller onboarding now runs in `ASWebAuthenticationSession` (`flutter_web_auth_2`), which presents the same Safari-backed view with the same cookie jar but dismisses itself when the redirect matches `fishauctions-oauth://`. **A separate scheme on purpose**: `fishauctions://` stays unregistered with the OS, and on Android the plugin uses Chrome's Auth Tab, which returns its result to the launching activity rather than through an intent filter — so nothing is registered there either. Safe to ship ahead of the backend: with no redirect to emit yet, the merchant taps Done, the platform reports a cancellation, and that is treated as a normal finish (reload + re-warm) because from the app the two are indistinguishable and both mean "they came back".
  - **`BACKEND_SPEC.md` Part TTP-7 (revised) is what is still owed**: the callback page should redirect to `fishauctions-oauth://square-connected` on the `session_opened_by_app` branch, with "tap Done" copy left visible underneath as the fallback. Until then the auto-close never fires.
- ~~Offline sync backend~~ — landed (`offline/snapshot/` + `offline/sync/` in `auctions/mobile/`).
- **AR lot mode backend v2:** v1 (models, solver, endpoints) landed on the backend, and so has every per-frame sensor channel `BACKEND_SPEC.md` Part 5 specced — gyro `yaw_deg` heading odometry, GPS + absolute-heading island anchoring, and pedometer-driven `odo_x_m`/`odo_y_m` planar dead-reckoning. What's left is island (connected-component) detection/labeling/merging (`component` on positions rows, which the app already consumes). Until it lands, lots that were never co-visible in one camera frame don't get reliable relative positions, and unconnected scanned islands overlap on the admin map.
- ~~Proximity check-in backend~~ — **implemented and live** (verified 2026-08-19; this entry previously said otherwise, and there is no Part 6 in `BACKEND_SPEC.md` any more). All three `checkin/*` views are in `auctions/mobile/urls.py`, with `CheckinNudge`, `Auction.exact_location_set`, `in_welcome_window` and the history writes behind them, and `auctions/test_checkin.py` covers them. The app's 404 self-disable will never fire against this backend. **What is *not* covered is the app half:** `test/services/` has no `checkin_service_test.dart` at all — the ping loop, `minGap`, the `_surfaced` dedupe, join and set-location are untested.
- **Recruit volunteers:** entirely web/backend — `BACKEND_SPEC.md` Part 7. No app work at all (notifications ride the Part 2 push pipeline; the accept flow is a web page).
- ~~Voice set-winners~~ — **both halves are live.** The backend landed the vocabulary endpoint, the `voice` config block, the page (mic button, event receiver, confidence styling) and the tuning telemetry; the app's two launch bugs — a permission dialog on page load, and "not available on this phone" on any phone that hadn't already granted the microphone — were fixed 2026-08-08 (see the Voice section above; the cause was `SpeechToText.initialize()` being used as a capability check). **A third bug wore the same message and outlived both** — `voiceStart` threw `NoSuchMethodError` on `args.firstOrNull` before any of its own code ran, so the page's catch printed "Voice is not available on this phone" on every tap of Listen and the recognizer was never once reached (fixed 2026-08-09; the rule is under WebView Integration Notes). **Nothing past that throw has been exercised on hardware yet** — the first real session is still unproven.
- ~~Command palette in the app~~ — **both halves are live** (2026-08-08). The app-bar title opens the *web* palette when the page has it (`#command-palette-modal`) and falls back to the native one when it doesn't, and `dictateGetState`/`dictateStart`/`dictateStop` expose the phone's recognizer so the palette's mic works — `window.SpeechRecognition` exists in neither of the app's engines. The web side landed the whole of Part PALETTE: the modal renders for app users, `command_palette.js` checks the bridge *before* feature-detecting Web Speech, it shows the dictation error instead of only un-pressing the button, and lot scanning / Tap to Pay are emitted as `fishauctions://` result rows (`auctions/command_palette.py`).
- **Release signing:** wired in CI (keystore from repo secrets; the release workflow refuses to build unsigned). *Local* `flutter build --release` still falls back to debug signing unless you create `android/key.properties` yourself.

## CI/CD

GitHub Actions live in `.github/workflows/` (repo root, above `fishauctions_application/`):
- **ci.yml** — PRs + master/main pushes: pub get, generated-code freshness check, `dart format` check, `flutter analyze`, `flutter test`. No Gradle — deliberately, it costs minutes on every push and the weekly updater is where dependency-driven Gradle breakage actually shows up. The steps themselves live in the composite action `.github/actions/flutter-verify` so `dependencies.yml` can run *the same* checks — it has to run them itself, since a branch pushed with `GITHUB_TOKEN` never triggers `ci.yml`.
- **android-release.yml** — **manual** (`workflow_dispatch`, pick a Play track): runs the CI suite as a gate, restores the upload keystore from secrets (fails fast if `ANDROID_KEYSTORE_BASE64` is missing — a release must be real-signed), builds the signed prod `.aab` **and uploads it to Google Play** on the chosen track (`PLAY_SERVICE_ACCOUNT_JSON`; prerequisites satisfied), plus a signed sideloadable APK artifact.
- **ios-release.yml** — **manual** (`workflow_dispatch`) on a `macos-latest` runner, same CI gate. Default run is an unsigned `flutter build ios --no-codesign` (works today, no secrets — the macOS equivalent of the Android compile gate; it's what verifies `AppDelegate.swift`/plugins actually build on Apple toolchain). The `distribute: true` path (signed `.ipa` → TestFlight via an App Store Connect API key) is scaffolded and fails fast until the signing secrets exist (see `IOS.md`).
- **dependencies.yml** — **weekly** (Mondays 06:23 UTC, plus `workflow_dispatch`), and the reason there is no `dependabot.yml` any more (removed 2026-08-15). Dependabot's problem wasn't the PR count, it was that **nothing it opened had been shown to work together**: each ecosystem moved in its own PR against a CI run that never builds Gradle and never touches Xcode. This updates everything in one pass — pub constraints via `pub upgrade --major-versions`, then AGP/Kotlin/Maven coordinates/the Gradle wrapper/`uses:` pins via `.github/scripts/bump_versions.py`, which *discovers* the pins rather than listing them, so a dependency added later needs no script edit — and then verifies the result with `flutter-verify` **plus a real debug APK build and an unsigned iOS build**. Only then does it open one PR, on one rolling branch.
  - **If the combined update fails, it retries without the breaking changes** rather than giving up, so a week where one package went bad still lands the rest. The PR body says which tier it is and carries the reverted constraint diff — that diff is the whole "which major broke it" answer.
  - **A PR whose checks all passed is opened ready for review; anything else is a draft.** There are no checks on the PR itself to read (a `GITHUB_TOKEN` push starts no workflow run), so draft-vs-ready *is* the signal.
  - **The run itself goes red whenever a verification failed** (the `gate` job, added 2026-08-16), because a scheduled workflow's conclusion is the only thing that mails anybody. The two `Verify` steps are `continue-on-error` by design — tier 2 exists *because* tier 1 may fail — and until the gate landed that made the whole run green no matter what happened; the week AGP 8.13.2 met the Gradle 9.7.0 wrapper, both tiers watched `assembleDevDebug` fail, the fallback reverted everything, nothing was left to commit, **no PR was opened at all**, and the run reported a green check. So the gate runs last (the PR is already open by then) and fails on: tier `safe` (a new major broke the build — mergeable PR, still needs a human), tier `failed`, an iOS build failure, or a failed `gh pr create`. Tier `none` — nothing available to update — stays green, since nothing was built and nothing is being claimed. Red here means *read the run summary*, not "the automation broke".
  - **Hold lists live in the workflow's `env:`** (`PUB_HOLD`/`GRADLE_HOLD`/`ACTIONS_HOLD`), each entry with the reason it can't just be bumped — `flutter_inappwebview`'s deliberate beta pin, `freezed_annotation`'s `dependency_overrides` twin, the native Square SDK that has to match the plugin's. Held packages are still *reported* as available, so a hold can't quietly become permanent.
  - **The pinned Flutter SDK is read from `ci.yml` at run time, never bumped by default.** `workflow_dispatch` with `bump-flutter` turns it on; the verify steps then re-read the pin from the working tree, so the bump is checked against the version it moved to rather than the one the run started with.
  - **The iOS job runs the *release* build, byte for byte the command
    `ios-release.yml` runs.** It gates that workflow, so a difference between
    them is only a way for the gate to be wrong. It was `--debug` for its first
    four runs (never once executed — the job is gated on the Linux tier passing,
    which it hadn't) and that was worse twice over: no one in this project can
    make a debug iOS build at all, Debug is the only configuration that pulls
    `RunnerDebug.entitlements` and its Tap to Pay *development* key, and no AOT
    means gen_snapshot failures sail through.
  - Needs **Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests"** enabled, or `gh pr create` 403s.

**"Building a deployable iOS app requires a selected Development Team" on a
`--no-codesign` build is not about signing, and the real error is not in the
log.** `flutter build ios` passes xcodebuild `-quiet` unless it is verbose, and
on failure prints a *diagnosis* rather than the output. When the `.xcresult`
yields no parsed issues — nothing matched, or `xcresulttool`'s JSON moved under
a newer Xcode — `ios/mac.dart` falls to the `noDevelopmentTeamInstruction`
branch, which sets `issueDetected` and therefore **skips
`_parseIssueInStdout`**, the one thing that would have dumped stdout/stderr. So
a four-minute build fails with a signing lecture, on a job that was never trying
to sign anything, and the compiler error appears nowhere. Both iOS workflows now
carry a `Show the real Xcode error` step that re-runs with `-v` (which drops
`-quiet` and makes `printTrace` visible) on failure; the rebuild is incremental,
so it fails again at the same target in a fraction of the time. Read that step,
never the signing block.

**The first thing that step ever caught was `--no-codesign` colliding with
Square's own setup phase, and the collision had been sitting there since the
phase landed** (2026-07-29 → found 2026-08-16, when the weekly gate executed for
the first time). Hoisting the nested frameworks out of
`SquareMobilePaymentsSDK.framework` is only half of what Square's `setup` does —
it also **re-signs each framework it moves**, and an unsigned build has no
identity to re-sign with, so the phase runs `codesign --force --sign ''` and
exits non-zero (`: no identity found`). Every green iOS run since July had taken
the `distribute: true` path, which archives with `CODE_SIGN_IDENTITY=-` — ad-hoc
is a real identity to `codesign` — so nothing had ever exercised the unsigned
path with the phase in place. The `.xcresult` records it as one `Uncategorized`
error, which is precisely the "no parsed issues" case above: hence the signing
lecture on the job that wasn't signing. `ios/Podfile` now skips the phase when
`CODE_SIGNING_ALLOWED=NO`; the App Store rejection it prevents is only reachable
through the signed path, which still runs it and still verifies the cleanup.
Nothing about this was a dependency problem — the weekly PR was a bystander.

**AGP is held below 9.x, and that is not staleness — it is what keeps the
payments SDK current.** AGP 9.0 removed `targetSdk` from the *library* DSL
(`LibraryBaseFlavor.setTargetSdk` is absent from the 9.0.1/9.2.1/9.3.1 jars and
present in 8.13.2), and `square_mobile_payments_sdk`'s Android module still sets
it, so every AGP 9 build dies while configuring the payments plugin. Square
documents "AGP 8.4.2 or later" and never mentions AGP 9. The alternative was
pinning the plugin back to 2026.7.2, which on iOS would also drag the pod down to
`SquareMobilePaymentsSDK ~> 2.5.0` — Android has an app-side override
(`implementation("com.squareup.sdk:mobile-payments-sdk:2.6.0")`, highest wins),
iOS has nothing, so pinning the plugin means shipping an older payments SDK on
one platform. Holding AGP costs nothing comparable. `GRADLE_CEILING` in
`dependencies.yml` enforces it while still letting 8.13.x patches through, and
the PR body reports the withheld bump every week so the cap can't go stale. Lift
it when Square ships a module without that line.

Two related facts worth keeping: **Flutter 3.44.1 only knows AGP up to 9.1 and
KGP up to 2.3.20** (`maxKnownAndSupportedAgpVersion` /
`maxKnownAndSupportedKgpVersion` in
`flutter_tools/lib/src/android/gradle_utils.dart`), so the AGP 9.3.1 and Kotlin
2.4.10 that unattended bumps had reached were both past what this SDK supports.
**Holding AGP on 8.x also caps the Gradle wrapper at 9.5.x**, and missing that
is what broke every Android build on 2026-08-16. Gradle 9.6 removed
`org.gradle.api.problems.internal.InternalProblems`, an internal API AGP 8.x
calls, so rolling AGP back to 8.13.2 while leaving the wrapper at 9.7.0 meant
`com.android.application` could not be *applied* at all — `Failed to create
service … AndroidProblemReporterProvider`, before any of the app's own code was
looked at. Gradle names the pairing in its own upgrade guide
(`#agp_8x_incompatible`) and says to use 9.5. AGP 8.13 needs Gradle ≥ 8.13, so
the usable window is **8.13 … 9.5.x** and the wrapper sits at its top (9.5.1);
`gradle<9.6` is a second `GRADLE_CEILING` entry so patches keep flowing and the
weekly PR keeps reporting the withheld 9.7.x. Both ceilings lift together — the
day Square's module drops `targetSdk`, and not before.

The app's own bytecode target is Java 17 (`sourceCompatibility`/`targetCompatibility`/Kotlin
`jvmTarget` in `android/app/build.gradle.kts`) — unrelated to the JDK actually
*running* Gradle. `android-release.yml` runs Gradle under **JDK 21**: AGP 9's
bundled lint tool crashes under JDK 17 (`NoSuchMethodError` on
`java.util.List.removeLast()`, a JDK-21-only default method — reproduced
locally against `url_launcher_android`'s `lintVitalAnalyzeRelease` and fixed by
bumping the runner JDK, not by touching the app's Java 17 target). `ci.yml`
doesn't invoke Gradle at all (`flutter analyze`/`test`/build_runner are pure
Dart), so it has no JDK setup step and isn't affected. `minSdk` is **28**
(Square SDK floor).

**No CI job runs R8, so a release-only build failure is invisible until the
manual release workflow.** The single Android build in `flutter-verify` is
`flutter build apk --debug --flavor dev`, and debug doesn't minify — which is
how the Square SDK 2.5.0 → 2.6.0 bump (2026-07-27) sat green for three weeks
and then failed `bundleProdRelease` on 2026-08-16 at
`:app:minifyProdReleaseWithR8`. `mobile-payments-sdk-internals:2.6.0` declares
SQLDelight's **JVM** driver at compile scope beside the Android one
(`app.cash.sqldelight:sqlite-driver` → `org.xerial:sqlite-jdbc`), so a desktop
JDBC library lands on an Android classpath referencing `java.sql.JDBCType`
(Android's `java.sql` has no `JDBCType`) and `org.slf4j` — and **R8 treats a
missing class as an error, not a warning**. The `-dontwarn java.sql.**` /
`org.sqlite.**` / `org.slf4j.**` block in `proguard-rules.pro` is the fix; none
of it is reachable at runtime, since Square drives SQLDelight through
`android-driver`. That jar also ships desktop JNI binaries as *java resources*,
and AGP's defaults drop the `.so` files but not the `.dll`/`.dylib` ones, so
6.2 MB of Windows and macOS libraries were being packaged into every build —
hence `packaging { resources { excludes += "org/sqlite/native/**" } }`. Both go
away if Square fixes the POM.

**Release artifacts are retained for 1 day** (`retention-days: 1` on every
`upload-artifact` in both release workflows). This is a **public** repo, so
anyone can download any run's artifacts — a 30-day `.apk` artifact is a
sideloadable pre-release build left on a public shelf. One day is the shortest
GitHub allows; retention is whole days only, so a sub-day window (12 h) is not
expressible in the workflow. TestFlight and Google Play hold the durable copies.

## Auth Model — Account Required

The app has **no anonymous browsing**. The router (`lib/config/router.dart`)
traps signed-out users on three gate screens until a sign-in succeeds:

- `/login` — native login: the social buttons on top, then the
  username/password form. **Two providers — Apple and Google** — each
  rendering only when `/api/mobile/config/` says the deployment configured it
  (`apple_sign_in_enabled`, `google_server_client_id`); unconfigured ones
  simply aren't offered (no "not configured" error). Both are also on the
  website through allauth, and the app sends **allauth's own provider ids**, so
  native and web sign-ins land on the same `SocialAccount` row with no mapping
  table. Backend contract: `BACKEND_SPEC.md` Part SOCIAL. Google specifics:
  `GOOGLE_SIGNIN.md`.
  - **Facebook was removed on 2026-08-10** — the SDK, the buttons, the plist
    and manifest entries, `facebookAppId`, and `SocialCredential.accessToken`
    (Facebook classic was the only thing that ever set it). It doesn't verify
    the email addresses it hands over, and an unverified address can't identify
    an account, so every Facebook sign-in either fell into the web continuation
    or risked attaching a session to the wrong user. The app now ignores
    `facebook_app_id` even when a deployment still serves it for the website.
    **Its parting shot is worth knowing**: `fb$(FACEBOOK_APP_ID)` in
    `Info.plist` expanded to the literal reserved scheme `fb` when the id was
    empty, and App Store Connect rejected version 2026.8.10 build 11 with
    `ITMS-90155 … disallowed: [fb]`. That rejection arrives **by email after a
    green CI run** — the upload succeeds, the binary is rejected during
    processing, and `ios-release.yml`'s wait-for-processing step then polls a
    state that never comes until its 20-minute App Store Connect JWT expires
    and reports `401 NOT_AUTHORIZED`. **A 401 from that step is not a
    credentials problem**; read the ITMS email first.
  - **Apple leads on iOS, and that ordering is a requirement, not taste.**
    Guideline 4.8 makes Sign in with Apple mandatory once any third-party login
    sets up the primary account, and its HIG expects the button at least as
    prominent as the others. `SocialAuthService.availableProviders` owns the
    order.
  - **Each button is the vendor's own artwork or spec** — Google's unmodified
    PNGs (`assets/google/`), Apple's from `sign_in_with_apple`. Never restyle
    either into a house look, and never draw a substitute mark.
  - **A social sign-in doesn't always finish natively.** Rarer now that
    Facebook is gone — its unverified emails were the common trigger — but
    Google and Apple still land here whenever allauth needs to confirm an
    address or link one that already belongs to another account.
    The backend then returns a `continue_url` + `pending_token`; the
    app runs allauth's own flow in the restricted WebView (`/social-continue`)
    and exchanges the token afterwards. Re-implementing email collection and
    confirmation natively would mean duplicating allauth's rate limiting,
    confirmation-link handling and "that address belongs to someone else"
    rules — where the bugs are account takeovers, not cosmetics.
  - **Apple sends the name and email exactly once**, on the first
    authorization, never again. The app forwards them so the backend can
    persist them; they're hints, never identity (that's the verified token's
    `sub`).
  - **Sign in with Apple is nonce-bound**: the app sends SHA-256(nonce) to
    Apple and the raw value to the backend, which must check them. Without it a
    captured ID token is a working credential.
  - **Every provider is now deployment-configurable**, which wasn't true while
    Facebook was in: its SDKs read the app id from
    `Info.plist`/`AndroidManifest.xml` at launch, so it had to be compiled in
    and a fork needed its own build. Nothing about sign-in is build-time any
    more except the iOS `GIDClientID` and its reversed URL scheme.
- `/signup`, `/password-reset` — the django-allauth web flows hosted in a
  restricted WebView (`AllauthWebScreen`). **Allauth is mounted at the site
  root** (`/signup/`, `/password/reset/`, `/login/`, `/logout/` — not under
  `/accounts/`): navigation is confined to an allow-list of the flow's own
  pages, a link to the web login form returns to the native login screen, and
  anything else opens in the system browser. This keeps reCAPTCHA, email
  verification, and throttling server-side with no native re-implementation.
  A failed load here gets a native "can't reach the server / Try again" panel:
  signup is the one flow with no offline fallback at all (there's no account
  yet, so nothing is cached), and the engine's own error page is a dead end.
- `/legal/terms`, `/legal/privacy` — the deployment's legal documents, in the
  same restricted WebView, and the only routes that work signed-in **and**
  signed-out (`_publicLocations` in the router, not `_gateLocations` — the
  latter also *ejects* signed-in users, which is right for `/login` and wrong
  for a document). Linked from both the login and signup screens by
  `LegalLinks`, because Apple requires terms and a privacy policy to be
  reachable in-app at the point of account creation. Paths come from
  `/api/mobile/config/` (`terms_url`/`privacy_policy_url`); terms falls back to
  the site's `/tos/`, and a deployment with no privacy policy shows no privacy
  link rather than a dead one — an off-host URL is rejected outright, since
  these load *inside* the login trap. The privacy page doesn't exist on the
  backend yet: `BACKEND_SPEC.md` Part L, and a submission blocker.

**Nothing in the app prompts for a permission at launch.** Location is a soft
banner on the listings pages (`LocationService.isLocationAwarePath`) plus a
direct ask on the lot-scanning screen; notifications are offered on
`/preferences/` and on in-person lot pages; camera and Bluetooth are asked for by
the screen that needs them. Every contextual banner waits for the page to sit
still for `_bannerSettleDelay` first and bails if the navigation generation moved
(`_claimBanner`) — a page that settles and *then* redirects used to flash a
prompt for a few frames before `_onLoadStart` hid it, which is worse than no
prompt: the user sees they were asked something and can't answer it. The
"already offered" flag is only set when a banner actually appears, so a stolen
offer gets another chance on the next page.

The native JWT (`authProvider`) is the single source of truth for "signed in".
Session restore falls back to a cached profile when the network is down (tokens
present ⇒ signed in); a definitive refresh-token rejection signs the app out
globally via `ApiService.onSessionInvalidated` → router → `/login`. Sign-out
clears everything: web logout POST, all WebView cookies, JWT pair, cached
profile, Google account picker state, Square authorization.

## WebView Integration Notes

The WebView loads the Django web UI and only mounts for a signed-in session.
JWT auth is bridged into the WebView's Django cookie session:

- On first load, if the WebView has no `sessionid` cookie (fresh sign-in, or
  cookies wiped by sign-out) the shell boots through the
  `/api/mobile/auth/web-session/` handoff so the very first page renders signed
  in; otherwise it loads directly and repairs a lapsed session when the server
  bounces to `/login/` (`_reconcileWebSession`; LOGIN_URL — allauth is
  root-mounted).
- The web login form is never shown in-app — a web-form login would create a
  cookie session with no JWT.
- The WebView intercepts specific URL patterns to trigger native flows (e.g. `fishauctions://print/<lot_pk>` and `fishauctions://print/?lots=…` → native printing, with no screen on the Bluetooth method, `fishauctions://pay/<invoice_pk>` → native Square payment flow); a web `/logout/` navigation triggers the full native sign-out instead of navigating.
- The page the user was last on is remembered (`LastPageService`, secure
  storage, scoped to the account and expired after 24 h) and becomes the
  landing page on the next cold start — Android routinely kills the app while
  it's backgrounded, and coming back to the site root loses the user's place.
  A pending quick action still wins; sign-out clears it.
- Home-screen quick actions (long-press the launcher icon) deep-link into web pages: `ShortcutService` owns the type→path mapping ("Lots in my last auction" → `/lots/my-last-auction/` backend redirect, "Selling" → `/selling/`, "Invoices" → `/invoices/`); the shell consumes the pending path at mount (surviving the login trap via the handoff `?next=`) or navigates in place when already up.
- **Downloads are refetched with the WebView's cookies** (`DownloadService` — these
  are Django *session* endpoints, so a bare client gets the login page) and then
  dispatched by MIME type. A **`.pkpass` goes to Apple's own Add-to-Wallet sheet**
  on iOS (`PKAddPassesViewController` via `PlatformBridge.addPassToWallet` →
  `ios/Runner/WalletPassPresenter.swift`), so the site's existing "Add to Apple
  Wallet" button on a club membership card behaves the way it does in Safari —
  one sheet, one "Add". `open_filex` stays the fallback (all Android has, and the
  right answer if PassKit refuses the bytes); a pass already in the library
  reports back rather than opening a sheet with a dead "Add" button. `.ics` opens
  in the OS calendar importer, everything else goes to the share sheet, and a PDF
  goes to the OS print dialog on the "System printer" method.
- **The navigation drawer is the server's, not a copy of the navbar**
  (2026-09-02). It renders the `menu` block of `GET /api/mobile/config/`
  (`DrawerMenu`, `BACKEND_SPEC.md` Part MENU), because the hand-written mirror
  it replaced could only follow `base.html` through an app-store release — the
  navbar changed in fifteen commits in a year — and was lossy besides: the
  superuser **Admin** menu and **About site** were never in the app at all,
  since who may see them is a server question. Three tiers, resolved by
  `MenuStore`: **server payload > last good payload persisted in the app
  documents dir > a bundled skeleton**. The middle one is why the class exists
  — `ConfigService` caches for the process only, so without a file on disk
  every offline cold start would drop a long-time user back to six links.
  - **The bundled skeleton is not a fallback menu, it is a life raft**
    (`bundledDrawerMenu`, six links). Growing it back into a mirror of the
    navbar recreates the exact problem — a third copy, hand-maintained, that
    rots where nobody looks. If something is missing from the drawer, the
    payload is what should change.
  - **A bad payload can never empty the drawer.** Bad rows are dropped
    individually, a section left with no rows goes with them, and a payload
    that yields nothing renderable is *ignored* — the previous tier keeps
    rendering and the good file on disk is left alone, so a broken deploy
    degrades to yesterday's working menu. Off-host `path`s are refused under
    the same rule as `terms_url` (`sitePathOrNull`), since these load in the
    shell's own WebView.
  - **The four app-owned rows are merged in at anchors, never positioned by
    the server**: Sign out, Offline mode (gated on offline data existing),
    Tap to Pay (platform + backend eligibility) and Clubs (live from
    `myClubsProvider`) attach to the `main`/`account` section ids, and a row
    whose anchor section is absent lands in a trailing section rather than
    disappearing. None of them can be expressed as a URL.
  - **This is the one per-user part of `/api/mobile/config/`** — staff get the
    admin section — which is why `ConfigService.loadForCurrentUser` re-fetches
    when the cached copy was taken by the signed-out login screen, and why
    `AuthService.logout` deletes the persisted menu.
  - **The endpoint reads the bearer token *optionally*, which makes a stale one
    silent and dangerous.** A missing, expired or malformed token is not a 401:
    it is a **200 carrying the signed-out menu**. Nothing errors, so nothing
    retries, and the app would render signed-out chrome around a live session
    for the whole process. Two rules follow, both in `ConfigService`:
    **refresh the access token before asking** (`ensureFreshAccessToken`, which
    reads `exp` out of the JWT and makes no network call when there's time
    left), and record whether the answer can be trusted
    (`configIsForCurrentUser`) so `_warmMenu` **declines to adopt an anonymous
    menu** rather than overwriting — and persisting — a good one. Resume
    re-asks for the menu when the cached config came back anonymous, which is
    the only way out of that state, since by definition nothing failed.
  - Section ids are `main`, `lots`, `account`, `admin`, `about`; `lots` and
    `account` appear only when authenticated, `admin` only for superusers, and
    an unknown id is an ordinary section. **Nothing is hardcoded** — the real
    paths differ from the spec's illustrative ones (`/lots/all/`, `/about/`,
    `/admin-usermap/?view=recent&filter=24`) and the query strings are
    load-bearing, so every row is built from what was sent.
  - Icons are the website's Bootstrap Icons names, mapped by
    `lib/utils/bi_icons.dart` (shared with the command palette). **The map and
    its fallback must stay `const`**: release builds tree-shake the icon font
    and an `IconData` built from a runtime codepoint renders tofu. An unknown
    name falls back to a chevron, so a new navbar icon never needs a release.
- **The command palette is the website's, opened from the app-bar title.** The
  web palette is where the LLM assist lives (streamed NDJSON progress, the
  confirm countdown, clarify options, cancel/report telemetry) — a second
  native copy of a feature that changes weekly would drift within a month — so
  the title tap runs `bootstrap.Modal.getOrCreateInstance('#command-palette-modal')`
  and only falls back to the native `showCommandPalette` when the JS says the
  modal isn't there (older deployment, failed page load, offline). The native
  palette is therefore *not* dead code: it is the offline path, and it goes
  over the JWT API rather than the page. Two rows the server can't express as
  URLs ride custom schemes instead — `fishauctions://ar/<slug>` and
  `fishauctions://tap-to-pay`, emitted by `auctions/command_palette.py` and
  gated on the app's User-Agent (dead links in a browser).
- **A JS bridge handler must declare its parameter as `List<dynamic>`, and may
  never reach a page's argument through an extension method.**
  `addJavaScriptHandler`'s `callback` is typed as a bare `Function`, so an
  inferred lambda parameter is `dynamic` — and a member access on `dynamic` is
  a *dynamic invocation*, which never finds an extension. `firstOrNull` is
  `package:collection`'s extension on `Iterable`, not a `List` member, so
  `callback: (args) => f(args.firstOrNull)` compiled with no import and threw
  `NoSuchMethodError` the first time a page called it. The plugin turns a
  throwing handler into a **rejected** `callHandler` promise, which every page
  here reads as "this app build doesn't have that handler" — so set-winners
  answered a tap on Listen with "Voice is not available on this phone",
  instantly and with no microphone prompt, while `voiceGetState` (which ignores
  its arguments) worked and revealed the button. `pushPromptOffer`/`pushEnable`
  were broken the same way, silently, which is why the contextual notification
  offer never appeared from a lot page. Fixed 2026-08-09 with
  `_WebViewScreenState._firstArg` plus declared parameter types — the
  declaration is the real guard, since it turns the mistake back into a compile
  error.
- **Dictation is a generic bridge, not a palette feature**
  (`dictateGetState`/`dictateStart`/`dictateStop` → `DictationService`, events
  pushed to `window.fishauctionsDictate.onEvent`). Any page can fill a field by
  talking. It exists because the Web Speech API works in **neither** of the
  app's engines — iOS `WKWebView` never shipped it at all, and Android's System
  WebView **defines `webkitSpeechRecognition` without being able to use it**
  (the Blink binding is exposed; WebView never wires it to a recognition
  service, and `_onPermissionRequest` denies the page's mic besides). That
  second case is worse than the first: feature detection finds the object,
  believes it, and never reaches the bridge — the palette's mic button appeared
  and tapping it did nothing, with no prompt and no error, because a failed
  `start()` only un-presses the button. So the shell **deletes
  `SpeechRecognition`/`webkitSpeechRecognition` at document start**
  (`_hideWebSpeechApi`, a `UserScript`), making the environment honest so any
  page's detection reaches the right answer with no app-specific knowledge.
  Fixing only the palette's branch order would leave the next page asking the
  same question the same broken way — the palette has since put the bridge
  check first as well, which is belt and braces, not a substitute.
  Deliberately *not*
  `VoiceCommandService` with the grammar removed: set-winners matches a closed
  vocabulary because a wrong bidder costs money, whereas the palette's whole
  point is that you can say anything and a language model reads it. Dictation
  runs a one-shot session (`continuous: false` — one sentence, then hand it
  back) and does **not** force on-device recognition the way set-winners does:
  Android's `onDevice: true` resolves to `createOnDeviceSpeechRecognizer`,
  which fails with no downloaded language pack, and a palette command is
  already waiting on a network call to the model anyway.
  **It also ends a phrase on a browser-length silence, not an auction one**
  (`DictationService.dictationPause`, 1.5 s, against set-winners' 3 s —
  `SpeechSessionOptions.pauseFor`, per session because the two are waiting on
  different people). The silence window *is* the delay between the user
  finishing and the microphone going off, and on Android it is felt twice over:
  it sets the recognizer's own complete-silence timeout *and* the plugin's
  timer after `onEndOfSpeech`. At 3 s the palette took roughly twice the
  browser's time to notice, which is what "it doesn't turn the mic off the way
  the web does" was (fixed 2026-08-09; the earlier fix that day made it stop
  by itself at all).
  **A browser has *two* silence windows and `speech_to_text` has one, and
  collapsing them is what made dictation stop before the user had finished
  the first word** (fixed 2026-08-09, third round). The plugin runs a single
  pause clock that starts at `listen()` and is pushed forward only by a
  *result* — sound level does not touch it — so 1.5 s was not "1.5 s after you
  stop talking", it was a 1.5 s deadline on getting a transcript back at all,
  with network recognition's round trip inside the budget. Chrome instead
  waits several seconds for speech to *begin* (then `no-speech`) and applies
  its short trailing-silence endpointing only afterwards. So
  `SpeechSessionOptions` now carries `waitForSpeech` (dictation: 8 s) beside
  `pauseFor`, `PlatformSpeechBackend` arms each listen with the long one and
  calls the plugin's `changePauseFor` on an utterance's **first partial** to
  drop to the short one — which is precisely what that API exists for. The
  default `waitForSpeech` equals the default `pauseFor`, i.e. one clock and
  the old behaviour, because a *continuous* session that runs out of patience
  with a silent speaker only re-arms: voice set-winners passes neither value
  and is deliberately untouched.
  **A phrase that ends without a final transcript still gets reported as one**
  (`_finalizePending`): the recognizer can deliver a run of partials and then
  simply stop, and a final is what the page acts on — Web Speech's own `stop()`
  delivers a last result for the same reason, so matching it keeps a page
  written against the browser working unchanged. Not on an explicit
  `dictateStop`, though: a user tapping the microphone off is cancelling, not
  submitting.
- **`mailto:`/`tel:`/`sms:` go to the OS; every other non-http scheme is still
  blocked** (`utils/external_links.dart`, fixed 2026-08-19). Both WebViews
  cancelled every navigation that wasn't `http(s)` — right for `javascript:`,
  `intent:` and `file:`, wrong for the three schemes that aren't navigations at
  all but handoffs a browser has always honoured. Every "Email" button on the
  site did nothing when tapped: the auction and club contacts, "Email all
  users", the speaker panel, allauth's own confirm-address page. The allow-list
  is closed and short on purpose — this shell renders user-authored HTML (lot
  descriptions, reference links), and `intent:`/`market:` can launch arbitrary
  apps with arbitrary extras.
- **App Links / Universal Links are switched off, and as of 2026-08-29 that is
  expressed in the manifest rather than left to fail.** The intent filter in
  `AndroidManifest.xml` (host from the flavor's `appLinkHost` placeholder, so
  dev/staging would claim `staging.auction.fish` and prod `auction.fish`) is
  **commented out**, and iOS never got the `associated-domains` entitlement.
  `FlutterDeepLinkingEnabled` stays on on both platforms: with no filter and no
  entitlement, no URL is ever delivered, so it is inert and one less thing to
  remember later. Deliberately **no OS registration for the `fishauctions://`
  scheme** either: those links only ever appear inside our own pages and are
  intercepted by `shouldOverrideUrlLoading`, so registering it would let any
  app — or any web page in any browser — drive the shell's native flows.
  - **The link arrives as a go_router *exception*, and is handled in `redirect`
    rather than only `onException`.** Both platforms push the absolute URL into
    the app's router, where nothing matches `/lots/123`. But the top-level
    redirect runs on an error match list too, so a signed-out deep link was
    being turned into `/login?from=<absolute url>` and never reaching the
    exception handler — and `_safeFrom` (rightly) refuses a non-relative
    `from`. `DeepLinkService.offer` therefore runs first in `redirect`, parks
    the path, and returns `/`; the shell consumes it the same way it consumes a
    quick action, so a link tapped while signed out survives the login trap.
  - **Left switched off on purpose.** Claiming the domain means a tapped
    `auction.fish` link stops opening in the browser for everyone with the app
    installed, and that's a product decision — forcing people into the app —
    not a technical gap.
  - **"Inert" was not free, which is why the filter is now commented out rather
    than merely unverified** (2026-08-29). The theory was that an
    `autoVerify="true"` filter pointing at a host serving no association file
    just fails verification and costs nothing. Two things say otherwise. **Play
    Console runs its own domain check** on every autoVerify'd web link and
    reports it on the Deep links page — `auction.fish / 1 domain / https /
    com.fishauctions.app.MainActivity / 1 issue found — Failed domain checks` —
    permanently, for a feature nobody is shipping, i.e. a standing red mark that
    trains you to ignore that page. And an **unverified** https `VIEW` filter is
    worse than none in the OS: Android stops handing the link straight to the
    browser and offers a chooser instead. Both go away with the filter.
  - **Turning it on is an ordered procedure, and the iOS order is not
    reversible from the app.** Android: set `ANDROID_APP_LINKS` on the
    deployment (`package=SHA256_FINGERPRINT`, comma separated) — the
    fingerprint is the certificate **Google Play re-signs with** (Play Console →
    Release → Setup → App signing), *not* the upload key, which is the classic
    silent failure — then uncomment the filter, then check with `adb shell pm
    get-app-links com.fishauctions.app`, then **enumerate the paths**: the
    four OAuth callbacks (`/square/onboard/success/`,
    `/paypal/onboard/success/`, `/mailchimp/callback/`,
    `/google-calendar/callback/`) must never reach the app, because waking it
    mid-flow kills the browsing session holding the OAuth state. The backend
    already excludes them from the iOS AASA, but `assetlinks.json` is
    host-level and has no path field, so **all Android path filtering lives in
    the intent filter** — and Android has no "exclude" and
    `pathAdvancedPattern` has no negation, so it has to be a list of the
    prefixes you *do* want, maintained by hand. Reproduce first: Chrome avoids
    launching the app that opened the Custom Tab, so it may not happen at all.
    Today this is all moot — the filter is commented out, so nothing claims the
    host and no callback can reach the app; on iOS there is no
    `associated-domains` entitlement either, so no URL is ever delivered and
    `ASWebAuthenticationSession` does not follow Universal Links into its own
    app regardless. iOS: enable **Associated Domains on the
    App ID first**, then set `IOS_APP_LINKS` (`TEAMID.bundle.id`) so the
    association file serves, and only then add the entitlement key — adding it
    before the capability exists on the App ID means cloud signing can't build a
    matching profile and every Release/TestFlight export fails, the same trap as
    the Tap to Pay entitlement. Both files are already implemented and live on
    the backend (`auctions/app_links.py`); unconfigured is a deliberate 404,
    because an empty-but-valid file verifies as "this site claims no apps" and
    looks identical to a working one.
  - **The Dart half stays whole and tested** (`DeepLinkService`, the router's
    `redirect` hook, `test/services/deep_link_service_test.dart`), so switching
    this on is a manifest edit and an entitlement, not a feature.
  - go_router normalizes away a trailing slash, so `/lots/123/` loads as
    `/lots/123` and Django's `APPEND_SLASH` 301s it back. One extra round trip;
    the fix, if it ever matters, is server-side.
- **Deployment config is re-fetched on resume if it never loaded**
  (`_rewarmConfigIfFailed`). Riverpod caches a `FutureProvider` failure for the
  process, so a cold start with no connectivity — routine at an auction hall —
  otherwise left Square uninitialized and push inert *for the whole session*, and
  the notification offer would have told the user notifications "aren't available
  on this device". The login screen offers the same retry explicitly, since the
  config fetch is what decides whether "Sign in with Google" appears at all.

## Key Decisions

- **WebView-first:** The web UI is the source of truth for all business logic and display. Flutter native code only handles hardware.
- **Backend over native, by default:** If a feature can live in Django and just be surfaced through the WebView/API, put it there. Native/local app state is only for things the web genuinely can't do (hardware access, offline).
- **Account required:** No signed-out mode. Signup/password-reset ride the allauth web flows in a restricted WebView rather than native forms.
- **JWT only for API calls:** The WebView session uses cookies like normal web. JWT is only used for the REST API calls from Dart code.
- **Flavor = environment:** Never hardcode URLs. Always read from `EnvironmentConfig`.
- **Secure storage for tokens:** `flutter_secure_storage` everywhere. No exceptions.
- **Backend repo is read-only reference:** `/home/user/staging/fishauctions` is available locally for browsing the Django backend, but never edit it — spec needed backend changes and hand them to the user.
