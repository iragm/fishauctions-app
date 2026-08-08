# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part PALETTE-2a — the palette mic's branch order (live bug)

The bridge shim landed and is faithful to the spec. **The spec had the two
branches in the wrong order**, and the implementation followed it:

```js
if (assistEnabled && SpeechRecognition && paletteMic) {
  enableMic();                       // ← Android takes this branch, and it cannot work
} else if (assistEnabled && paletteMic && appBridge()) {
  …                                  // ← the bridge, never reached on Android
}
```

**Android's System WebView defines `webkitSpeechRecognition` and cannot use
it.** The Blink binding is exposed, but WebView never wires it to a recognition
service, and the shell denies the page's own microphone request besides — so
`start()` fires an immediate error and nothing else happens. Presence is not
capability.

That is the reported symptom exactly: **the mic button appears and tapping it
does nothing** — no permission prompt, no transcript, and no message, because
the palette's `error` handler only calls `setListening(false)`.

Swap them, so the app's own recognizer wins inside the app whatever the engine
claims:

```js
if (assistEnabled && paletteMic && appBridge()) {
  var dictateState = appBridge().callHandler("dictateGetState");
  …
} else if (assistEnabled && SpeechRecognition && paletteMic) {
  enableMic();
}
```

The app (2026-08-08 build) now also deletes `window.SpeechRecognition` /
`webkitSpeechRecognition` at document start, so the existing feature detection
reaches the right answer without this change. **Both are still wanted**: the
user script fixes every page that asks the question, the branch order is what
makes this page's intent readable and what keeps working if the script is ever
dropped.

## Part PALETTE-2b — show the dictation error

The shim fires `error` with a real message (`state.error`, or an `error` event
carrying `code` + `message` — e.g. "Microphone access is off for this app. Turn
it on in your phone's settings…"), and the palette discards it:

```js
speech.addEventListener("error", function () {
  setListening(false);
});
```

That is why a refused microphone looks identical to a broken button. Put the
message somewhere — the results pane's existing
`renderNote(msg, "danger", "bi-exclamation-triangle-fill")` is right there.
