# CLAUDE.md — FishAuctions Flutter App

## What This Is

A Flutter client for FishAuctions: **a thin WebView shell + a native hardware layer**. The WebView loads the Django web UI (JWT bridged into a cookie session); native code handles only what the web can't reach — Square Tap to Pay, Bluetooth label printing, camera/QR scanning, speech.

Backend: https://github.com/iragm/fishauctions, with a read-only local checkout at `/home/user/staging/fishauctions`. Use it to check what endpoints and fields actually exist.

- **Never edit `/home/user/staging/fishauctions`.** Spec backend changes into `BACKEND_SPEC.md` and hand them over.
- **Prefer the backend over native/local logic.** Native is only for hardware, true offline, or a platform API with no web equivalent.

## Running

```bash
flutter run --flavor dev -t lib/main.dart --dart-define=FLAVOR=dev        # staging backend
flutter run --flavor prod -t lib/main.dart --dart-define=FLAVOR=prod
flutter run -t lib/main.dart --dart-define=FLAVOR=staging                 # iOS: no --flavor
```

Android flavors (`android/app/build.gradle.kts`): `dev` → `com.fishauctions.app.dev`, `staging` → `.staging`, `prod` → `com.fishauctions.app`. `lib/config/environment.dart` maps FLAVOR → API base URL; dev and staging both point at staging. iOS has no Xcode schemes — dart-define only.

## Architecture

`lib/{config,models,screens,services,widgets,utils}/` · Riverpod · go_router · Dio · freezed · flutter_secure_storage (JWT only).

## Key rules

- **Flavor = environment.** Never hardcode URLs; read `EnvironmentConfig`.
- **Tokens live in `flutter_secure_storage`.** No exceptions.
- **Never send a binary `Accept` header to `/api/mobile/`.** DRF negotiates content before authentication, so `Accept: application/pdf` 406s before the view runs. Send `*/*` (`LabelService._accept`).
- **A JS bridge handler must declare `List<dynamic>`** and must never throw. An inferred `dynamic` parameter turns `args.firstOrNull` (a `package:collection` extension) into a failed dynamic call, and the plugin turns a throwing handler into a rejected promise — which every page reads as "this build lacks the handler". Use `_firstArg`.
- **`bi_icons.dart`'s map and fallback must stay `const`.** Release builds tree-shake the icon font, so a runtime-built `IconData` renders tofu.
- **Never draw Tap to Pay artwork, never shorten the name, never use `Icons.contactless`.** Only SF Symbols' `wave.3.right.circle[.fill]` is permitted (requirement 5.5); the app ships no icon on those controls.

## Backend API — `/api/mobile/`

All except login/refresh need `Authorization: Bearer <access>`.

```
POST auth/login/       {credential, password} → {access, refresh}
POST auth/refresh/     {refresh} → {access, refresh}   ← rotation on
GET  auth/me/
POST auth/web-session/ → single-use handoff token (300 s TTL) for cookie sessions
POST devices/register/ upsert by device_uuid; call after login
GET  config/           square/firebase/voice/menu blocks, terms & privacy URLs
```

Access tokens 60 min; refresh 30 days, rotated and blacklisted.

```
labels/<pk>/ [?fmt=pdf|png&resolution&dpi] · labels/prefs/ · labels/printed/
printers/profiles/ · printers/observed/
ar/lots/ · ar/observations/ · ar/events/ · ar/positions/
offline/snapshot/ · offline/sync/
checkin/ping/ · checkin/join/ · checkin/set-location/
payments/create/ · payments/confirm/ · payments/authorization/
notifications/prefs/    ← NOT implemented (BACKEND_SPEC Part N)
```

## Auth — account required

No anonymous browsing. The router traps signed-out users on `/login`, `/signup`, `/password-reset`; `/legal/terms` and `/legal/privacy` work signed in *and* out.

- **Apple and Google only**, each rendered only when `config/` says the deployment configured it. The app sends allauth's own provider ids, so native and web land on the same `SocialAccount`.
- **Apple leads on iOS** — guideline 4.8 requires Sign in with Apple once any third-party login exists, at least as prominent. Use each vendor's own artwork; never restyle.
- **Apple sends name/email exactly once**, on first authorization. Hints, never identity — that's the verified token's `sub`.
- **Sign in with Apple is nonce-bound**: SHA-256(nonce) to Apple, raw to the backend, which must check them.
- **A social sign-in may not finish natively** — the backend returns `continue_url` + `pending_token` and allauth's flow runs in a restricted WebView (`/social-continue`).
- **Facebook was removed 2026-08-10** (it doesn't verify emails, and an unverified address can't identify an account). Don't re-add. Its parting shot: `fb$(FACEBOOK_APP_ID)` with an unset id expanded to the reserved scheme `fb` and drew `ITMS-90155` *after* a green CI run — the upload succeeds, the rejection arrives by email, and the wait-for-processing step polls until its JWT expires and reports a misleading `401`.
- Signup/reset are allauth web flows in a restricted WebView, confined to an allow-list. **Allauth is mounted at the site root** (`/signup/`, `/password/reset/`, `/login/`, `/logout/`).
- **Nothing prompts for a permission at launch.** Location is a soft banner on listings plus a direct ask in lot scanning; notifications on `/preferences/` and in-person lot pages; camera/Bluetooth by the screen that needs them. Banners wait for the page to settle (`_claimBanner`) and bail if navigation moved.

