# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part VOICE-APP — set lot winners, the app half of iragm/fishauctions#987

The app now sends what the page needs to read phrases precisely, and lets the page use its own
microphone. Everything below is `dynamic_set_lot_winner.html`; nothing is required — current pages
keep working — but without VOICE-APP-1 an Android 13+ phone can lose a phrase.

### VOICE-APP-1: read `final` and `phrase_id` on app transcripts

Every `transcript` event now carries `final` (bool) and `phrase_id` (int). A phrase's partials and
its final share one id; the next phrase gets the next. `partial` is unchanged for older pages, so a
final whose commands the app had already sent still says `partial: true` — but `final: true`.

In `voiceAppTranscript(event)`:

1. If `event.phrase_id` is present and differs from the id of the phrase being held
   (`voicePhrase` non-empty), call `voicePhraseDone()` for the held one **before** taking the new
   text. Today a new phrase's first partial overwrites the old phrase's text, and only the `state`
   re-arm saves it.
2. If `event.final === true`, end the phrase (`voicePhraseDone()`), whatever `partial` says. Only
   when `final` is absent (an older app) fall back to `partial` and the 4 s settle timer.

Why it matters now: on Android 13+ the app asks for a segmented recognizer session, so phrases
arrive back to back with no re-arm between them. The app still sends a `state` with
`listening: true` after each phrase (the page's existing phrase end), so this is belt and braces —
but a final marked `partial: true` otherwise sits 4 s on the settle timer.

### VOICE-APP-2: let the app listen through OpenAI too

`voiceGetState()` now answers `web_microphone: true`: the app will grant this page's own
`getUserMedia({audio: true})` (on this page only, after the OS permission). So in the app,
`voiceCloudStart()` works the same as in a browser.

- When `voiceConfig.cloud` is on (which already folds in `UserData.voice_cloud_enabled`, so only
  accounts it's on for see this) and the state says `web_microphone`, add a **Listen with** choice
  to the voice settings panel: *This phone* (the app's recognizer, free) or *OpenAI* (charged to the
  site per minute). Store it in `localStorage` (per device, like the panel's other values); default
  *This phone*.
- With *OpenAI* chosen, the Listen button runs `voiceCloudStart()` / `voiceCloudStop()` instead of
  `voiceStart` / `voiceStop`, and the `voiceInit` bridge branch must not hide that path — today any
  `flutter_inappwebview` sends the button to the bridge unconditionally.
- If `getUserMedia` is refused in the app, the app has already shown a snackbar pointing at the
  phone's settings; the page's "Allow it for this site" wording doesn't apply there (no site
  permission to allow), so say "Allow the microphone for the app" when the bridge exists.
- The help texts on `VoiceGrammar.cloud_model` ("Off leaves only the app") and
  `UserData.voice_cloud_enabled` ("The app listens without it") should say the flag gates OpenAI in
  the app too; the app's own recognizer is what needs neither.

---

## Part SCAN — faster camera scanning on the lot queue (and check-in / checkout)

All in `auctions/static/js/camera_scanner.js`, `barcode_scanner.js` and `lot_queue.html`. The app
half has shipped: in the app on iOS, `window.BarcodeDetector` now exists and is backed by Apple's
Vision (an Android WebView that lacks one gets ML Kit), so `camera_scanner.js` takes its native
path there with no page change. What remains is page-side, and SCAN-1 is the biggest single win on
every device, browser or app.

### SCAN-1: don't stop the camera for the network

Today a decoded lot QR runs `scanFrame → await handleCode → await onCode →
auctionBarcodeScanner.handleCode → await postLotScan (fetch POST)`, and only then is the next frame
decoded. Then `auction-lot-queued` triggers a full `?partial=list` GET. On venue wifi that is
0.3–3 s per label during which the camera reads nothing, so building a queue goes at the speed of
the network, not of the operator's hand.

- On the lot queue, acknowledge the read the moment it decodes (the existing `"scan"` beep), start
  the POST **without awaiting it**, and return `true` to the scanner at once. Report the POST's
  outcome when it lands (the success/error toast and beep as now).
- Keep a `Set` of lot pks already sent this session (or in flight) and skip them, so the camera
  re-seeing a label doesn't re-post it. Forget a pk when the POST fails, so a retry works.
- Coalesce the list refresh: one `?partial=list` GET at most every ~500 ms however many adds landed,
  or have the add POST return the list partial (the manual form already gets one).
- Check-in/checkout can stay serial — a member scan is one-at-a-time by nature.

### SCAN-2: every code in the frame, not just the first

`startNativeScanner` reads `barcodes[0]` only. With several labels in view the first can be the
same label every frame and the others are never read. Loop over all results.

### SCAN-3: per-value duplicate suppression

`handleCode` remembers one `lastValue`. Labels A and B alternately in frame defeat it (A, B, A —
each is "new"), and the 2.5 s window then blocks the label the operator deliberately re-presents.
Keep a `Map` of value → last time instead; the SCAN-1 set covers the lot queue regardless.

### SCAN-4: a native detector that fails on every frame

Chrome/WebView on a phone without Google Play services constructs a `BarcodeDetector` but rejects
every `detect()` (`NotSupportedError`). The loop logs and retries forever while the preview looks
alive. After a handful of consecutive rejections, stop the native loop and switch to
`startFallbackScanner()` (keep the stream).

### SCAN-5: cheaper ZXing for browsers that still need it (iOS Safari)

The app no longer uses ZXing, but iPhone users of the website still do.

- Let a page narrow `FORMATS` (`createCameraScanner({formats: ["qr_code"]})`); the lot queue only
  ever wants QR, and ZXing's cost grows with every format it tries.
- Decode only what the operator can see. The lot queue's preview is a 3:1 box with
  `object-fit: cover`, so most of each frame is cropped off screen — yet ZXing decodes all of it,
  and reads labels the operator never aimed at. Draw the visible rectangle to a canvas and decode
  that.
- `TRY_HARDER` roughly doubles the per-frame cost; try without it first and only add it on alternate
  frames.

### SCAN-6: a preview you can aim with

The lot queue's camera box is `aspect-ratio: 3 / 1`, at most 480 px wide — on a phone a strip
about 120 px tall, into which a square QR has to fit, so operators hold the phone farther away and
the code shrinks. Use 4:3 (or 1:1) on narrow screens.
