# Voice set-winners — design sketch

Hands-free lot selling on `/auctions/<slug>/lots/set-winners/`. The operator
taps a microphone button on the web page and then just talks:

> "lot forty two … bidder seventeen … twenty five dollars … sold"

**Status.** Live on both halves. The app supplies the speech pipeline, the
parser, the vocabulary matcher, the confidence model and the three `voice*`
bridge handlers; the backend landed the vocabulary endpoint, the `voice` config
block, the page's microphone button and receiver, and the tuning telemetry.

Two launch bugs, both app-side, both fixed 2026-08-08, and both worth
remembering because they came from the same mistake — treating the microphone
*permission* as the device's *capability*:

- **The permission dialog appeared on page load.** `voiceGetState` runs when the
  set-winners page renders, and it called `speech_to_text`'s `initialize()`,
  which on Android requests `RECORD_AUDIO` as a side effect. The user was asked
  for a microphone before they had shown the slightest interest in one.
- **"Voice is not available on this phone", on phones that were.** That same
  `initialize()` returns whether the permission is held — not whether a
  recognizer exists — so the honest first-visit answer (`false`, nobody has
  granted anything yet) was reported as `supported: false`, and the page did
  the right thing with the wrong fact: it hid the button, permanently.

The fix is the split now baked into `SpeechBackend`: `isCapable()` is
permission-free and prompt-free (a native `SpeechRecognizer.isRecognitionAvailable`
/ `SFSpeechRecognizer` check, optimistic on error — hiding the button on
working hardware is the worse failure), and `prepare()` is the *only* thing
that asks for the microphone, reached only from `voiceStart`, i.e. from the tap
on Listen. See §3.3.

---

## 1. Why v1 didn't work

The Vosklet/Vosk attempt is in `dynamic_set_lot_winner.html` (backend repo,
lines ~190–525) and is currently commented out at the button. It's worth being
precise about why it failed, because only one of the four causes is "Vosk was
the wrong engine" — and a straight engine swap would have fixed the *least*
important one.

1. **The model isn't deployed.** `auctions/static/models/vosk/vosk-model-small-en-us-0.15/`
   contains a 147-byte `README` saying "This is a placeholder… download the real
   model", an empty `index.html`, and nothing else. The real files are in
   `.gitignore` (lines 38–47) and only arrive if someone runs
   `download_vendor_resources.sh` on that host. On a deployment where nobody
   did, `createModel()` is loading 404s.

2. **The number parser is broken independent of the audio.**
   `parseSpokenNumber()` *concatenates* digit strings:

   ```js
   'twenty' → '20',  'five' → '5'   ⇒  "twenty five" → "205"
   "one hundred five"               ⇒  "1001005"
   ```

   Only single-word numbers and the accidental "one fifty" → `150` case ever
   produced the right answer. A perfect recognizer would still have typed `205`
   into the price box for a $25 lot.

3. **The audio frontend clips.** `GAIN = 5` is applied to Float32 samples in
   `[-1, 1]` before `acceptWaveform`, with no limiter. Anything above 0.2
   amplitude — i.e. most of a room with an auctioneer in it — is squared off
   into distortion. Clipping is the single most destructive thing you can do to
   an acoustic model.

4. **`vosk-model-small-en-us-0.15` is a 40 MB generic dictation model** — the
   smallest tier — running in WASM, in a noisy hall, doing open-vocabulary
   transcription for what is actually a six-word command language.

And it cost the page a lot: SharedArrayBuffer forced cross-origin isolation, so
`dynamic_set_lot_winner.html` overrides `analytics`, `ads`, `core_css` and
`core_js` to self-host jQuery/Bootstrap/icons, and `CrossOriginIsolationMiddleware`
exists solely to set COOP/COEP on this one path. All of that is deletable.

**Lesson carried into v2:** the listening model was right (keyword-anchored slot
filling — `lot`/`bidder`/`dollars`/`sold`). The recognizer, the parser, and the
absence of any tuning loop were wrong.

---

## 2. Shape of v2

```
  web page (Django template)          app (Flutter)                 platform
  ─────────────────────────────       ───────────────────────       ────────────
  mic button  ──callHandler──►  voiceStart(auction slug)
  transcript line                     VoiceCommandService
  per-field confidence UI               ├─ SpeechBackend  ◄──────► SFSpeechRecognizer
  fills #lot/#price/#winner              │   (swappable)            android.speech
  submits via existing AJAX              ├─ VoiceGrammar (served JSON + bundled default)
        ▲                                └─ VoiceVocabulary (this auction's real
        └──window.fishauctionsVoice◄─────    lot numbers + bidder numbers)
             .onEvent({...})
```

Three rules decide where everything lives:

- **The app owns the microphone.** iOS `WKWebView` has no Web Speech API and the
  shell denies the WebView's mic permission outright
  (`webview_screen.dart:1729`). Native speech recognition is hardware the web
  can't reach — the same test that justifies Bluetooth printing and the camera.