### What must never be read as a sign-out

Only three signals: a completed **POST** `/logout/`, account deletion, and `auth/refresh/` answering **401** for a token that was not concurrently rotated.

- **A GET of `/logout/` is a confirmation page.** Intercept the POST (`_webLogoutHook` UserScript + a native `request.method == 'POST'` fallback). Account deletion is caught at `/account/deleted/`.
- **Landing on `/login/` is never a sign-out** — the cookie session lapsed while the native one is fine. `_reconcileWebSession` re-mints the handoff and resumes; the repair counter resets on any page that renders.
- **400/403/5xx/timeouts/offline never wipe anything.** 429 backs off with jitter — the endpoint is throttled per IP and an auction hall is one NAT.
- **A 401 for a token rotated mid-flight is ignored** — re-read and compare the stored token before clearing. Single-flight refresh is load-bearing.

## WebView shell

- Boots through the `auth/web-session/` handoff when there's no `sessionid` cookie; repairs a lapsed session on a `/login/` bounce.
- Intercepts `fishauctions://` for `print/<pk>`, `print/?lots=…`, `pay/<pk>`, `ar/<slug>`, `tap-to-pay`.
- **No OS registration for `fishauctions://`** — those links only appear in our own pages, so registering would let any app drive native flows.
- Last page remembered 24 h per account (`LastPageService`) and used as the cold-start landing page; quick actions map type → path (`ShortcutService`).
- **Downloads are refetched with the WebView's cookies** (`DownloadService` — these are Django session endpoints). `.pkpass` → PassKit's Add-to-Wallet sheet, `.ics` → OS calendar, PDF → OS print dialog on the System-printer method, else the share sheet.
- **`mailto:`/`tel:`/`sms:` go to the OS; every other non-http scheme is blocked** (`external_links.dart`). The allow-list is closed on purpose — this shell renders user-authored HTML, and `intent:`/`market:` can launch arbitrary apps.
- **Web Speech is deleted at document start** (`_hideWebSpeechApi`). Android's WebView *defines* `webkitSpeechRecognition` without wiring it to a service, so feature detection finds it, believes it, and silently does nothing.
- **Config is re-fetched on resume if it never loaded** — Riverpod caches a `FutureProvider` failure for the process, so a cold start with no connectivity otherwise leaves Square uninitialized all session.

### Drawer menu

Renders the `menu` block of `config/` (`DrawerMenu`, Part MENU). Three tiers via `MenuStore`: server payload > last good payload on disk > bundled six-link skeleton.

- **The skeleton is a life raft, not a fallback menu** — growing it back into a navbar mirror recreates the hand-maintained copy this replaced.
- **A bad payload can never empty the drawer**: bad rows drop individually, and a payload yielding nothing renderable is ignored so the previous tier keeps rendering.
- **Four app-owned rows merge in at section anchors** (Sign out, Offline mode, Tap to Pay, Clubs); a row whose anchor is missing lands in a trailing section.
- **This is the one per-user part of `config/`, so a stale token is dangerous**: the endpoint reads the bearer *optionally* and answers a bad one with **200 + the signed-out menu**. Refresh first (`ensureFreshAccessToken`) and record `configIsForCurrentUser` so `_warmMenu` refuses to adopt an anonymous menu.
- Section ids `main`/`lots`/`account`/`admin`/`about`; nothing is hardcoded and query strings in paths are load-bearing.

### Command palette & dictation

The app-bar title opens the **website's** palette and falls back to the native one only when the JS says it isn't there — the native one is the offline path, over the JWT API.

`dictateGetState`/`dictateStart`/`dictateStop` → `DictationService`, events to `window.fishauctionsDictate.onEvent`. Any page can fill a field by talking.

