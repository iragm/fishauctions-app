import AVFoundation
import Flutter
import Speech

/// `SFSpeechRecognizer`, driven directly, so that the auction's own lot and bidder numbers can be
/// handed to it as `contextualStrings`.
///
/// That property is the entire reason this file exists. `speech_to_text` — otherwise a perfectly
/// good wrapper, and still the default backend — never sets it and has no extension point that
/// could. Without it, a club whose bidder numbers are initials ("NM", "BOB") is asking a
/// general-purpose dictation model for strings it has essentially no prior for.
///
/// **Scope: one utterance.** Sessions, re-arming, the two silence windows, the on-device fallback
/// and promoting a last partial all live in Dart (`RestartingSpeechBackend`), because that logic
/// is identical on both platforms and has already been wrong three times. This side starts a
/// recognition task, forwards what it says, and stops.
///
/// **Error codes are `speech_to_text`'s strings on purpose** (`error_no_match`,
/// `error_network`, …) so Dart classifies errors in exactly one place for both platforms and both
/// backends.
///
/// Authorization is deliberately *not* requested here. The Dart side asks for the microphone and
/// speech permissions together, on the user's tap, before it ever calls `start` — the same rule
/// that keeps a permission dialog off the set-winners page's load.
final class BiasedSpeechBridge: NSObject {
  private let audioEngine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var sink: FlutterEventSink?

  /// Identity of the utterance in flight, and the only one whose callbacks count.
  ///
  /// **`SFSpeechRecognitionTask.finish()` does not stop the callbacks — it asks for them.** It
  /// requests the final result, which arrives asynchronously, and a cancelled task reports its
  /// cancellation the same way. `start` tears the previous utterance down before building the next
  /// one, so those late callbacks land *after* the successor's task is already installed. Without
  /// an identity check the predecessor's final either emits a stale transcript attributed to the
  /// new utterance, or takes the `error` path and runs `teardown()` — killing the audio engine and
  /// recognition task of the phrase now being spoken. From the operator's side the microphone
  /// simply dies mid-session.
  ///
  /// Android has had this guard from the start (`speech/BiasedSpeechBridge.kt`, `isCurrent`,
  /// checked in five callbacks). This is the same rule: a `UInt64` rather than object identity
  /// only because there is no per-utterance object here to compare.
  ///
  /// [liveUtterance] is nil whenever nothing is in flight — set by `start`, cleared by `teardown`
  /// and by every terminal event — so a callback arriving after a phrase has properly ended is
  /// dropped too, exactly as Android's `finish()` (which nils `current`) does.
  private var nextUtteranceId: UInt64 = 0
  private var liveUtterance: UInt64?

  /// Deferred hand-back of the audio session; see [scheduleSessionRelease].
  private var sessionReleaseTimer: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "com.fishauctions.app/speech", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
    FlutterEventChannel(name: "com.fishauctions.app/speech_events", binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      // supportedLocales rather than a recognizer for the current locale: the recognition locale
      // comes from the served voice config (en_US by default), not from the phone's region.
      result(
        SFSpeechRecognizer.authorizationStatus() != .restricted
          && !SFSpeechRecognizer.supportedLocales().isEmpty
      )
    case "supportsBias":
      // `contextualStrings` has been on SFSpeechRecognitionRequest since iOS 10, well below this
      // app's deployment target — so unlike Android (where the extra is API 33 and minSdk is 28)
      // there is no version to check.
      result(true)
    case "start":
      let arguments = call.arguments as? [String: Any]
      start(
        locale: arguments?["localeId"] as? String ?? "en-US",
        onDevice: arguments?["onDevice"] as? Bool ?? false,
        biasPhrases: arguments?["biasPhrases"] as? [String] ?? [],
        result: result
      )
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(
    locale: String,
    onDevice: Bool,
    biasPhrases: [String],
    result: @escaping FlutterResult
  ) {
    // A new phrase is starting, so the audio session is still wanted. Cancel before teardown:
    // teardown arms nothing, but the *previous* phrase's terminal event did.
    sessionReleaseTimer?.cancel()
    sessionReleaseTimer = nil
    teardown(deactivateSession: false)
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
      emit(["type": "error", "code": "error_language_unavailable"])
      scheduleSessionRelease()
      result(nil)
      return
    }
    // `isAvailable` is deliberately *not* a gate. It is KVO-backed and starts false while the
    // recognition service connects, so the first listen of a session — the one the user just
    // tapped for — routinely arrives before it flips true. Reporting that as
    // `error_language_unavailable` is a hard failure on the Dart side, which retires on-device
    // recognition and then ends the session, on a phone whose recognizer works perfectly two
    // seconds later. `error_busy` is in the base class's benign set: it re-arms, and by the next
    // attempt the service is up. A recognizer that really never becomes available fails again
    // with a real code the moment the task starts.
    guard recognizer.isAvailable else {
      emit(["type": "error", "code": "error_busy"])
      scheduleSessionRelease()
      result(nil)
      return
    }
    self.recognizer = recognizer

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // The point of the whole file.
    request.contextualStrings = biasPhrases
    // Asked for, not assumed: a phone can report on-device support and still lack the downloaded
    // asset for this locale. Dart's own fallback handles the failure — once, silently, for the
    // rest of the process.
    if onDevice, recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    self.request = request

    // Claim this utterance. Everything below captures `utterance` and reports nothing unless it is
    // still the live one — see [liveUtterance].
    nextUtteranceId &+= 1
    let utterance = nextUtteranceId
    liveUtterance = utterance

    do {
      let session = AVAudioSession.sharedInstance()
      // `.measurement` disables the system's own signal processing, which is what you want in
      // front of a recognizer.
      //
      // **No `.duckOthers`.** Apple permits that option only on `playAndRecord`, `playback` and
      // `multiRoute`; on `.record` `setCategory` rejects the call, and every failure here lands in
      // the `catch` below as `error_audio_error` — a hard error that ends the session before the
      // audio engine has been started at all. It also bought nothing: `.record` already interrupts
      // other audio. Kept as one call with a plain retry so an option list can never silently cost
      // us the microphone again.
      try session.setCategory(.record, mode: .measurement)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      emit(["type": "error", "code": "error_audio_error", "detail": "\(error)"])
      scheduleSessionRelease()
      result(nil)
      return
    }

    let input = audioEngine.inputNode
    // The node's own format, never a hand-rolled one: a mismatch here is the classic
    // "required condition is false: format.sampleRate == hwFormat.sampleRate" crash.
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    // `request` is captured, never read back off `self`. This block runs on the audio render
    // thread while `self.request` is replaced on the main one: `removeTap` is synchronous, but a
    // buffer already dispatched here still runs after it, and appending that to the *new* request
    // feeds the previous phrase's audio into the current one. A mis-transcription, not a crash,
    // and nothing about it would ever point back to this line. Appending to its own request is
    // harmless — that request's task is already finished.
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      request.append(buffer)
      self?.emitLevel(from: buffer, utterance: utterance)
    }