- **The web page owns the form.** Validation, submit, undo, the queue
  auto-advance and every error message already work and are server-iterable. The
  app never POSTs a winner; it writes into `#lot`/`#price`/`#winner` and clicks
  the page's own buttons.
- **The grammar is data, not code.** Keywords, synonyms, number words,
  confidence weights and thresholds are served JSON with a bundled default —
  exactly the `ThermalPrinterProfile` / `bundled_printer_profiles.dart` pattern.
  Tuning a misheard word must take a Django admin edit, not an app release. v1
  had no tuning loop at all, and that is the failure most likely to repeat.

---

## 3. App architecture

### 3.1 `SpeechBackend` — the swappable part

```dart
// lib/services/speech/speech_backend.dart
abstract class SpeechBackend {
  String get id;                       // 'platform' | 'cloud' | …
  Future<bool> available();
  Future<void> start(SpeechSessionOptions options);
  Future<void> stop();
  Stream<SpeechEvent> get events;      // partial | finalResult | level | error | state
}

class SpeechHypothesis {
  final String text;
  final double confidence;             // -1 when the platform doesn't report one
}

class SpeechEvent {
  final SpeechEventType type;
  final List<SpeechHypothesis> alternates;   // n-best, best first
  final double? level;                       // 0..1, for the mic meter
  final String? errorCode;
}

class SpeechSessionOptions {
  final String localeId;
  final bool preferOnDevice;
  final List<String> biasPhrases;      // lot/bidder numbers; used by backends that can
}
```

Backends, in the order they'd be reached for:

| id | implementation | when |
|---|---|---|
| `platform` | `speech_to_text` ^7.4.0 → `SFSpeechRecognizer` / `android.speech.SpeechRecognizer` | **v1 default.** Free, offline-capable, no keys, both platforms. |
| `biased` | **the default.** Our own channel: `SFSpeechRecognitionRequest.contextualStrings` / `EXTRA_BIASING_STRINGS`, over recognizers this app owns. `speech_to_text` exposes neither, and phrase biasing is the one lever it can't pull. Falls back to `platform` where the native side isn't there. |
| `cloud` | Deepgram / Google STT streaming with keyword boost | best accuracy in noise; needs network *and* a short-lived token minted by Django — never a baked key. |
| `spotter` | Picovoice Rhino (intent+slot, fixed grammar, offline) | the tool actually built for this problem. Commercial licence, so it's the escape hatch, not the default. |

Which backend runs is a served config field (`voice.backend`), so a deployment
can move without an app release once more than one exists.

**`speech_to_text` specifics that shape the code:**

- It targets "commands and short phrases, not continuous conversion". Android's
  `SpeechRecognizer` ends the session after each utterance and iOS caps a
  request at ~1 minute. `VoiceCommandService` therefore owns a **restart loop**:
  treat `error_no_match` / `error_speech_timeout` as normal end-of-utterance,
  restart with ≥300 ms spacing (Android throws `ERROR_RECOGNIZER_BUSY` on a
  tight loop), and back off exponentially on genuine errors.
- `SpeechRecognitionResult.alternates` is a `List<SpeechRecognitionWords>`, each
  with its own `confidence`. **Use all of them** (§4.3) — v1 looked only at the
  single best string.
- `confidence` is `-1` ("not available") far more often than people expect —
  routinely so for iOS on-device results and Android partials. A design that
  keys the UI off the platform's confidence number alone will show "unsure" for
  everything or nothing. Hence §4.4.
- `SpeechListenOptions(onDevice: true, partialResults: true, listenMode: dictation,
  pauseFor: …, cancelOnError: false)`. Prefer on-device: an auction hall's wifi
  is bad, the round trip is the latency the operator feels, and Apple throttles
  server-side recognition per app per hour.
- **But `onDevice: true` is a request that a phone can accept and then fail.**
  `SpeechRecognizer.isOnDeviceRecognitionAvailable()` reports whether the
  *service* exists, not whether the language pack is downloaded, so a phone
  that passes every availability check answers the first listen with
  `ERROR_LANGUAGE_UNAVAILABLE` — reported to the user as "no speech
  recognition available", on a phone whose microphone demonstrably works. The
  first such failure drops to network recognition for the rest of the process
  (`PlatformSpeechBackend._onDeviceUnavailable`) and the page says "Listening
  (online)". Palette dictation never asked for on-device, which is why it was
  the half that worked. The retry also has to shift `pauseFor` by a
  millisecond: the plugin rebuilds its Android recognizer `Intent` only when
  the language tag, partials flag, listen mode or pause changes — **not** when
  `onDevice` does — so the fallback would otherwise inherit
  `EXTRA_PREFER_OFFLINE` and fail identically.
- **`pauseFor` belongs to the caller, not the backend.** It is the whole of the
  delay between the speaker stopping and the microphone switching off, and on
  Android it is spent twice — it sets the recognizer's own complete-silence
  timeout *and* the plugin's timer after `onEndOfSpeech`. Three seconds is
  right for an auctioneer, who pauses mid-chant and must not be cut off, and
  wrong for palette dictation, where the user has finished a sentence and is
  watching a lit microphone: there it read as the app failing to notice they
  had stopped, at roughly twice a browser's wait. Hence
  `SpeechSessionOptions.pauseFor`, 3 s for set-winners and
  `DictationService.dictationPause` (1.5 s) for dictation.
