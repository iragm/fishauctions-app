# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---


## Part PALETTE — the command palette (LLM assist + voice) in the app

**Status: app side landed 2026-08-08. All three items below are web-only —
one template line, one JS block, and two rows of data.**

The palette's natural-language assist is ~600 lines of JS: streamed NDJSON
progress, the confirm countdown, clarify options, follow-ups, and the
cancel/report telemetry the analytics page runs on. None of it can reach a
mobile user today, because `base.html` renders the palette only when
`not request.is_mobile_app`, so the app falls back to its own native palette —
which has plain search and nothing else.

The app now opens the *website's* palette instead (the app-bar title runs
`bootstrap.Modal.getOrCreateInstance('#command-palette-modal').show()`), for
the reason everything else in this app works that way: business logic lives on
the web, and a second native copy of a feature that changes weekly would be
wrong within a month. The app supplies the one thing the web genuinely can't
reach — the microphone.

The native palette (`command_palette_screen.dart`, over
`/api/mobile/command-palette/`) is **not** removed and those endpoints must
stay. It is the fallback when the JS reports the modal isn't there: an older
deployment, a page that failed to load, offline.

### PALETTE-1 — render the palette in the app

`auctions/templates/base.html`, currently line 479:

```diff
-{% if request.user.is_authenticated and not request.is_mobile_app %}{% include 'command_palette.html' %}{% endif %}
+{% if request.user.is_authenticated %}{% include 'command_palette.html' %}{% endif %}
```

This one line is what turns the LLM on for every app user. Nothing else is
needed — the app's title tap already looks for `#command-palette-modal` and
shows the native palette when it isn't found, so the two orders of deployment
both work.

The keyboard-shortcut footer is already `d-none d-md-flex`, so it stays hidden
on a phone.

### PALETTE-2 — drive the microphone through the app bridge

`window.SpeechRecognition` **does not exist in either engine the app uses.**
iOS `WKWebView` has never had the Web Speech API, Android's System WebView
doesn't ship the recognizer Chrome does, and the shell denies the WebView's own
`getUserMedia` microphone request besides. So `command_palette.js`'s mic button
is invisible in the app, and would stay invisible after PALETTE-1.

The app exposes the phone's native recognizer over three JS handlers (live as
of the 2026-08-08 build — `DictationService`, `dictation_service.dart`):

```
window.flutter_inappwebview.callHandler('dictateGetState')
  → {supported: bool, listening: bool, permission: bool, error?: string}

window.flutter_inappwebview.callHandler('dictateStart')
  → the same state map; begins listening

window.flutter_inappwebview.callHandler('dictateStop')
  → the same state map
```

and pushes events into a receiver the page defines:

```js
window.fishauctionsDictate = {
  onEvent: function (event) { /* event may be an object or a JSON string */ }
};
```

| `event.type`  | fields                     | meaning                                  |
|---------------|----------------------------|------------------------------------------|
| `state`       | `listening`                | started / stopped                        |
| `transcript`  | `text`, `partial`          | `partial: false` is the final utterance  |
| `level`       | `level` (0..1)             | microphone level, ~10 Hz                 |
| `error`       | `code`, `message`          | `permission_denied` \| `unavailable` \| … |

Three contract notes, each of which is a bug if ignored:

- **No handler ever rejects.** A rejected `callHandler` promise is
  indistinguishable from an app build with no dictation at all, so failures
  arrive as a resolved state map carrying `error`. Print `error`; don't treat a
  resolution as success.
- **`supported: true` with `permission: false` is the normal first visit.**
  Show the button — tapping it is what raises the OS prompt. (Reporting the
  permission as the capability is exactly the bug that made voice set-winners
  report "not available on this phone"; see Part VOICE.)
- **Dictation ends itself on the final transcript.** A palette command is one
  sentence, and a microphone left open puts the room into the box the user is
  now reading. Expect a `state {listening: false}` right after
  `transcript {partial: false}`.

The smallest change to `command_palette.js` is a shim in the shape the file
already uses, so `buildRecognition()`'s handlers need no edit at all:

```js
// --- Speech to text ---------------------------------------------------------

var SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;

// Neither of the app's WebViews has the Web Speech API, so in the app the phone's own recognizer
// arrives over the shell's JS bridge. Wrapped in the same shape as the browser API so everything
// below this line is unchanged.
function appBridge() {
  var b = window.flutter_inappwebview;
  return (b && b.callHandler) ? b : null;
}

function AppSpeechRecognition() {
  var self = this;
  this._handlers = { result: [], end: [], error: [] };
  window.fishauctionsDictate = {
    onEvent: function (event) {
      if (typeof event === "string") {
        try { event = JSON.parse(event); } catch (err) { return; }
      }
      if (!event || !event.type) { return; }
      if (event.type === "transcript") {
        // Same shape the browser gives us: results[i][0].transcript, results[i].isFinal.
        var alternatives = [{ transcript: event.text || "" }];
        alternatives.isFinal = !event.partial;
        self._fire("result", { resultIndex: 0, results: [alternatives] });
      } else if (event.type === "state" && !event.listening) {
        self._fire("end", {});
      } else if (event.type === "error") {
        self._fire("error", { error: event.code, message: event.message });
      }
    }
  };
}
AppSpeechRecognition.prototype._fire = function (name, event) {
  (this._handlers[name] || []).forEach(function (fn) { fn(event); });
};
AppSpeechRecognition.prototype.addEventListener = function (name, fn) {
  if (this._handlers[name]) { this._handlers[name].push(fn); }
};
AppSpeechRecognition.prototype.start = function () {
  var self = this;
  var bridge = appBridge();
  if (!bridge) { return; }
  bridge.callHandler("dictateStart").then(function (state) {
    // The handler resolves even when it failed; `error` is how it says so.
    if (state && state.error) {
      self._fire("error", { error: "app", message: state.error });
      self._fire("end", {});
    }
  });
};
AppSpeechRecognition.prototype.stop = function () {
  var bridge = appBridge();
  if (bridge) { bridge.callHandler("dictateStop"); }
};

var micAvailable = false;

if (assistEnabled && SpeechRecognition && paletteMic) {
  micAvailable = true;
  recognition = buildRecognition();
  paletteMic.classList.remove("d-none");
  paletteMic.addEventListener("click", onMicClick);
} else if (assistEnabled && paletteMic && appBridge()) {
  // The app's answer is async (it asks the OS whether a recognition service exists), so the button
  // is revealed on the reply rather than synchronously. A build without the handlers resolves
  // nothing useful and the button stays hidden, exactly as it does in a browser without the API.
  appBridge().callHandler("dictateGetState").then(function (state) {
    if (!state || !state.supported) { return; }
    micAvailable = true;
    SpeechRecognition = AppSpeechRecognition;
    recognition = buildRecognition();
    paletteMic.classList.remove("d-none");
    paletteMic.addEventListener("click", onMicClick);
  }).catch(function () {});
}
```

…with the existing click body lifted into a named `onMicClick` so both branches
share it. `buildRecognition()` sets `continuous`, `interimResults` and `lang`
on the object; the shim ignores all three, which is correct — the app decides
those from its own config.

`autoStartListening()` needs no change and stays right: `cp_mic_auto` is only
set by a deliberate click, so a first-time app user is never auto-prompted for
the microphone.

### PALETTE-3 — two native destinations for app users

The native palette injects two rows the server can't express as URLs, and they
disappear when the web palette takes over. Both are already deep links the app
intercepts, so they only need to be *emitted* — as ordinary result items whose
URL is a custom scheme, gated on `request.is_mobile_app`:

| Row              | URL                            | When to show                                                         |
|------------------|--------------------------------|----------------------------------------------------------------------|
| "Lot scanning"   | `fishauctions://ar/<slug>`     | user's last in-person auction, or the query matches `scan`/`ar`/`augmented reality`/`find lot` |
| "Tap to Pay"     | `fishauctions://tap-to-pay`    | user is an auction/club admin who can take payments, or the query matches `tap`/`card`/`payment` |

`fishauctions://tap-to-pay` is new in the 2026-08-08 build; `fishauctions://ar/`
has existed since AR shipped. Anything else with a `fishauctions://` scheme is
ignored by the app rather than navigated to, so an unrecognised one is inert
rather than broken.

Worth having `go_to_page` / the route catalog know about these too, so "take me
to tap to pay" resolves — but the palette rows are the part that matters.

---

## Part VOICE — set-winners voice (fixed app-side 2026-08-08)

Two bugs, both app-side and both now fixed; recorded here because the second one
changes what the page can assume.

1. The app answered `voiceGetState` by calling `speech_to_text`'s
   `initialize()`, which on Android **requests** `RECORD_AUDIO` — so the
   microphone dialog appeared the instant the set-winners page loaded, before
   the user had touched anything.
2. That same call returns *whether the permission is held*, not whether the
   device has a recognizer, so `supported: false` came back on every phone that
   hadn't already granted the microphone — and the page correctly hid its
   button, permanently, with nothing left to tap.

The app now answers `voiceGetState` from a permission-free native capability
check and asks for the microphone only inside `voiceStart`. **No web change is
required**, but two page assumptions are now guaranteed rather than incidental:

- `supported: true, permission: false` is the normal state on a first visit.
  Reveal the button; the tap is what earns the prompt.
- `voiceStart` / `voiceStop` / `voiceGetState` never reject. A failure resolves
  with a state map carrying `error` (and, for a refusal, an `error` *event*
  with `code: "permission_denied"`). The page's current
  `.catch(… 'Voice is not available on this phone')` can therefore only fire on
  a build with no voice handlers at all — which is what it was written for.

Optional polish while you're in `dynamic_set_lot_winner.html`: the click
handler's `.then` already receives `state.error` and prints it, so a denied
microphone now shows the real reason ("Turn it on in your phone's settings…")
instead of the generic catch. Nothing to change; just don't route that path
back through the catch.

---

## Notes on this document

Earlier parts (printing profiles, push pipeline, AR mapping v1, offline sync,
proximity check-in, the last-used-auction lookup) were removed once the backend
implemented them — `git log` on this file has the history. Several `CLAUDE.md`
references to "Part 1 / Part 6 / Part T / Part W" point at that removed content;
the code and `auctions/mobile/urls.py` are the truth.
