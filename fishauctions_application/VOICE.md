# Voice set-winners

Hands-free lot selling on `/auctions/<slug>/lots/set-winners/`: the operator calls out "lot forty two … bidder seventeen … twenty five dollars … sold".

Operational rules live in `CLAUDE.md`. This file is the design record — why v1 failed, the file map, and the bridge contract.

**Both halves are live; the first real session on hardware is still unproven.**

## Why v1 (Vosk in the browser) failed

Only one of four causes was "wrong engine", and an engine swap would have fixed the least important one:

1. **The model was never deployed** — only a 147-byte placeholder is committed; the weights are gitignored, so `createModel()` was loading 404s.
2. **The number parser concatenated digits**: "twenty five" → `205`, "one hundred five" → `1001005`. A perfect recognizer would still have typed `205` for a $25 lot.
3. **`GAIN = 5` on Float32 samples in [-1, 1] with no limiter** — anything above 0.2 amplitude squares off into distortion, which is the most destructive thing you can do to an acoustic model.
4. **A 40 MB generic dictation model in WASM**, in a noisy hall, doing open-vocabulary transcription for a six-word command language.

It also cost the page its analytics, ads and CDN assets: SharedArrayBuffer forced cross-origin isolation, so the template self-hosts jQuery/Bootstrap/icons and `CrossOriginIsolationMiddleware` exists for that one path. All of it is deletable.

**The listening model was right** — keyword-anchored slot filling. The recognizer, the parser, and the absence of any tuning loop were wrong.

## Files

```
lib/models/voice_command.dart            slot, confidence model + weights
lib/models/voice_grammar.dart            served config, merged over the bundle
lib/models/voice_vocabulary.dart         this auction's values + spoken-form index
lib/services/voice_spoken_forms.dart     number/letter words, form generation
lib/services/voice_parser.dart           the walk, matching, confidence
lib/services/speech_backend.dart         the swappable interface
lib/services/platform_speech_backend.dart
lib/services/biased_speech_backend.dart  + BiasedSpeechBridge.kt / .swift
lib/services/bundled_voice_grammar.dart  cold-start default
lib/services/voice_vocabulary_service.dart
lib/services/voice_command_service.dart  session, dedupe, sold-guard, bridge state
lib/services/microphone.dart             arbitration with palette dictation
```

`voice_command_service.dart` is the only stateful piece. The grammar rides in `AppConfig.voice` (a raw map — tuning data, not app config) and is applied by the shell's `_warmVoice()`.

## Bridge contract

```
voiceGetState()               → {supported, listening, permission, backend, on_device}
voiceStart({auction, locale}) → {listening, error}
voiceStop()                   → {listening: false}
voiceGetSettings() / voiceSetSettings({...})
```

Two invariants, both bugs before they were invariants:

- **`voiceGetState` prompts for nothing and starts nothing.** The page calls it on load. `supported` and `permission` are separate answers, because `{supported: true, permission: false}` is the *normal* first visit and must still reveal the button.
- **None of them ever throws.** A rejected promise is indistinguishable, on the page, from a build with no voice handlers — its catch prints "Voice is not available on this phone". Failures resolve as a state map carrying `error`. Guarding the *body* is not enough: `voiceStart` threw `NoSuchMethodError` on `args.firstOrNull` before reaching its `try` and answered every tap with that sentence for a month. **Declare bridge parameters as `List<dynamic>`** so the mistake is a compile error.

App → page is a push, not a poll — `evaluateJavascript` into a receiver the page installs as `window.fishauctionsVoice.onEvent`:

```jsonc
{"type": "state",      "listening": true, "on_device": true}
{"type": "level",      "level": 0.34}                        // ~10 Hz, 0..1
{"type": "transcript", "text": "bidder seventeen", "partial": true}   // partial is not actionable
{"type": "command",    "slot": "bidder", "value": "17", "confidence": 0.93,
                       "heard": "bidder seventeen", "candidates": ["17", "70"], "blocked_by": []}
{"type": "error",      "code": "permission_denied", "message": "…"}
```

`slot` ∈ `lot` · `bidder` · `price` · `sold` · `unsold` · `undo` · `clear` · `confirm`. **Unknown slots must be ignored by the page**, so either side can add one without the other shipping.

## Not done, deliberately

- **No spoken readback** — needs `flutter_tts` and ducking the recognizer while speaking.
- **No tones or level meter in the app** — the app emits `level` events; the page draws the meter.
- **No native voice on the offline set-winners screen.** The parser is Dart and could serve it, but the vocabulary is a network fetch by design, and offline mode stays small.
