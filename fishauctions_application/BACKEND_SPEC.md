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

- When `voiceConfig.cloud` is on and the state says `web_microphone`, add a **Listen with** choice
  to the voice settings panel: *This phone* (the app's recognizer, free) or *OpenAI* (charged to the
  site per minute). Store it in `localStorage` (per device, like the panel's other values); default
  *This phone*.
- With *OpenAI* chosen, the Listen button runs `voiceCloudStart()` / `voiceCloudStop()` instead of
  `voiceStart` / `voiceStop`, and the `voiceInit` bridge branch must not hide that path — today any
  `flutter_inappwebview` sends the button to the bridge unconditionally.
- If `getUserMedia` is refused in the app, the app has already shown a snackbar pointing at the
  phone's settings; the page's "Allow it for this site" wording doesn't apply there (no site
  permission to allow), so say "Allow the microphone for the app" when the bridge exists.
- `VoiceGrammar.cloud_model`'s help text ("Off leaves only the app") should say the app can use it
  too.
