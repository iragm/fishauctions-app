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
    teardown(deactivateSession: false)
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
      emit(["type": "error", "code": "error_language_unavailable"])
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
      result(nil)
      return
    }

    let input = audioEngine.inputNode
    // The node's own format, never a hand-rolled one: a mismatch here is the classic
    // "required condition is false: format.sampleRate == hwFormat.sampleRate" crash.
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.request?.append(buffer)
      self?.emitLevel(from: buffer)
    }

    task = recognizer.recognitionTask(with: request) { [weak self] response, error in
      self?.handle(response: response, error: error)
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

  private func handle(response: SFSpeechRecognitionResult?, error: Error?) {
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
        // The status is what drives Dart's end-of-utterance, and it has to follow the words: the
        // base class flushes anything still pending when a phrase ends, so a status arriving
        // first would promote the last partial and leave the real final for the next utterance.
        emit(["type": "status", "listening": false])
      }
      return
    }
    guard let error = error as NSError? else { return }
    teardown()
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
  }

  /// Release the recognizer and the audio graph.
  ///
  /// [deactivateSession] is false when another utterance is about to start, which is most of them:
  /// a continuous session re-arms every few seconds, and deactivating the audio session only to
  /// reactivate it 350 ms later costs the first fraction of a second of every phrase — the part
  /// carrying the anchor keyword the whole grammar hangs on. Handing the session back matters when
  /// the operator has finished, not between two words.
  private func teardown(deactivateSession: Bool = true) {
    audioEngine.inputNode.removeTap(onBus: 0)
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    task?.finish()
    task = nil
    request = nil
    recognizer = nil
    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    }
  }

  /// RMS of the buffer, normalized to 0..1 — Android reports a dB figure and iOS reports nothing
  /// at all, so both native sides normalize here rather than leaving Dart to know which platform
  /// it is on. The meter only ever answers "is it hearing me".
  private func emitLevel(from buffer: AVAudioPCMBuffer) {
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
    emit(["type": "level", "level": Double(level)])
  }

  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(payload)
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
