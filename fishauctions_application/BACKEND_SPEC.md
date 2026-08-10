# Backend Spec — Web-Configurable Printing, Push Notifications, AR Lot Mapping & Offline Sync

Handoff spec for `iragm/fishauctions` (the Django backend). The Flutter app work is
tracked separately in this repo; this document is everything the *backend* needs so
the app can be a dumb interpreter and all product behavior lives on the web.

Design principle for both features: **changes to the website ship in minutes,
changes to the app take dev time.** Anything that could plausibly vary per
printer, per deployment, or per product decision is a Django model instance or a
template — never an app constant.

---

## Part VOICE-6 — log the utterances that matched nothing

`VoiceCommandLog` is written when a command is **accepted**, so the failures are
invisible. "Bitter" for "bidder" opened no slot, produced no command and reached
no table — and it is precisely the row we needed, on a model whose own docstring
says it exists to make "the word we get wrong most often" a query rather than a
hunch. Right now that query can only ever return words we already handled.

The app already pushes every transcript to the page (`{type: 'transcript',
text, partial}`), so no app change is needed. The page should log a final
transcript that produced **no** `command` event, and one that produced a command
below `unsure_at`:

- `slot` — allow blank, meaning "nothing matched".
- `chosen` — blank for these rows (already `blank=True`).
- `confidence` — null when nothing matched.
- Rate-limit per session. A continuous recognizer hears the room; most of what
  it transcribes is not addressed to the app, and every phrase must not become a
  row. Something like "at most one row per 5 s, and only when the transcript
  contains ≥2 tokens" keeps it useful without logging the crowd.

Admin value: group by `heard`, order by count. Anything frequent and unmatched
is a candidate anchor synonym, which is a `VoiceGrammar` row edit and ships
without an app release.

---

## Part VOICE-7 — voice settings panel on the set-winners page

Native-side is **implemented and live**; this is the page half. The operator
needs to tune voice *during* an auction, on the phone in their hand.

Three bridge handlers' worth of contract, all of which already answer:

```js
await bridge.callHandler("voiceGetSettings");
// → { settings: {confident_at, prefer_on_device, bias_low_prices},
//     settings_range: {confident_min: 0.6, confident_max: 0.9},
//     bias_supported: false }

await bridge.callHandler("voiceSetSettings", { confident_at: 0.72 });
// → the same shape, with what is now in force. Merged field by field, so send
//   only the control that moved. Takes effect on the next utterance — no need
//   to stop and restart listening.
```

`voiceGetState` also carries all of the above, so the panel can render from the
call the page already makes on load.

**UI** — a settings button next to the mic that expands a panel below it:

1. **Slider**, `min = settings_range.confident_min`, `max =
   settings_range.confident_max`, `step = 0.01`, value `settings.confident_at`.
   **Do not show the number.** Label the ends — left "Fill it in, I'll check",
   right "Only when you're sure" — with help text along the lines of *"How
   certain the app must be before it fills a field without flagging it. Lower
   catches more, and gets more wrong; higher means retyping more often."* Send
   on release, not on every input event.
2. **Checkbox "Process on this phone"**, value `settings.prefer_on_device`.
   Help text: *"Faster and works without a connection. Uncheck for better
   accuracy."* Works on both platforms; both need the device's language pack
   downloaded, and the app already falls back to network recognition by itself
   if the phone turns out not to have one.
3. **Checkbox "Bias towards lower numbers"**, value `settings.bias_low_prices`.
   Help text, as specified: *"If in doubt, guess 17 instead of 70. Only for sell
   prices."* Render it whatever `bias_supported` says — the half that works
   everywhere (picking the smaller of two readings the recognizer already
   returned) needs nothing from the platform.

   `bias_supported` reports whether *phrase biasing* is also active — i.e.
   whether this device will be told the auction's real lot and bidder numbers
   before it listens. It is a note, not a gate. Two things to know when
   rendering it: it is **false until the operator has tapped Listen once**
   (the app won't make a platform call on page load just to answer it), and it
   is false on Android below 13, where `EXTRA_BIASING_STRINGS` doesn't exist —
   the recognizer still works there, it just can't be given a vocabulary.

Settings are **per device and stored by the app**, deliberately: they describe
this phone in this room — its microphone, its language pack, its noise floor —
and syncing them to the account would fight an operator who uses two handsets.
There is nothing for Django to store.

---