- One-shot (`continuous: false`); does **not** force on-device recognition (Android's on-device recognizer fails with no language pack).
- **`dictationPause` is 1.5 s vs set-winners' 3 s** — the silence window *is* the delay before the mic goes off, and on Android it applies twice.
- **A browser has two silence windows; `speech_to_text` has one.** `waitForSpeech` (8 s) arms the listen and `changePauseFor` drops to the short window on the first partial; without it, 1.5 s was a deadline on getting *any* transcript back, network round trip included.
- **A phrase ending with no final transcript is still reported as one** (`_finalizePending`), matching Web Speech's `stop()`. Not on an explicit `dictateStop` — that's cancelling.

### App Links / Universal Links — off on purpose

The Android intent filter is **commented out** and iOS has no `associated-domains`. Claiming the domain takes `auction.fish` links away from the browser for everyone with the app installed — a product decision.

- **"Inert" was not free**: Play Console runs its own domain check and reports a permanent failure, and an *unverified* https VIEW filter makes Android show a chooser instead of going straight to the browser.
- **The link arrives as a go_router exception**, so `DeepLinkService.offer` runs in `redirect` (which also runs on the error match list), not only `onException`.
- Turning it on: Android needs `ANDROID_APP_LINKS` with the **Play re-signing** fingerprint (not the upload key), then the filter, then an explicit path list — `assetlinks.json` is host-level with no path field, and the four OAuth callbacks must never reach the app. iOS needs Associated Domains on the App ID **first**, then `IOS_APP_LINKS`, then the entitlement; the reverse order breaks every signed export.

## Features

### Label printing

Configured on `/printing/`; the app branches on `print_method`. Contract in Part 1.

- **Bluetooth printing has no screen.** `LabelPrintService` connects, renders and sends over whatever page the user is on, with a progress snackbar and Stop. Only failures interrupt. `PrintLabelScreen` survives for PDF only; System printer goes straight to the OS dialog.
- **No printer paired → `/printing/` once** (`PrinterSetupPrompt`, device-local), then a snackbar with a Set-up action.
- **Multi-lot works end to end** (Part W): `fishauctions://print/?lots=…` loops the single-lot raster path with one connect. The backend gates in the **view**, so every bulk entry point routes to the printer.
- **A batch link with unreadable prefs prints anyway.** "Not Bluetooth ⇒ stale page ⇒ reload" is an infinite loop when prefs are simply *null* (offline); a null answer defers to the server.
- Server-rendered PNG at the printer's exact raster → 1-bit pack (`LabelRaster`) → `PrinterProfileDriver` runs the profile's declarative JSON program. Profiles are Django admin rows; bundled seeds cover cold start and must stay in sync.
- **Most 4″ printers don't speak ESC/POS.** `tspl-raster` drives the VEVOR Y486BT: the raster is inlined in an ASCII `BITMAP` command and **a `0` bit prints black**, so the profile sets `invert`. TSPL has no completion ack, hence no `await` step.
- **"First writable characteristic" is wrong on serial-bridge modules** — the Y486BT's first writable is the module's *control* channel. `_knownDataCharacteristics` tries documented data pipes first; the fallback skips SIG housekeeping services (`1801` publishes a writable characteristic that sorts first).
- **The profile's GATT ids beat the remembered ones on reconnect**, or a corrected profile could never reach an already-paired printer.
- **A dual-mode printer appears twice and only one entry works.** Android's bonded list includes classic pairings; this app is BLE-only, so a GATT connect to the classic radio times out. The BLE side advertises separately, often `-BLE`, different MAC.
- **A BLE write can't exceed `MTU − 3`** and both platforms reject rather than split; un-negotiated links sit at 20 usable bytes. `_negotiateMtu` requests 512 on Android and `_maxWritePayload` clamps to the *live* `mtuNow` (iOS settles MTU after connect returns).
- **Raster geometry is `mm × dpi / 25.4`, capped at the printhead** — never printhead width scaled by aspect ratio. `exceedsHead` outranks any driver warning.
- **Profile resolution is cheapest-first**: BLE name → Device Information Service → `PrinterProbe` (what language it answers in) → ask the user. DIS often describes the *radio module*. A language matching exactly one profile auto-selects; every probe query must stay read-only.
- **A profile declaring no way to be recognised is never auto-matched** (`isGenericFallback`) — `escpos-raster` was otherwise the unique ESC/POS speaker and won every printer.
- **The scan list is ranked, never filtered** — filtering hides exactly the unknown printers this flow exists to onboard.
- **No query can discover what a status byte means.** `PrinterCharacterization` walks the user through four physical states, so `status_flags.values` is derived rather than guessed.
- **Schema v2 is implemented and deliberately unused** (`supportedSchemaVersion`) — the reader must ship before the first row needing it.
- **Label rendering stays image-only on the server.** Emitting printer bytes server-side would move printhead width, invert polarity and MTU chunking behind a network call at an auction hall.
- **"Print test label"** proves language, geometry, polarity and orientation in one loop, on-device so it works while pairing and offline.
- Pairing POSTs DIS strings, service UUIDs, probe replies and the full GATT tree to `printers/observed/`; **DRF silently drops undeclared keys, so this is discarded until Part U1**.
- **Remote print (Part R)**: app side done. **The phone cannot be summoned** — Android blocks background Activity starts, iOS silent push won't reach a force-quit app, and the BLE link lives in a UI-scoped provider. So the feature is "the app is open", measured by a 5-min heartbeat and said on the `/printing/` checkbox. First 404 disables it for the process.

### Lot scanning (internally "AR")

**Called "Lot scanning" in every user-facing string.** "AR" survives only in the deep-link scheme, `/api/mobile/ar/*`, `?src=ar`, and identifiers.

- Camera screen scanning lot-label QRs (`/qr/<pk>/`) with name overlays; one label centered/close pops a card. Entry: `fishauctions://ar/<slug>`, `?locate=<lot_pk>`.
- **Chips show the lot's *other* name** (`ArLotMeta.secondLine`) — common under scientific and vice versa, scientific italicised. The rule is the backend's, so the app never has to know why a half is blank. In a hall you can read a name across the room but not a label.
- Interactions report to `ar/events/` as `scanned`/`zoomed`/`zoomed_full`, de-duped per lot per type per session.
- **Angle-only measurements** (QR corner centroids + gravity vs device-reported FOV) — deliberately nothing depends on printed QR size, since sellers print arbitrary label sizes. A bearing-dominant solver builds a per-auction 2D map; locate mode places a beacon from a map→screen homography, or from bearing-only resection when too few labels are visible.
- **Back closes the card before leaving the screen** (`PopScope`), and back from a lot page returns to scanning. That was dead code — it keyed on `?src=ar`, which `base_page_view.html` strips via `history.replaceState` on every load. It now keys on the path and pops the real **pk**, which the shell could not re-derive: the segment after `lots/` is `lot_number_display` (often `BOB-1`, and a different integer from the pk when numeric).
- **Orientation comes from the *interface*, never `UIDevice.current.orientation`** (Android already read the display rotation). The device answers `.faceUp` for a phone held flat over a table of labels — this screen's actual posture — and that has no image orientation, so the old fallback silently assumed portrait. Get it wrong and `reportedWidth`/`reportedHeight` swap: every QR bearing is computed in a transposed frame, chips land on the wrong labels and the beacon points into the room. Nothing about the preview looks wrong, because ARKit draws that itself.
- **The only screen that raises an OS permission dialog directly** — location, 700 ms after the camera paints, only if undecided. Someone here is standing in an auction hall. Declining costs nothing: scanning, overlay, map and locate are all camera geometry.
- **Removed 2026-07-25**: Watched/Recommended beacons on any mapped lot within 6 ft — the map isn't precise enough for unprompted "you're next to this" claims. Nothing it needed was torn out.
- **Backend v1 landed**, including every per-frame sensor channel (gyro yaw, GPS anchoring, compass heading, pedometer odometry). **Still open: island detection/labeling/merging** — v1 can't relate lots never co-visible in a frame and overlaps islands at the origin. The app already parses `component` and refuses cross-island fixes.

### Offline auction management

Native mirrors of the users / bulk-add / set-winners pages for the operator's **last admin auction only**. `OfflineSyncService` pulls a snapshot into `OfflineStore` (two JSON files); changes queue as idempotent ops (client UUIDs; offline-created rows referenced `op:<uuid>` so server renumbering can't misroute later ops).