- **`SpeechRecognitionError.permanent` is a lie on Android.** The plugin writes
  `speechError.put("permanent", true)` on every error it forwards. A session
  ends on a permission refusal or three consecutive failures — never on that
  flag.
- **No gain stage.** The platform recognizers run the same AGC/noise-suppression
  pipeline as the keyboard dictation mic. Feeding them raw is correct; v1's
  ×5 was actively harmful.

### 3.2 Files

```
lib/models/voice_command.dart           # slot, confidence model + weights
lib/models/voice_grammar.dart           # served config, merged over the bundle
lib/models/voice_vocabulary.dart        # this auction's values + spoken-form index
lib/services/voice_spoken_forms.dart    # number/letter words, form generation
lib/services/voice_parser.dart          # the walk, matching, confidence
lib/services/speech_backend.dart        # the swappable interface
lib/services/platform_speech_backend.dart
lib/services/bundled_voice_grammar.dart # cold-start default
lib/services/voice_vocabulary_service.dart
lib/services/voice_command_service.dart # session, dedupe, sold-guard, bridge state
```

`voice_command_service.dart` is the only stateful piece: it holds the session,
the last value and confidence per slot, and the dedupe window. The grammar
rides in `AppConfig.voice` (a raw map — it's tuning data, not app config) and
is applied by the shell's `_warmVoice()` alongside the Square and push warm-ups.

### 3.3 Bridge handlers

Registered in `_onWebViewCreated` next to `printer*` / `push*`:

```
voiceGetState()            → {supported, listening, permission, backend, on_device}
voiceStart({auction, locale}) → {listening, error}
voiceStop()                → {listening: false}
```

Two invariants hold across all three, and both were bugs before they were
invariants:

- **`voiceGetState` prompts for nothing and starts nothing.** The page calls it
  on load. `supported` answers "does this phone have a recognizer" and
  `permission` answers "has it been granted" — separately, because
  `{supported: true, permission: false}` is the *normal* first visit and must
  still reveal the button. The tap is what earns the prompt.
- **None of them ever throws.** A rejected `callHandler` promise is
  indistinguishable, on the page, from an app build that has no voice handlers
  at all — its catch prints "Voice is not available on this phone". Anything
  that goes wrong resolves as a state map carrying `error` instead, so the page
  can print what actually happened.

  **Wrapping the handler's body is not enough, and assuming it was cost this
  feature a month.** `voiceStart` is the one handler that takes an argument,
  and it read it with `args.firstOrNull` — an extension method on a parameter
  that infers as `dynamic`, because `addJavaScriptHandler`'s `callback` is
  typed as a bare `Function`. Dynamic invocations never find extensions, so
  every tap on Listen threw `NoSuchMethodError` *before* entering the `try`,
  the promise rejected, and the page printed exactly the sentence this
  invariant exists to prevent — with no permission prompt, because nothing in
  the app ran. `voiceGetState` ignores its arguments, so it worked, revealed
  the button, and made the feature look like it was one tap from working.
  Declare bridge parameters as `List<dynamic>`; a mistake is then a compile
  error (fixed 2026-08-09, `_WebViewScreenState._firstArg`).

The microphone is claimed through `Microphone` (`services/microphone.dart`),
which also owns the one shared recognizer: the command palette dictates through
the same platform service, and the palette opens *over* this page. Starting
either one stops the other rather than both failing with
`ERROR_RECOGNIZER_BUSY`.

App → page is a push, not a poll — `evaluateJavascript` calling a receiver the
page installs:

```js
window.fishauctionsVoice = { onEvent: function (e) { … } };
```

```jsonc
// state       – listening started/stopped, permission result
{"type": "state",   "listening": true, "on_device": true}
// level       – mic meter, ~10 Hz, 0..1
{"type": "level",   "level": 0.34}
// transcript  – live text for the status line; partial:true is not actionable
{"type": "transcript", "text": "bidder seventeen", "partial": true}
// command     – the only actionable event
{"type": "command", "slot": "bidder", "value": "17", "confidence": 0.93,
 "heard": "bidder seventeen", "candidates": ["17", "70"],
 "blocked_by": []}
// error
{"type": "error", "code": "permission_denied", "message": "…"}
```

`slot` ∈ `lot` · `bidder` · `price` · `sold` · `unsold` · `undo` · `clear` ·
`confirm`. Unknown slots must be ignored by the page, so the app can add one
without a template change (and vice versa).

### 3.4 Platform plumbing

- **Android** — `RECORD_AUDIO` in the manifest, plus the API 30+ package
  visibility block, without which `SpeechRecognizer` silently finds no service:
  ```xml
  <queries><intent><action android:name="android.speech.RecognitionService"/></intent></queries>
  ```
  The Bluetooth permissions `speech_to_text` wants for SCO headset routing are
  already declared for label printing.
- **iOS** — `NSMicrophoneUsageDescription` **and** `NSSpeechRecognitionUsageDescription`
  (two separate prompts; missing the second crashes on first use).
- **Permission timing** — the ask fires on the mic button tap and nowhere else.
  That keeps the standing rule that nothing prompts at launch, and it's the
  textbook contextual ask: the user pressed a microphone.
- **Screen wake** — the operator won't touch the phone for minutes at a time.
  Hold a wakelock while listening (`wakelock_plus`), release on stop.
- **`_onPermissionRequest` is unchanged**: the page still must not get the
  WebView mic. Audio is native now; the page never calls `getUserMedia`.

---

## 4. Accuracy

This is the part that has to be different, not the engine.

### 4.1 A command language, not dictation

Every slot needs an anchor keyword. A bare number writes nothing, so the
auctioneer's chant, the crowd, and half a conversation can't corrupt a field.

```
lot <number>                     → #lot
bidder <number>                  → #winner
<number> dollars                 → #price
sold                             → submit (action=save)
no sale | unsold | pass          → submit (action=end_unsold)
undo | scratch that              → the existing undo link
clear | cancel                   → wipe the three fields
```

Synonyms per anchor (`item`, `buyer`, `number`, `bucks`, `hammer`, …) live in
the served grammar, because which words a given auctioneer actually uses is
exactly the thing we'll be wrong about on day one.

**A missed anchor loses the whole utterance**, which makes anchor matching the
highest-leverage place to be forgiving — the opposite of value matching, where
a wrong guess costs money. Beyond the served synonyms, `_fuzzyAnchor` takes a
word one edit away (`bidders`, `dollar`) at quality 0.6, and counts a
voiced/voiceless substitution as **no edit at all**. That last part came from
the first real session: "bitter" for "bidder". It isn't a recognizer error to
be tuned away — American English flaps both consonants to the same sound, so
nothing in the audio distinguishes them, and the same goes for
"ladder"/"latter" — but at two plain edits it was invisible here and the bidder
slot silently never opened. Free substitution within a voicing pair (t/d, s/z,
p/b, k/g, f/v) buys the homophones without buying every two-edit neighbour:
"collars" is still not "dollars".

A **trailing plural** is taken at any length and scored 0.8, ahead of both.
That exception exists for one anchor in particular: `lot` is three characters,
so the length guard skipped it entirely and the grammar's most-used word had to
be transcribed exactly or the utterance was lost. A plural is the same word
rather than a guess about which word, and "lots" cannot be confused with "got"
or "not" the way a general 1-edit rule at three characters would be. "We have
lots of nice fish" is still safe, because the tokens after the anchor have to
resolve to a real identifier and they don't.

### 4.1a What a missed anchor actually costs

Worth stating plainly, because it drove three of the fixes above: the anchor is
all-or-nothing. Miss it and the slot never opens, `_resolveValue` is never
called, no command is emitted, and the operator gets **no feedback at all**
beyond the transcript line — the app looks like it isn't listening. That
asymmetry is why anchor matching should keep getting more forgiving (a wrong
anchor still has to find a real identifier before anything is written) while
value matching should not (a wrong identifier is a wrong bidder, and that
costs money).

### 4.2 Match a closed vocabulary — the biggest single win

**Lot and bidder identifiers are not numbers.** `AuctionTOS.bidder_number` is a
`CharField(max_length=20)` and is routinely set to text; in seller-dash auctions
that text spills into lot numbers, which `Lot.save()` builds as
`f"{bidder_number}-{n}"[:9]` — so `BOB-1`, `BOB-2`, `3-1` are all normal. Any
design that assumes digits is wrong for a chunk of real auctions.

What is true is that the set of *legal answers is closed and small*: a few
hundred lot numbers and a few dozen bidder numbers, in this auction. So invert
the v1 approach — instead of transcribing freely and then repairing the text,
**generate the spoken forms of the values we know exist and match the utterance
against them.**

```
GET /api/mobile/auctions/<slug>/voice/vocabulary/   (ETag'd, refreshed on a timer
                                                     and after every save)
{ "lot_numbers": ["1", "12", "BOB-1", "3-1"],
  "bidder_numbers": ["4", "17", "BOB"],
  "only_whole_dollar_bids": true,
  "use_seller_dash_lot_numbering": false,
  "currency_symbol": "$" }
```

Every entry is expanded at fetch time into the ways a person says it:

| value | spoken forms indexed |
|---|---|
| `42` | "forty two", "four two", "42" |
| `105` | "one hundred five", "one oh five", "one zero five", "105" |
| `BOB` | "bob", "b o b", "bravo oscar bravo" |
| `BOB-1` | "bob one", "bob dash one", "bob one" |
| `3-1` | "three one", "three dash one" |

Matching is then: normalize the utterance after the anchor keyword, look it up
in the index, and fall back to fuzzy comparison (edit distance over the
normalized form) when there's no exact hit. This dissolves the classic ASR
confusions for free — "fifteen" and "fifty" are a coin flip acoustically, but if
only bidder 50 exists there is no ambiguity, and if both exist we know to *ask*.
The recognizer doesn't have to be good; it has to be good enough to shortlist.

It also handles text without any extra machinery: "bob" is only a plausible
bidder because the vocabulary says so, and "bidder bee oh bee" spells it.

Match outcomes:

| outcome | score | behaviour |
|---|---|---|
| exact hit in the spoken-form index | 1.00 | fill |
| unique fuzzy hit (edit distance 1, or a homophone-table sibling) | 0.75 | fill, marked unsure |
| ≥2 plausible members | 0.40 | fill best, marked unsure, `candidates` sent so the page can offer a pick-list |
| no member, but the utterance parses as a number | 0.35 | fill, marked unsure — a bidder may genuinely be seconds old |
| no member, doesn't parse | — | no command; transcript only |

Confidence at a neutral platform rating, for the same rows: 0.89 / 0.72 / 0.58 /
0.55. The scores in `VocabularyScore` are *chosen* so each outcome lands in the
tier it's described as landing in — worth re-checking if the weights move. Only
an exact hit on a value this auction really has is ever filled silently, and a
weak match compounded with a weak (fuzzy) anchor keyword falls below 0.5 and
isn't written at all: the two doubts multiply, which is right.

The homophone confusions this is meant to dissolve — 13/30, 14/40, 15/50, 16/60,
17/70, 18/80, 19/90, two–to–too, four–for, eight–ate, one–won, oh–zero — are
handled at the *word* level in `kCardinalWords`/`kDigitWords` rather than as a
value-level table, so "bidder to" and "bidder two" reach the same index key.

**Refresh matters:** bidders are added at the check-in desk *while* selling
runs, so a vocabulary fetched once at page load is stale within minutes. Refresh
on a timer and after every save.

**No offline fallback.** The vocabulary is fetched or voice doesn't arm — it is
deliberately *not* wired to `OfflineStore`. Offline mode is the one part of this
app where a bug means a stuck auction with no way to recover, and it stays as
small as it is. Voice needs a live vocabulary to be trustworthy anyway; without
one, every match would score 0.35 and everything would be amber.

### 4.2a Getting the words out of the recognizer at all

The accuracy work above is wasted if the transcript never arrives, and for a
while it frequently didn't. Set-winners acts on **final** results only — a
half-recognized number written into a field and then corrected reads as the app
typing nonsense — but only one of the four ways a phrase can end produces a
final. `ERROR_NO_MATCH`, `ERROR_SPEECH_TIMEOUT` and a bare "done" from the
platform all leave the words in the last partial, and in a *continuous* session
`PlatformSpeechBackend._endOfUtterance` emitted nothing, so there was no signal
to act on either. Short utterances are the most likely to end that way, which
is why "lot five" never filled anything while whole sentences did.

`_flushPendingAsFinal` promotes the last partial when a phrase ends without a
final. Web Speech's `stop()` does the same, and it belongs in the backend
rather than in each caller — every future `SpeechBackend` has the same problem.
An explicit `stop()` is excluded: that path doesn't go through
`_endOfUtterance`, and someone switching the microphone off is cancelling.

### 4.3 Parse every alternate, not just the best

Run all n-best hypotheses through the grammar and score each. The winner is the
hypothesis that both matches the grammar *and* matches the vocabulary cleanly —
which is often not the top-1 string. Where the alternates disagree about a slot,
that disagreement is the honest confidence signal.

Building the spoken-form index needs a real cardinal parser (and its inverse),
not v1's concatenation: accumulate units/teens/tens, `hundred` multiplies,
`thousand` flushes. Both readings are indexed, because people use both, often in
the same session:

- cardinal — "forty two" → `42`
- digit string — "four two" → `42`, "one oh five" → `105`

Recognizers also frequently hand back digits directly ("bidder 42"), so the
literal form is indexed too. Letters cover single-letter names ("bee" → `B`) and
the NATO alphabet, since `BOB` is as likely to be spelled as said.

Prices: `<n> dollars`, `<n> dollars and <m> cents`, and the "twenty five fifty"
half-dollar idiom — but only when the auction allows it. `only_whole_dollar_bids`
forces integers and deletes an entire error class; the server enforces it anyway
(`validate_price`).

### 4.4 Confidence is computed, not taken

Because the platform's number is `-1` so often, derive it from four inputs and
weight them from the served grammar:

| input | meaning |
|---|---|
| `asr` | platform confidence when available, else a neutral 0.8 prior |
| `keyword` | 1.0 exact anchor · 0.8 known synonym · 0.6 fuzzy (edit distance 1: "butter" → "bidder") |
| `snap` | the §4.2 table |
| `agreement` | fraction of the top-3 alternates that parse this slot identically |

```
confidence = asr^0.5 · keyword · snap · (0.6 + 0.4 · agreement)
```

Weights and the two thresholds are grammar fields. The important property is
that a platform which never reports confidence still produces a *meaningful*
confidence, because three of the four inputs are ours.

### 4.5 Session rules

- **Only final results write.** Partials drive the transcript line and nothing
  else — no half-parsed numbers landing in fields.
- **Dedupe:** same slot + same value inside 2 s is ignored (the restart loop can
  redeliver an utterance).
- **`sold` is guarded.** An auctioneer says "sold" constantly. It submits only
  when all three fields are filled, all three are confident, and at least one
  changed since the last save. Otherwise it emits with
  `blocked_by: ["bidder"]` and the page says what's missing. The server is the
  real backstop — it already refuses a second sale of the same lot.
- After a save, slot state resets; the page's existing `next_queued_lot_number`
  auto-advance is untouched.

### 4.6 Operational

A phone in a pocket 20 ft from the podium will not hear the auctioneer, and no
amount of the above fixes that. A Bluetooth headset or a clip-on mic is the
difference between working and not working, and should be in the on-screen help
the first time voice is enabled.

### 4.7 Reading the transcript with a language model — costed

Asked after the first real session, where the recurring miss was "bitter" for
"bidder" (§4.1). The palette already has an LLM seam (`auctions/llm.py`,
`gpt-5-nano` by default, `reasoning_effort: minimal`) so this would be a new
`/api/mobile/voice/interpret/` over the existing plumbing, not new
infrastructure.

**Token shape per call.** System prompt with the slot contract, the "a value
needs its keyword" rule and a few examples ≈ 500. The auction's vocabulary is
the bulk: ≈ 2 tokens per numeric identifier, ≈ 4–5 for a seller-dash one
(`BOB-1`), so 400 lots + 100 bidders ≈ 1,000 and a large seller-dash auction
≈ 4,000. Three n-best alternates plus framing ≈ 70. Output is small JSON
(≈ 40) plus reasoning tokens, ≈ 200 billed all told.

At $0.05/M input, $0.005/M cached input, $0.40/M output:

| | warm cache | cold |
|---|---|---|
| 400 lots, numeric | $0.000091 | $0.00016 |
| 800 lots, seller-dash | $0.00011 | $0.00031 |

**Two things dominate, and neither is the vocabulary.**

*Output tokens are ~85% of a warm call.* Prompt size barely matters once the
prefix is cached, so there is no reason to trim the vocabulary and every reason
to keep the reasoning budget minimal.

*The cache is fragile in exactly the way this feature is built.* The vocabulary
endpoint returns **unsold** lots and bidders added at the check-in desk, so a
prompt regenerated per call has a different prefix every time and pays the
10× uncached rate on all of it. Pin a per-session snapshot, refresh on a timer,
and keep the utterance last.

**Call volume is the number that decides this, not the per-call price.** A
continuous recognizer fires on everything it hears — the chant, the crowd, side
conversations — and today that is free because a non-matching phrase is parsed
locally and dropped. Route every phrase to the model and all of it is billable:
a 300-lot sale is maybe 900 command phrases and a couple of thousand ambient
ones, so ~2,400 calls ≈ **$0.22 warm / $0.38 cold**; a long seller-dash auction
at 6,000 calls ≈ **$1.90**. Gate it on the local parser having failed (nothing
matched, or below `unsureAt`) and it falls to a few hundred calls ≈ **2–3¢**.

**So cost is not the objection. These are:**

1. **Latency, in the one place §3.1 says we can't afford it.** Set-winners
   forces on-device recognition because an auction hall's wifi is bad and the
   operator feels every round trip. This adds phone → Django → OpenAI → back,
   ~1.5–3 s, and a gated design puts that delay precisely on the utterances the
   operator is already repeating.
2. **The local parser stays regardless** — offline, timeout and 404 all fall
   back to it — so this is an addition, and the homophone handling has to exist
   locally anyway.
3. **A new error class.** A model will return a confident bidder number that
   isn't what was said. The answer has to be validated against the vocabulary,
   which is what `VoiceVocabulary` already does — leaving the model's real job
   as "normalize the transcript", which is a large hammer.
4. **It costs an app release and an endpoint**, where the grammar is already
   served data a Django row edit can change.

**The cheaper version of the same idea, and the recommendation:** use the model
*offline*. Log the misses, batch them nightly, have it propose anchor synonyms,
and push those into the `voice` config block. A handful of calls a day, nothing
in the operator's path, and it feeds the tuning loop §7 step 5 already plans
for. The blocker is that `VoiceCommandLog` is written **only when a command is
accepted**, so an utterance that matched nothing — the entire "bitter" case —
leaves no trace at all. That is VOICE-6 (§6), and it is worth doing whichever
way this goes.

---

## 5. Confidence UX

Three tiers, per field:

- **Confident** (≥ 0.85) — field filled, the page's existing `is-valid` green.
  Short rising tone.
- **Unsure** (0.5 – 0.85) — filled, but amber dashed border, and the heard text
  under the field: *heard "bidder fifty" → 50?* with a **Confirm** tap, plus a
  pick-list when `candidates` has more than one. Lower two-tone cue.
  **`sold` will not auto-submit while any field is unsure** — it prompts instead.
- **Rejected** (< 0.5) — nothing is written; the transcript line shows
  *heard: "…"* so the operator knows they were heard but not understood.

Two things v1 had no answer for and that matter more than they look:

- **A mic level meter.** v1 gave zero evidence audio was flowing, so a dead mic
  and a bad model were indistinguishable.
- **Audible cues.** The operator is looking at the lot and the crowd, not the
  screen. Distinct accept/unsure tones carry the state without a glance.

**Phase 2: spoken readback.** Before an auto-save, say "lot 42, bidder 17,
twenty five dollars" and require "sold" or "yes". This is the real safety net for
a hands-and-eyes-busy operator, and it's what makes auto-submit trustworthy.
Needs `flutter_tts` and a duck of the recognizer while speaking.

### 5.1 Settings the operator can move mid-auction

`VoiceSettings` (device-local) over `voiceGetSettings` / `voiceSetSettings`,
rendered as a panel on the set-winners page (`BACKEND_SPEC.md` Part VOICE-7).
Three controls, chosen because each is a judgement we cannot make from here:

| control | what it moves | why it's a knob, not a constant |
|---|---|---|
| confidence slider (0.6–0.9) | `confidentAt` | An operator watching the screen wants it low and will catch mistakes; one calling lots with their hands full wants it high and would rather retype. |
| process on this phone | `preferOnDevice` | On-device survives bad wifi and is faster; network recognition is more accurate. The trade is per-room. |
| bias towards lower numbers | `biasLowPrices` | A claim about *this* domain's price distribution, not about speech. |

**Every field is nullable and null means "whatever the deployment served".** The
grammar is served data precisely so it can be retuned centrally, and a device
that stamped a copy of today's defaults the first time the panel was opened
would never see a central improvement again. Only a control the operator
actually moved is stored, and `VoiceCommandService.grammar` composes the two on
*read* — so a change lands on the next utterance rather than the next session,
which is the difference between tuning while selling and stopping to tune.

Not server-held, which is the one place this project's "prefer the backend" rule
doesn't apply: these describe a phone in a room — its microphone, its language
pack, its noise floor — and syncing them would actively fight an operator with
two handsets.

### 5.2 Phrase biasing, and how prices get biased separately

The recurring question is whether sell prices can be biased apart from bidder
and lot numbers. **The APIs say no and the answer is still yes.**

`SFSpeechRecognitionRequest.contextualStrings` and Android's
`RecognizerIntent.EXTRA_BIASING_STRINGS` are both one flat array of strings for
the whole utterance. Neither has a slot, a category or a weight, and the
recognizer has no idea whether a number it is about to emit will land in the
price field or the lot field.

But both bias **phrases, not words** — and `"seventeen dollars"` is a different
string from `"lot seventeen"`. Anchoring each biased value to the keyword that
introduces it buys per-slot biasing out of an API that offers none. It is the
same trick as the anchored grammar itself, for the same reason.

The constraint that shapes `VoiceBiasPhrases` is the budget: Apple recommends
around **100 phrases of one or two words**, and longer lists and longer phrases
are both *less* effective, not more. A 400-lot auction has far more identifiers
than that, so selection is by expected value — non-numeric bidder identifiers
first (`NM`, `BOB`: a general recognizer has no chance at these unprompted, and
there are few), then the low-price phrases, then seller-dash lots, then numeric
bidders. Plain numeric lot numbers come last and usually don't fit, which is
correct: they're what a recognizer already gets right, and four hundred of them
would push out the handful of strings that needed help.

**`speech_to_text` cannot deliver any of this**, which is why the app now drives
its own recognizer. `SpeechListenOptions` has fixed fields, its native halves
never touch either API, and its only extension point (`initialize(options:)`) is
per-process and reads exactly one name. So `BiasedSpeechBackend` owns
`android.speech.SpeechRecognizer` and `SFSpeechRecognizer` directly, over
`com.fishauctions.app/speech` and its event channel, and `biased` is the default
`VoiceGrammar.backend`. A build or device without the native side falls back to
`platform` silently (`Microphone.backendFor`), and `"backend": "platform"` in the
served config is the kill switch — a Django row edit, not a release.

**The native halves are deliberately tiny: one utterance, no session.**
Re-arming, the two silence windows, the on-device fallback, the three-strikes
rule and promoting a last partial live in `RestartingSpeechBackend`, which both
backends extend. That logic is identical on both platforms and has already been
wrong three times; a second copy means fixing the fourth bug twice. The native
sides also report `speech_to_text`'s own `error_*` strings, so "these codes are
really just a speaker who stopped" is written once.

`supportsPhraseBias` is a *runtime* question on Android — `EXTRA_BIASING_STRINGS`
is API 33 against a minSdk of 28, so a real share of phones get the new
recognizer without its point (fine; it still recognizes speech) and the settings
panel is told rather than assuming. iOS has had `contextualStrings` since iOS 10.

Two races the handoff has to get right, neither of which needs hardware to see:
a recognizer asked to stop keeps calling back for a moment, so Android tags each
utterance and ignores a predecessor's callbacks — otherwise the old one's
`onResults` tears down the new one. And Dart's pause timer closes the utterance
and waits for the *platform's* answer instead of declaring the phrase over
itself: stopping a recognizer is asking for its final result, so ending the
phrase first would flush a partial, re-arm, and land the real final inside the
next utterance. A 1.5 s watchdog covers a recognizer that answers a stop with
nothing, which would otherwise be a lit microphone that has quietly stopped
listening.

**The low-price tie-break is separate and works today.** Biasing changes what
the recognizer *offers*; the tie-break chooses between readings it already
returned. A price scores `keyword × match` with `match` pinned at 1, so
"seventeen dollars" and "seventy dollars" tie *exactly* and the winner was
whichever the platform happened to list first. Prices only — bidder and lot
numbers have no such distribution, and quietly preferring the lower of two
candidate bidders is how the wrong person gets charged.

---

## 6. Backend work

Spec'd in `BACKEND_SPEC.md` **Part VOICE**. Summary:

**Delete** — `Vosklet.js`, `static/models/vosk/`, `VOICE_RECOGNITION_SETUP.md`,
`download_vendor_resources.sh`'s voice section, `CrossOriginIsolationMiddleware`
(and its `settings.py` entry — nothing else on the site uses SharedArrayBuffer),
the `analytics`/`ads`/`core_css`/`core_js` overrides in
`dynamic_set_lot_winner.html`, and all of `startVoiceRecognition` /
`startWebSpeechRecognition` / `parseSpokenNumber` / `handleVoiceResult`. The page
gets its ads, its analytics and its CDN assets back.

**Add** — an app-only mic button and status area on the set-winners page, the
`window.fishauctionsVoice.onEvent` receiver, the confidence styling, and
`GET /api/mobile/auctions/<slug>/voice/vocabulary/`. Grammar config rides in
`/api/mobile/config/` under `voice`.

The button renders hidden and is revealed only after `voiceGetState()` resolves
`{supported: true}` — `{% if request.is_mobile_app %}` alone would show a dead
button to anyone on an app build that ships no `voice*` handlers.

**Done**, along with the rest of the page. Note that `supported` no longer
implies the microphone has been granted (it never should have): a first visit
answers `{supported: true, permission: false}` and the button must appear
anyway.

**VOICE-6 — log the misses, not only the hits.** `VoiceCommandLog` is written
when a command is *accepted*, which means the utterances that produced nothing
are invisible: "bitter" for "bidder" opened no slot, emitted no command, and so
never reached the table whose whole purpose is answering "what are we getting
wrong most often". The app should emit an event for a transcript that matched
no anchor, or matched one below `unsureAt`, and the page should log it with the
same `{heard, confidence}` shape and a null `chosen`. It is the cheapest
accuracy work available: every row is a candidate anchor synonym for the served
grammar, which is a Django row edit and needs no app release. It is also what
makes the language-model option in §4.7 practical in its offline form.

---

## 7. Phasing

1. ~~**Pipe**~~ — `speech_to_text`, `SpeechBackend`, `PlatformSpeechBackend`,
   the restart loop, the three bridge handlers, manifest/plist. **Done.**
2. ~~**Parser + vocabulary**~~ — cardinal/digit/letter readings, the
   spoken-form index, matching, computed confidence, `command` events.
   **Done**, with 50 tests; the parser is pure and testable against recorded
   transcripts, which is where the tuning loop starts.
3. ~~**Demolition**~~ (backend) — delete v1 and the cross-origin-isolation
   scaffolding. **Done.**
4. ~~**The page**~~ (backend) — mic button, receiver, field states, tones,
   guarded `sold`, undo. **Done** — and it is what exposed the two app-side
   capability/permission bugs at the top of this file, since nothing had ever
   called `voiceGetState` on a real phone before.
5. **Then measure.** Log `{heard, chosen, confidence, corrected_to}` (VOICE-5)
   and use real sessions to tune the grammar over `/api/mobile/config/`. If
   accuracy is still short after tuning, the ordered answers are: phrase
   biasing (`biased` backend) → cloud streaming with keyword boost → Picovoice
   Rhino. Not a rewrite — that's what `SpeechBackend` is for.

The one thing not to repeat from v1 is shipping straight to step 5.

### Not done, and deliberately

- **No spoken readback** (§5, phase 2) — needs `flutter_tts` and a duck of the
  recognizer while speaking.
- **No tones or level meter in the app** — both are page-side rendering; the
  app emits `level` events at ~10 Hz and the page draws the meter.
- **No native voice on the offline set-winners screen.** The parser is Dart and
  could serve it, but the vocabulary is a network fetch by design (§4.2), and
  offline mode stays as small as it is.