    // Hopped to the main queue because `SFSpeechRecognizer` calls this handler on an arbitrary
    // one, and everything it touches — the identity, the task, the request, the audio graph — is
    // owned by the main thread. Android's callbacks arrive on the main looper already, which is
    // why its guard needs no equivalent.
    task = recognizer.recognitionTask(with: request) { [weak self] response, error in
      DispatchQueue.main.async {
        self?.handle(response: response, error: error, utterance: utterance)
      }
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
      emit(["type": "status", "listening": true])
    } catch {
      teardown()
      emit(["type": "error", "code": "error_audio_error"])
    }
    result(nil)
  }

  private func handle(
    response: SFSpeechRecognitionResult?, error: Error?, utterance: UInt64
  ) {
    // A predecessor's late final, or a cancellation report from a task torn down by `start`. Both
    // are routine — `finish()` asks for exactly this — and both must not touch the phrase now in
    // flight. Android drops them the same way.
    guard liveUtterance == utterance else { return }
    if let response {
      emit([
        "type": "result",
        "final": response.isFinal,
        // n-best, best first. Confidence is per-segment on iOS and routinely 0 for partials, so
        // -1 ("the platform didn't say") is the honest report — Dart's confidence model treats
        // that as neutral rather than as doubt, and computes its own score from three other
        // signals.
        "alternates": response.transcriptions.map {
          ["text": $0.formattedString, "confidence": -1.0]
        },
      ])
      if response.isFinal {
        teardown(deactivateSession: false)
        scheduleSessionRelease()
        // The status is what drives Dart's end-of-utterance, and it has to follow the words: the
        // base class flushes anything still pending when a phrase ends, so a status arriving
        // first would promote the last partial and leave the real final for the next utterance.
        emit(["type": "status", "listening": false])
      }
      return
    }
    guard let error = error as NSError? else { return }
    // Deactivating here would be wrong for the same reason it is wrong after a final: the session
    // backs off and re-arms after most errors, and handing the audio session back only to take it
    // again 2 s later costs the start of the next phrase. The deferred release covers the case
    // where nothing re-arms.
    teardown(deactivateSession: false)
    scheduleSessionRelease()
    emit(["type": "error", "code": Self.code(for: error)])
  }

  /// iOS reports end-of-speech conditions as errors from a private domain, and the codes are the
  /// only way to tell "nobody said anything" from "the network went away". Anything unrecognised
  /// is reported as a no-match rather than a failure: Dart treats a no-match as an ordinary end of
  /// phrase and re-arms, where a hard error after three in a row ends the session — and ending a
  /// half-hour auction on an error we couldn't identify is the worse mistake.
  private static func code(for error: NSError) -> String {
    switch error.code {
    case 203, 1110:  // no speech / no match
      return "error_no_match"
    case 1700:  // request cancelled by us
      return "error_no_match"
    case 209, 216:  // task cancelled mid-flight during teardown
      return "error_no_match"
    default:
      break
    }
    if error.domain == NSURLErrorDomain {
      return "error_network"
    }
    return "error_no_match"
  }

  /// Ask the recognizer to finish and deliver what it has.
  ///
  /// **Emits no status of its own, deliberately.** Stopping a recognizer *is* asking for its final
  /// result, and that result is the best transcript of the phrase — so the phrase ends when the
  /// result lands, not here. Reporting it over would make Dart flush a partial, re-arm, and take
  /// the real final as the start of the next utterance. A recognizer that answers with nothing at
  /// all is covered by the watchdog on the Dart side.
  ///
  /// `endAudio`, not `cancel`: cancelling throws the phrase away, which is the very bug
  /// `_flushPendingAsFinal` exists to work around.
  private func stop() {
    guard task != nil else { return }
    request?.endAudio()
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    // Also armed here, because the one path with no terminal event is a recognizer that is asked
    // to stop and never answers. Dart's 1.5 s watchdog ends the phrase on its side; nothing would
    // otherwise reach this file again, and the audio session would stay active in `.record` for
    // the rest of the process.
    scheduleSessionRelease()
  }

  /// Hand the audio session back once the operator has actually finished, rather than between two
  /// words.
  ///
  /// A continuous session re-arms roughly every 350 ms (`RestartingSpeechBackend.restartDelay`),
  /// and deactivating only to reactivate costs the first fraction of a second of the next phrase —
  /// the part carrying the anchor keyword the whole grammar hangs on. So the release is deferred
  /// and any `start` cancels it. The delay clears the longest legitimate gap, which is
  /// `errorBackoff` (2 s), with room to spare.
  ///
  /// It has to be *inferred* here rather than signalled from Dart. There is no "session over"
  /// message that could be sent safely: `RestartingSpeechBackend.stop()` returns as soon as
  /// `endAudio` is acknowledged, while the final transcript is still in flight, so tearing the task
  /// down on that signal would throw away the last thing the operator said — the exact bug
  /// `_flushPendingAsFinal` exists to work around.
  ///
  /// Left running, the session stays active in `.record`: the microphone indicator persists after
  /// the operator stops, and later in-app audio (a video in the WebView) plays silently until
  /// WebKit resets the category.
  private func scheduleSessionRelease() {
    sessionReleaseTimer?.cancel()
    // "Has a new phrase begun since this was scheduled?" — not "is a task still attached". The
    // case this exists for is precisely a task that is still attached because the recognizer was
    // asked to stop and never answered, so keying on the task would no-op exactly there.
    let scheduledAfter = nextUtteranceId
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.nextUtteranceId == scheduledAfter else { return }
      self.sessionReleaseTimer = nil
      // Full teardown, not a bare `setActive(false)`: this path also has to release the stuck task
      // and the audio graph. Its late callbacks are dropped, since teardown clears the identity.
      self.teardown()
    }
    sessionReleaseTimer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay, execute: work)
  }

  /// How long to wait for the next phrase before handing the audio session back. Clears the
  /// longest legitimate gap between two utterances, which is `RestartingSpeechBackend.errorBackoff`
  /// (2 s), with room to spare.
  private let releaseDelay: TimeInterval = 3

  /// Release the recognizer and the audio graph.
  ///
  /// [deactivateSession] is false when another utterance is about to start, which is most of them:
  /// a continuous session re-arms every few seconds, and deactivating the audio session only to
  /// reactivate it 350 ms later costs the first fraction of a second of every phrase — the part
  /// carrying the anchor keyword the whole grammar hangs on. Handing the session back matters when
  /// the operator has finished, not between two words.
  private func teardown(deactivateSession: Bool = true) {
    // Before anything else: from here on, callbacks from the task being finished below are stale
    // and must not be acted on.
    liveUtterance = nil
    audioEngine.inputNode.removeTap(onBus: 0)
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    task?.finish()
    task = nil
    request = nil
    recognizer = nil
    if deactivateSession {
      sessionReleaseTimer?.cancel()
      sessionReleaseTimer = nil
      try? AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    }
  }

  /// RMS of the buffer, normalized to 0..1 — Android reports a dB figure and iOS reports nothing
  /// at all, so both native sides normalize here rather than leaving Dart to know which platform
  /// it is on. The meter only ever answers "is it hearing me".
  private func emitLevel(from buffer: AVAudioPCMBuffer, utterance: UInt64) {
    guard let channel = buffer.floatChannelData?[0] else { return }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return }
    var sum: Float = 0
    for index in 0..<count {
      let sample = channel[index]
      sum += sample * sample
    }
    let rms = sqrt(sum / Float(count))
    // ~-50 dBFS is a quiet room and 0 is clipping; that range maps to a meter that moves.
    let db = 20 * log10(max(rms, 0.000_001))
    let level = max(0, min(1, (db + 50) / 50))
    emit(["type": "level", "level": Double(level)], utterance: utterance)
  }

  /// Forward a payload to Dart.
  ///
  /// [utterance], when given, drops the event unless that utterance is still the live one — and
  /// the check happens *inside* the main-queue hop, so the identity is only ever read on the
  /// thread that writes it. That is what makes the level meter safe to emit from the audio render
  /// thread.
  private func emit(_ payload: [String: Any], utterance: UInt64? = nil) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let utterance, self.liveUtterance != utterance { return }
      self.sink?(payload)
    }
  }
}

extension BiasedSpeechBridge: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