**Conflicts are never silently overwritten — the server copy wins** and the rejected op surfaces as a notification. Sign-out wipes the files. A 404 disables sync for the process.

### Voice set-winners

Hands-free selling on the set-winners page. Design and v1 post-mortem: `VOICE.md`. Both halves live; **the first real session is still unproven on hardware.**

- **The app owns only the microphone** — iOS WKWebView has no Web Speech API and the shell denies the WebView's mic. The page keeps the form.
- **Capability and permission are different questions.** `voiceGetState` runs on page load and must not prompt; it used to call `initialize()`, which requests `RECORD_AUDIO` and reports the permission as the capability — so the mic dialog fired on page render and the button hid itself on every phone that hadn't already granted it.
- **One microphone, arbitrated by `Microphone`**; two `SpeechToText` objects contend for one platform service. Last thing tapped wins, and swapping backends stops the current holder first.
- **Values are matched against a closed vocabulary, not parsed from free text.** `bidder_number` is a `CharField` and routinely text, which spills into lot numbers (`BOB-1`). The auction's real identifiers are expanded into spoken forms and looked up.
- **Every value slot needs an anchor keyword**; a bare number writes nothing, so the auctioneer's chant can't corrupt a field. `sold` submits only when all three fields are filled and confident.
- **Anchor matching forgives *speaker* confusions**: substitutions within a voicing pair (t/d, s/z, p/b, k/g, f/v) cost nothing, because American English flaps both consonants in "bidder"/"bitter" — there is nothing in the audio to distinguish them. Values use plain distance, deliberately: "ten" and "den" must stay different answers.
- **Confidence is computed, never taken** — `speech_to_text` reports `-1` constantly; three of the four signals are ours.
- **The grammar is served data** (`voice` block in `config/`), so tuning is a Django row edit.
- **Three device-local settings** (confidence, on-device, low-price bias). **Every field is nullable and null means "whatever the deployment served"** — stamping today's defaults would freeze the device out of future retunes.
- **Prices can be biased separately, because both APIs bias *phrases***: `"seventeen dollars"` is a different string from `"lot seventeen"`. `VoiceBiasPhrases` spends Apple's ~100-phrase budget by expected value — non-numeric bidder ids first, plain numeric lot numbers last.
- **`speech_to_text` cannot do phrase biasing at all**, hence `BiasedSpeechBackend` + native bridges owning `SpeechRecognizer`/`SFSpeechRecognizer` directly. `biased` is the default; `"backend": "platform"` in served config is the kill switch.
- **The native halves handle one utterance and know nothing about sessions.** Re-arming, both silence windows, on-device fallback, three-strikes and promoting a last partial all live in `RestartingSpeechBackend` — that logic has been wrong three times already.
- **`supportsPhraseBias` is a runtime question on Android** (`EXTRA_BIASING_STRINGS` is API 33, `minSdk` 28); unconditionally true on iOS.
- **Two races**: Android tags each utterance so a predecessor's callbacks can't tear down its successor; and Dart's pause timer waits for the *platform's* answer rather than declaring the phrase over, or the real final lands inside the next utterance. A 1.5 s watchdog covers a recognizer that answers a stop with nothing.
- **Only one of four phrase endings produces a final result, and set-winners acts on finals only** — so a whole command could be heard and discarded. `_flushPendingAsFinal` promotes the last partial; this is why "lot five" never filled anything while longer phrases worked.
- **A stopped recognizer keeps calling back on both platforms**, so both native halves stamp each utterance and drop anything that isn't the live one (Android `isCurrent`, iOS `liveUtterance`). `finish()`/`stopListening()` *request* the final result; it lands after the successor's task is installed, and acting on it runs teardown against the phrase now being spoken. **A microphone that dies mid-auction is this, until proven otherwise.** iOS lacked the guard entirely until 2026-09-03.
- **iOS hands the audio session back on a 3 s deferral, cancelled by the next `start`.** Deactivating between two words costs the anchor keyword; never deactivating leaves `.record` active, the mic indicator lit and later in-app audio silent. It's inferred, not signalled — `stop()` returns while the final transcript is still in flight, so there is no safe "session over" message.
- **Android's `permanent` error flag means nothing** — the plugin sets it on every error. A session ends on a permission refusal or three consecutive failures.
- **On-device recognition is a request a phone can accept and then fail**: `isOnDeviceRecognitionAvailable` reports the service, not a downloaded language pack. First failure drops to network for the process.
- **Both recognizers write money as a symbol**: "twenty five dollars" arrives as `$25`, and "dollars" is the price slot's anchor. `_spellOutCurrency` reads the symbol as the anchor it stands for, before tokenizing.
- **`.duckOthers` is illegal on iOS's `.record` category** and its rejection lands in the same catch as everything else. Removed; `.record` already interrupts other audio.
- **The event channel is subscribed once per backend.** Cancelling a broadcast subscription doesn't wait for `onCancel`, which clears the messenger's handler for the channel name the new subscription just installed.
- **A recognizer that says nothing is the one failure it can't report** — 6 s with no status or level events is a broken pipe, not a quiet room.
- **Every final transcript is logged with what it parsed to.** From outside, "it misheard me" and "it never got a final" look identical.

