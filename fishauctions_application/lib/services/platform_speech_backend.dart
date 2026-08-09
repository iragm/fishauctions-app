import 'dart:async';
import 'dart:io' show Platform;

import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../utils/platform_bridge.dart';
import 'speech_backend.dart';
import 'voice_parser.dart';

final _log = Logger();

/// Speech recognition through the OS — `SFSpeechRecognizer` on iOS,
/// `android.speech.SpeechRecognizer` on Android, via `speech_to_text`.
///
/// The default backend: free, no keys, no per-deployment setup, and able to
/// run entirely on-device, which matters more here than it looks. An auction
/// hall's wifi is bad, and a network round trip is latency the operator feels
/// between saying a number and seeing it land.
///
/// **This class exists mostly to make a per-utterance API behave like a
/// session.** `speech_to_text` says outright that it targets "commands and
/// short phrases, not continuous spoken conversion": Android's recognizer ends
/// after each utterance and iOS caps a request at about a minute. Selling an
/// auction is half an hour of talking, so [_restartSoon] keeps re-arming until
/// [stop], and end-of-utterance conditions that the platform reports as errors
/// (`error_no_match`, `error_speech_timeout`) are treated as the normal end of
/// a phrase rather than as failures.
///
/// A caller that wants the opposite — one sentence, then hand it back — asks
/// for it with [SpeechSessionOptions.continuous]; [_endOfUtterance] is where
/// the two part company, and its doc says why the choice has to be made here.
class PlatformSpeechBackend implements SpeechBackend {
  PlatformSpeechBackend({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  /// Android throws `ERROR_RECOGNIZER_BUSY` when `listen` follows a stop too
  /// closely, and the failure looks exactly like a dead microphone from the
  /// outside. Anything under about a quarter second is unreliable in practice.
  static const Duration _restartDelay = Duration(milliseconds: 350);

  /// After a genuine error, back off instead of hammering the service.
  static const Duration _errorBackoff = Duration(seconds: 2);

  /// Re-arm well before iOS's own request cap so the seam falls in silence we
  /// chose rather than mid-word.
  static const Duration _listenFor = Duration(seconds: 50);

  /// How many failures in a row end a continuous session. One is too few —
  /// a recognizer that hiccups mid-auction should recover by itself — and
  /// unlimited is a microphone that stays lit while nothing works.
  static const int _maxConsecutiveFailures = 3;

  final SpeechToText _speech;
  final _events = StreamController<SpeechEvent>.broadcast();

  bool _initialized = false;
  bool _wantListening = false;
  bool _restartScheduled = false;
  bool _needsPermission = false;
  bool _onDevice = false;

  /// Set once on-device recognition has been tried and failed, and never
  /// cleared: a missing language pack doesn't arrive mid-session, and this
  /// object is shared by both features, so paying the failed attempt once per
  /// process is right. Downloading the pack takes effect on the next launch.
  bool _onDeviceUnavailable = false;
  int _consecutiveFailures = 0;
  Timer? _restartTimer;
  SpeechSessionOptions _options = const SpeechSessionOptions();

  @override
  String get id => 'platform';

  @override
  bool get needsPermission => _needsPermission;

  @override
  bool get isOnDevice => _onDevice;

  @override
  Stream<SpeechEvent> get events => _events.stream;

  /// Whether the phone has a recognition service — asked of the OS directly,
  /// never of `speech_to_text`.
  ///
  /// **`SpeechToText.initialize()` cannot answer this question**, which is the
  /// bug this method exists to fix. On Android it *requests* `RECORD_AUDIO`
  /// (and `BLUETOOTH_CONNECT`) and then returns whether that permission is
  /// held — so calling it from `voiceGetState` popped a permission dialog the
  /// instant the set-winners page loaded, and answered `supported: false` on
  /// every phone that hadn't already granted the microphone. A phone that has
  /// never been asked is not a phone that can't.
  ///
  /// Optimistic on a channel error or a platform that doesn't implement the
  /// check: the failure we care about is hiding the button on hardware that
  /// works. If the recognizer really is missing, [prepare] says so precisely,
  /// at the moment the user asked for it.
  @override
  Future<bool> isCapable() => PlatformBridge.speechRecognitionAvailable();

  @override
  Future<bool> hasPermission() async {
    try {
      return await Permission.microphone.isGranted;
    } on Object catch (e) {
      _log.w('Microphone permission check failed: $e');
      return false;
    }
  }

  @override
  Future<SpeechReadiness> prepare() async {
    // Ask for the microphone ourselves, before speech_to_text can. Its
    // initialize() would otherwise raise the dialog at a time of its choosing
    // (see isCapable), and it collapses "refused" and "no recognizer" into one
    // false — two states that need different messages.
    //
    // iOS needs two grants, not one: SFSpeechRecognizer's own authorization is
    // separate from the microphone's, and it traps on first use without it.
    // Both are asked here so the pair arrives together, on the tap, rather
    // than the second one appearing from inside initialize().
    for (final permission in [
      Permission.microphone,
      if (Platform.isIOS) Permission.speech,
    ]) {
      final status = await _request(permission);
      _needsPermission = !status.isGranted;
      if (!status.isGranted) {
        return status.isPermanentlyDenied || status.isRestricted
            ? SpeechReadiness.deniedForever
            : SpeechReadiness.denied;
      }
    }
    // With the permission already held, initialize() takes the "has
    // permission, completing" path: no dialog, and its answer is now really
    // about the recognizer.
    return await _ensureInitialized()
        ? SpeechReadiness.ready
        : SpeechReadiness.unavailable;
  }

  Future<PermissionStatus> _request(Permission permission) async {
    try {
      final current = await permission.status;
      // A permanent denial must not be re-requested: the OS returns denied
      // without showing anything, so the user sees a button that does nothing
      // rather than a message telling them where the switch is.
      if (current.isGranted ||
          current.isPermanentlyDenied ||
          current.isRestricted) {
        return current;
      }
      return await permission.request();
    } on Object catch (e) {
      _log.w('Permission request for $permission failed: $e');
      return PermissionStatus.denied;
    }
  }

  Future<bool> _ensureInitialized() async {
    if (_initialized) {
      return true;
    }
    try {
      _initialized = await _speech.initialize(
        onError: _onError,
        onStatus: _onStatus,
      );
    } on Object catch (e) {
      // Thrown rather than returned when the platform reports
      // `recognizerNotAvailable`.
      _log.w('Speech initialize failed: $e');
      _initialized = false;
    }
    return _initialized;
  }

  @override
  Future<void> start(SpeechSessionOptions options) async {
    _options = options;
    final readiness = await prepare();
    if (readiness != SpeechReadiness.ready) {
      _events.add(SpeechEvent.error(readiness.errorKind, readiness.message));
      return;
    }
    _consecutiveFailures = 0;
    _wantListening = true;
    await _listen();
  }

  /// The session's [SpeechSessionOptions.pauseFor], nudged by a millisecond
  /// once we've fallen back to network recognition — a workaround for the
  /// plugin, not a tuning knob.
  ///
  /// Its Android side rebuilds the recognizer `Intent` only when the language
  /// tag, partial-results flag, listen mode or pause length changes;
  /// `onDevice` is not on that list, and it is what puts
  /// `EXTRA_PREFER_OFFLINE` on the intent. So a fallback attempt inherits the
  /// flag from the on-device attempt that just failed and fails the same way —
  /// on any phone whose system locale differs from the voice config's, which
  /// is the case where the flag gets set at all. Changing the pause forces the
  /// rebuild; a millisecond is not observable anywhere else.
  Duration get _pauseForNow => _onDeviceUnavailable
      ? _options.pauseFor + const Duration(milliseconds: 1)
      : _options.pauseFor;

  Future<void> _listen() async {
    if (!_wantListening || _speech.isListening) {
      return;
    }
    try {
      _onDevice = _options.preferOnDevice && !_onDeviceUnavailable;
      // Two package defaults are load-bearing and so left unset rather than
      // restated: `partialResults` stays on (the transcript line and the
      // level meter are the only proof the microphone is alive), and
      // `cancelOnError` stays off — a no-match must not end the session,
      // since a phrase that wasn't a command is most of what a microphone in
      // an auction hall hears.
      await _speech.listen(
        onResult: _onResult,
        onSoundLevelChange: _onSoundLevel,
        listenOptions: SpeechListenOptions(
          listenFor: _listenFor,
          pauseFor: _pauseForNow,
          localeId: _options.localeId,
          onDevice: _onDevice,
          listenMode: ListenMode.dictation,
        ),
      );
      _events.add(const SpeechEvent.state(listening: true));
    } on Object catch (e) {
      _log.w('Speech listen failed: $e');
      if (!_options.continuous) {
        _fail(
          SpeechErrorKind.unknown,
          'The microphone didn\'t start. Try again.',
        );
        return;
      }
      _restartSoon(after: _errorBackoff);
    }
  }

  void _onResult(SpeechRecognitionResult result) {
    // Words came back, so whatever went wrong before is behind us.
    _consecutiveFailures = 0;
    final alternates = [
      for (final words in result.alternates)
        if (words.recognizedWords.trim().isNotEmpty)
          SpeechHypothesis(
            words.recognizedWords,
            confidence: words.hasConfidenceRating ? words.confidence : -1,
          ),
    ];
    if (alternates.isEmpty) {
      return;
    }
    _events.add(
      result.finalResult
          ? SpeechEvent.result(alternates)
          : SpeechEvent.partial(alternates),
    );
  }

  /// Platform sound levels are not on a shared scale — Android reports an RMS
  /// in roughly -2..10 dB, iOS a normalized-ish figure — and the meter only
  /// needs to answer "is it hearing me". Clamp both into 0..1 and don't
  /// pretend it's calibrated.
  void _onSoundLevel(double level) {
    final normalized = ((level + 2) / 12).clamp(0.0, 1.0);
    _events.add(SpeechEvent.level(normalized));
  }

  void _onStatus(String status) {
    if (status == SpeechToText.listeningStatus) {
      return;
    }
    // 'notListening' / 'done' — the utterance ended.
    if (!_wantListening) {
      _events.add(const SpeechEvent.state(listening: false));
      return;
    }
    _endOfUtterance();
  }

  /// The recognizer finished a phrase, however it finished. A continuous
  /// session re-arms; a one-shot one is over, and says so.
  ///
  /// Everything that ends a phrase routes through here rather than each caller
  /// deciding, because they don't all look alike: a final result, three
  /// seconds of silence, a no-match on a cough, the platform simply reporting
  /// `notListening`. Only the first of those produces a transcript, so a
  /// caller trying to close its own session on the transcript alone stays open
  /// on the rest.
  void _endOfUtterance() {
    if (_options.continuous) {
      _restartSoon();
      return;
    }
    _wantListening = false;
    _restartTimer?.cancel();
    _restartScheduled = false;
    _events.add(const SpeechEvent.state(listening: false));
  }

  void _onError(SpeechRecognitionError error) {
    // These two are how the platforms say "the speaker stopped talking", not
    // that anything went wrong. Treating them as failures is what makes naive
    // continuous listening die after the first silence.
    const benign = {
      'error_no_match',
      'error_speech_timeout',
      'error_retry',
      'error_busy',
    };
    if (benign.contains(error.errorMsg)) {
      if (_wantListening) {
        _endOfUtterance();
      }
      return;
    }
    final kind = switch (error.errorMsg) {
      'error_permission' ||
      'error_insufficient_permissions' => SpeechErrorKind.permission,
      'error_network' || 'error_network_timeout' => SpeechErrorKind.network,
      'error_language_not_supported' ||
      'error_language_unavailable' => SpeechErrorKind.unavailable,
      _ => SpeechErrorKind.unknown,
    };
    // `permanent` is deliberately not consulted. Android's plugin sets it on
    // *every* error it forwards — `speechError.put("permanent", true)`, with
    // nothing behind the value — so trusting it ends the session on the first
    // hiccup of a half-hour auction. What actually can't be retried is decided
    // below, from the error itself.
    _log.w('Speech error: ${error.errorMsg}');
    if (kind == SpeechErrorKind.permission) {
      _fail(kind, _messageFor(kind, error.errorMsg));
      return;
    }
    // The one failure with a known cure, and the reason voice set-winners
    // reported "no speech recognition available" on a phone whose microphone
    // demonstrably worked: on-device recognition was asked for (an auction
    // hall's wifi is bad, so it's the default) and this phone has the
    // recognition service without the downloaded language pack. Android
    // answers that with ERROR_LANGUAGE_UNAVAILABLE — and the plugin's own
    // availability check passes, because the *service* is there. Network
    // recognition works on the same phone in the same breath, which is why
    // palette dictation was fine while set-winners was not.
    if (_onDevice && !_onDeviceUnavailable) {
      _onDeviceUnavailable = true;
      _onDevice = false;
      _log.i(
        'On-device recognition failed (${error.errorMsg}); '
        'using network recognition from here on',
      );
      _restartSoon();
      return;
    }
    _consecutiveFailures++;
    if (!_options.continuous ||
        _consecutiveFailures >= _maxConsecutiveFailures) {
      _fail(kind, _messageFor(kind, error.errorMsg));
      return;
    }
    // Not reported to the page: a transient failure that the next re-arm fixes
    // two seconds later isn't news, and putting it on screen means the button
    // resets itself while the microphone is in fact still coming back.
    _restartSoon(after: _errorBackoff);
  }

  /// End the session and tell the caller why. The only exit that carries a
  /// message — everything else is an utterance ending, which is not a failure.
  void _fail(SpeechErrorKind kind, String message) {
    _wantListening = false;
    _restartTimer?.cancel();
    _restartScheduled = false;
    _events.add(SpeechEvent.error(kind, message));
  }

  String _messageFor(SpeechErrorKind kind, String raw) => switch (kind) {
    SpeechErrorKind.permission =>
      'Microphone access is off for this app, so voice control can\'t start.',
    SpeechErrorKind.network =>
      'Speech recognition lost its connection. On-device recognition avoids '
          'this — check the language pack is downloaded.',
    SpeechErrorKind.unavailable =>
      'Speech recognition isn\'t available for this language on this device.',
    SpeechErrorKind.unknown => 'Voice control stopped: $raw',
  };

  void _restartSoon({Duration after = _restartDelay}) {
    if (_restartScheduled || !_wantListening) {
      return;
    }
    _restartScheduled = true;
    _restartTimer?.cancel();
    _restartTimer = Timer(after, () async {
      _restartScheduled = false;
      await _listen();
    });
  }

  @override
  Future<void> stop() async {
    _wantListening = false;
    _restartTimer?.cancel();
    _restartScheduled = false;
    try {
      await _speech.stop();
    } on Object catch (e) {
      _log.w('Speech stop failed: $e');
    }
    _events.add(const SpeechEvent.state(listening: false));
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}