### Proximity check-in

`CheckinService` POSTs position at mount/resume and every 10 min, **only when location permission already exists**. The server decides what to surface; all copy is the server's, and unknown action types are ignored.

- **The bidder number is the deliverable** and used to be thrown away — nothing a just-arrived bidder can reach shows it. Read as a **string**; any message carrying one gets a 12-second snackbar.
- **A nudge is an OS notification, not a modal** — these arrive on the ping loop's schedule, unrelated to what the user is looking at, and a bottom sheet landed on top of the lot-scanning camera. **Nothing about this prompts**, so the in-app fallback stays and for most users is the live path — deferred until the shell is the *visible* route.
- **The tap must work after the app is dead**, so the whole action rides in the payload rather than memory, and cold-start taps come from `getNotificationAppLaunchDetails`.
- **The admin location pin takes a *precise* fix and refuses a bad one** (`precisePosition`): it becomes the 500 ft geofence permanently. Best accuracy, 30 s, no cached fallback, rejects worse than 50 m or older than 2 min. This is the one place the coarse-location loophole bites — Android "Approximate" and iOS "Precise Location: off" both leave `hasPermission()` true.
- **Outstanding backend defect**: the candidate query doesn't filter on `promote_this_auction`, so an unlisted auction pushes its title and a working Join button to any signed-in user within two miles (Part CHECKIN-1). Not filterable app-side.
- Right and easy to doubt: the admin offer **is** geofenced (2 mi) and the whole thing **is** time-boxed (`in_welcome_window`, 3 h before start to end).

### Notifications

`PushService.init` never prompts. It reads the FCM token **only if the OS already allows notifications**, because the backend treats a row with a token as "this user can receive push".

Two prompt sites running the identical opt-in (`PushPromptService.enable`): `/preferences/` (matched from the URL — that page *is* the settings screen and its checkbox is server-disabled until a token exists), and an in-person lot page via `pushPromptOffer('lot_selling_soon')`, once per device.

Both toggles write through `notifications/prefs/` — **not implemented** (Part N). Until then the OS half completes and the user is pointed at `/preferences/`; the app never claims success it didn't get. Details in `PUSH.md`.

### Payments — Square Tap to Pay

`square_mobile_payments_sdk`. Charges complete on-device; there is no client-side nonce. Credentials resolve **per invoice** on the backend and ride the `create` response — the app never stores a Square token.

```
POST payments/create/   {invoice_pk} → {amount, currency, location_id, access_token,
                                        square_environment, idempotency_key, reference_id}
POST payments/confirm/  {invoice_pk, payment_id, idempotency_key} → {payment_id, status, receipt_number, receipt_url}
```

The app must tap with the backend's `reference_id` verbatim; `confirm` verifies it via Square's GetPayment and rejects a mismatch.

- **Never call the Square plugin before `initializeSquare`** — on Android that ends the process and **no Dart `try`/`catch` can stop it**. Every plugin module holds its manager in a `companion object` property, so a call before `MobilePaymentsSdk.initialize()` throws inside a static initializer; the JVM rewraps that as `ExceptionInInitializerError`, an `Error`, and Flutter's `MethodChannel` catches only `RuntimeException`. Not calling is the only defence: `PlatformBridge.squareInitialized` guards every SDK-touching getter in `SquarePaymentService`. This reached sign-out, not just Tap to Pay.
- **`/tap-to-pay` is iOS-only, at every entry point.** The drawer tile and the offline palette's row were gated; `fishauctions://tap-to-pay` was not, and the server offers that row to any mobile client (Part TTP-10). Android has no setup screen because there is nothing to set up — it charges from the invoice page's own button.
- **Education follows a terms acceptance wherever it happened** (4.2), which means checkout too — `showTapToPayEducation`, on a *fresh* link only. Wiring it to the settings screen alone missed the likeliest first acceptance of all.
- **The app id comes from `config/`**, so one binary serves any deployment. It's the *public* integrator id, environment-specific, and must agree with `square_environment`. The SDK has no re-initialize — the app refuses a different app id mid-session.
- **The cashier launches the charge explicitly** (`fishauctions://pay/<pk>`). A Square charge takes over the whole screen, so we never auto-start on invoice load. The button is also the retry.
- **`paymentAttemptId` must be unique per attempt.** Square rejects a reused one outright — it does not de-duplicate, which is what the server-side `idempotency_key` does. Conflating them made every retry after a decline fail inside Square's UI.
- **Both platforms are verified taking real payments** — Android in production builds, iOS on 2026-09-02. Still needs a real NFC device (API 31+ / iPhone XS+ on iOS 16.4+) and Square production approval; not exercisable in CI.

#### iOS: Tap to Pay is an *additional* payment method

**This dead-ended every iOS charge on Square's "connect hardware to take card payments" screen for a day.** On iOS, `AdditionalPaymentMethods` includes `.tapToPay` alongside `.keyed` and `.cash` — it is not the prompt's implicit primary method — and plugin 2026.8.1's iOS mapper stopped falling back to `.all`. So `additionalPaymentMethods: []` built a prompt with **no methods at all**, whose empty state is that screen. Android's mapper ignores the list entirely, which is why Android always worked.

`SquarePaymentService._startPaymentIOS` goes around the plugin's typed API to pass `tapToPay`, because the Dart `AdditionalPaymentMethodType` enum only has `keyed` and `cash` while the iOS mapper accepts the string. Remove it when the enum catches up.

Two lessons: **the comment that hid this was accurate when written** and went wrong on a dependency bump; and **`getReaders()` had never been called** — the fact that reframed everything (the reader reporting `ready`) was one SDK call away the whole time.

Also iOS-only: the plugin's `Location.toMap()` omits `merchantId` and `cardProcessingActivated`, so the payment sheet's `cardProcessingActivated == false` gate is dead code there (null-safe, so it does nothing rather than misfiring).

#### Apple's review checklist

`TAPTOPAY.md` tracks every item; the backend half is Part TTP. We hold the **development** entitlement (2026-07-31); the **publishing** one gates TestFlight *and* the App Store and comes only after review.

- **Merchant education is Apple's** (`ProximityReaderDiscovery`, iOS 18+). Requirement 4.1 mandates it and it satisfies 4.4/4.6/4.7/4.8 at a stroke. It does need the Tap to Pay entitlement despite presenting education rather than operating a reader — measured, not documented.
- **The reader is warmed at launch, on resume, and when a page asks** (`prepare`, requirement 1.5) — which means *authorizing*, since that's what starts the reader preparing, and is what makes 5.6 (prompt within one second, 90% of the time) reachable.
  - **The page trigger is the `tapToPayWarm` bridge handler**, called by the pages that render the pay button; which pages those are is the server's question, same rule as `tapToPayOffer`. Throttled to one warm-up per 2 min since `prepare` re-fetches eligibility each call; mount and resume are not throttled.
  - **Subscribing to the reader callback is separate from warming and used to be trapped inside it.** `listenToReader()` sat behind `prepare`'s credentials gate, so any deployment where the backend withheld them never subscribed — while the charge path authorized regardless. `status` then sat at `unknown` for the process and `_awaitReaderReady` burned its full 12 s showing "Checking Tap to Pay…" before *every* charge. The payment sheet now subscribes right after `ensureAuthorized`.
- **Terms-acceptance status is asked of Apple every time** (1.6 forbids a local cache — a merchant can unlink from iOS Settings at any moment). Don't memoize `isAppleAccountLinked()`.
- **Enablement and education live outside checkout** (3.6, 4.3) — the drawer's Tap to Pay entry, shown only to merchants the backend calls eligible. Making it visible to everyone with a "nothing to set up" screen was tried and reverted the same day.
- **The awareness modal is gated on `canCharge` and driven by the server.** `eligible` only means "administers some auction"; `canCharge` means the backend issued live seller credentials. The auction ribbon calls `tapToPayOffer` when `Auction.offers_tap_to_pay`, and that handler is its **only** caller — the old URL-prefix guess is deleted with no app-side fallback, because guessing is what the guess got wrong.
- **The awareness marker is a file in the documents directory, not the Keychain** — the Keychain survives app deletion, and combined with marking *before* presenting, that made a once-ever flag no reinstall could reset.
- **`TapToPayService.resetForRecording()`** clears that marker and releases the Square authorization so Apple's onboarding video can be re-recorded; reachable from Troubleshooting on `/tap-to-pay`. The SDK has no unlink, so the Apple Account step is re-recorded with `relinkAppleAccount()`.
- **Troubleshooting — the diagnostics dump and that reset button — is developer builds only** (`EnvironmentConfig.enableDeveloperTools`, a compile-time `const` so a release prod build drops the subtree). It's a debug console dressed as a settings screen, and Apple reviews this feature by working the merchant flows. Default is any debug build plus the dev/staging flavors; **`--dart-define=DEV_TOOLS=true` forces it into a prod-pointing build**, which is where hands-on Tap to Pay work actually happens since Square only issues live credentials on production.
- **The reset button presents Apple's Account sheet *before* releasing the authorization.** `relinkAppleAccount()` answers `notAuthorized` on a deauthorized SDK, and the plugin reports a sheet that never opened exactly like one the merchant dismissed — so the old order failed silently on every press and the button looked inert. It now reports the SDK's error name, and re-reads the linked state afterwards rather than trusting the state the screen was built with.
- **Reader status comes from the reader *list*, not only the change callback** (`syncStatusFromReaders`). Square emits reader events on change, and the app can't subscribe until it has authorized — which is the thing that arms the reader — so a warm reader routinely produces no event at all, `status` sits at `unknown` for the process, and the payment sheet burns its full 12 s "initializing" wait before *every* charge on a reader that was ready all along. Seeded after each subscribe, at the end of `prepare()`, in `diagnose()`, and polled during `_awaitReaderReady`.
- **A declined charge must still be able to send a receipt** (5.10, "approved *or* declined"), so the success view no longer auto-dismisses — a window that closes itself isn't a way to offer an action.
- **"Update your iOS" and "this iPhone will never work" are different messages** (1.4). Square collapses both into `isDeviceCapable() == false`, so the OS version is read natively; below 17.6 is reported as an update.
- **Open**: the invoice page offers a card charge on a settled invoice (Part TTP-8). `invoice.html` gates on `status != "PAID"`, missing a zero balance, one covered by payments, and a seller the club owes. Template-only; not fixable app-side, since the app has no balance until `create` answers.

### Connect flows (Square, PayPal, Mailchimp, Google Calendar, Discord)

`utils/connect_flows.dart` + `services/connect_flow_service.dart`. Reworked from the report that **connecting anything signed the user out**.

- **The authentication session carries Safari's cookie jar, not the shell's** — which is why it was chosen (Google blocks SSO in embedded WebViews) and why our half couldn't run in it: every connect view is `LoginRequiredMixin` and 302s to `/login/`. Signing in there doesn't help either, because each flow stashes OAuth state in the Django session before redirecting.
- **So the session is minted, not inherited**: `POST auth/web-session/` → open the consume URL with `next=<connect path>?return_to_app=1`. `next` must be percent-encoded (an unencoded `&` is eaten by the query parser) and site-relative.
- **Mint immediately before opening, and again on every retry.** The token is single-use with a 300 s TTL and a replayed one redirects to `/login/` — reproducing the exact bug. Never stored, never cached.
- **The launcher is intercepted in the shell before it navigates** (`startsConnectFlowInShell`); those URLs render nothing and 302, so running one in the shell splits the round trip across two sessions. The Discord *settings* page is a real page and deliberately not a launcher.
- **A dismissal is not a failure.** Only Square ends with a `fishauctions-oauth://` redirect; the rest succeed and leave the user on our page with the sheet open, and tapping Done is reported as a cancellation — indistinguishable from a real back-out, and both mean "re-read state and say nothing". Never show "connection failed" on a cancel.
- **Not awaited from the navigation callbacks** — the sheet stays up for minutes and WKWebView holds its decision handler open until `shouldOverrideUrlLoading` returns.
- **A separate `fishauctions-oauth://` scheme on purpose**: `fishauctions://` stays unregistered with the OS, and on Android the plugin uses Chrome's Auth Tab, which returns to the launching activity.
- **Still owed** (Part TTP-7): the callback page should redirect to `fishauctions-oauth://square-connected` on the `session_opened_by_app` branch, with "tap Done" left visible underneath. Until then the auto-close never fires.

## CI/CD

Workflows in `.github/workflows/` (repo root, above `fishauctions_application/`).

- **ci.yml** — PRs + main: pub get, codegen freshness, format, analyze, test. No Gradle, deliberately. Steps live in the composite action `flutter-verify` so `dependencies.yml` runs the same checks (a `GITHUB_TOKEN` push never triggers `ci.yml`).
- **android-release.yml** — manual; CI gate, keystore from secrets (fails fast if missing), signed prod `.aab` to Play plus a sideloadable APK.
- **ios-release.yml** — manual, macOS. Default is unsigned `flutter build ios --no-codesign`. `distribute: true` signs; `export_method` picks `app-store` (TestFlight) or `development` (sideloadable, and the only way to get the Tap to Pay dev entitlement onto a phone without a Mac — needs a registered device). The development path copies `RunnerDebug.entitlements` over `Runner.entitlements`, which is why a Release archive legitimately carries the Tap to Pay key, `get-task-allow`, and `aps-environment=development`.
- **dependencies.yml** — weekly, and the reason there's no `dependabot.yml`. Dependabot's problem wasn't PR count: **nothing it opened had been shown to work together**. This updates pub, AGP/Kotlin/Gradle/`uses:` pins (via `bump_versions.py`, which *discovers* pins rather than listing them), verifies with `flutter-verify` **plus a real debug APK and an unsigned iOS build**, then opens one PR on one rolling branch.
  - **A failed combined update retries without the breaking changes**, so a bad week still lands the rest.
  - **Checks passed ⇒ ready for review; anything else ⇒ draft.** There are no checks on the PR itself to read, so draft-vs-ready *is* the signal.
  - **The `gate` job makes the run red when a verification failed** — the Verify steps are `continue-on-error` by design, and before the gate a week where every tier failed and no PR was opened still reported green.
  - Hold lists live in the workflow's `env:` with reasons; held packages are still *reported*, so a hold can't quietly become permanent.
  - **The iOS job runs the *release* build, byte for byte what `ios-release.yml` runs.** It was `--debug` for four never-executed runs: nobody here can make a debug iOS build, Debug is the only configuration pulling `RunnerDebug.entitlements`, and no AOT means gen_snapshot failures sail through.
  - Needs Settings → Actions → "Allow GitHub Actions to create and approve pull requests".

### iOS build gotchas

- **"Requires a selected Development Team" on a `--no-codesign` build is not about signing, and the real error is not in the log.** Flutter passes xcodebuild `-quiet` and on failure prints a diagnosis; with no parsed `.xcresult` issues it takes the `noDevelopmentTeamInstruction` branch, which sets `issueDetected` and skips the one thing that would dump stdout. Both iOS workflows carry a **`Show the real Xcode error`** step that re-runs with `-v`. Read that step, never the signing block.
- **The first thing it caught**: `--no-codesign` collides with Square's setup phase. Hoisting the nested frameworks is half of what `setup` does — it also re-signs each one, and an unsigned build runs `codesign --force --sign ''` and exits non-zero. `ios/Podfile` skips the phase when `CODE_SIGNING_ALLOWED=NO`.
- **The Square setup phase must be the last build phase**, added from `post_integrate` (not `post_install`, not the pbxproj) or it lands before "[CP] Embed Pods Frameworks", no-ops, and the App Store rejection (ITMS-90035/90205/90206) comes back looking identical.
- **The archive is ad-hoc signed on purpose** (`CODE_SIGN_IDENTITY=-`); the export applies the real signature. Under automatic signing xcodebuild resolves the archive's profile from the identity, and every value it accepts is a *development* one, which needs a registered device.

### Android build gotchas

- **AGP is held below 9.x, and that keeps the payments SDK current.** AGP 9.0 removed `targetSdk` from the *library* DSL, which `square_mobile_payments_sdk` still sets, so every AGP 9 build dies configuring the payments plugin. Pinning the plugin back instead would drag the iOS pod to `~> 2.5.0` (Android has an app-side override, iOS has nothing).
- **Holding AGP on 8.x also caps the Gradle wrapper at 9.5.x.** Gradle 9.6 removed an internal API AGP 8.x calls, so 8.13.2 + wrapper 9.7.0 couldn't even *apply* `com.android.application`. Usable window 8.13 … 9.5.x; both ceilings lift together.
- Flutter 3.44.1 only knows AGP ≤ 9.1 and KGP ≤ 2.3.20.
- Bytecode target is Java 17; `android-release.yml` runs Gradle under **JDK 21** (AGP 9's lint crashes under 17 on a JDK-21-only default method). `minSdk` is **28** (Square floor).
- **No CI job runs R8, so a release-only failure is invisible until the manual release.** The Square 2.5.0 → 2.6.0 bump sat green three weeks then failed `minifyProdReleaseWithR8`: `mobile-payments-sdk-internals` declares SQLDelight's **JVM** driver at compile scope, putting `java.sql.JDBCType` and `org.slf4j` on an Android classpath, and **R8 treats a missing class as an error**. Hence the `-dontwarn` block; none of it is reachable at runtime. That jar also ships desktop JNI binaries as java resources and AGP drops `.so` but not `.dll`/`.dylib` — hence `excludes += "org/sqlite/native/**"`.
- **Release artifacts are retained for 1 day** — this is a public repo, so any run's artifacts are downloadable by anyone.
- **Release signing** is wired in CI; local `flutter build --release` falls back to debug signing without your own `android/key.properties`.

## What's not done

- **Backend tests** alongside new mobile endpoints.
- **`notifications/prefs/`** (Part N) — blocks the notification opt-in writing its toggles.
- **Printer onboarding backend** (Parts T/U/V/X/Y): the `tspl-raster` seed row, `probe_replies`/`probed_language` + a `probe` choice for `matched_by`, `command_language`, a `/printing/` button reaching the native sheet *while connected*, v2 validator changes, characterization fields.
- **Remote print backend** (Part R1–R6).
- **AR island detection/merging.**
- **Check-in**: the `promote_this_auction` filter (Part CHECKIN-1); and the app half is untested — no `checkin_service_test.dart` at all.
- **Tap to Pay**: the publishing entitlement (Apple's), Part TTP-7 (callback redirect), Part TTP-8 (settled-invoice gate).
- **Recruit volunteers** (Part 7) — entirely web/backend.
- **Voice set-winners has never completed a real session on hardware.** Two iOS defects that would have ended one were fixed 2026-09-03 (stale callbacks, audio session) — still unproven, but for better reasons than before.
- **`BACKEND_SPEC.md` is cleared after each round of backend changes**, so "Part X" references here may point at a section that already shipped and was removed.
