import 'dart:async';

import 'package:logger/logger.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../utils/platform_bridge.dart';
import 'restarting_speech_backend.dart';
import 'speech_backend.dart';
import 'voice_parser.dart';

final _log = Logger();

/// Speech recognition through `speech_to_text` — `SFSpeechRecognizer` on iOS,
/// `android.speech.SpeechRecognizer` on Android.
///
/// The default backend: free, no keys, no per-deployment setup, and able to
/// run entirely on-device, which matters more here than it looks. An auction
/// hall's wifi is bad, and a network round trip is latency the operator feels
/// between saying a number and seeing it land.
///
/// **Everything hard about running a session lives in
/// [RestartingSpeechBackend]** — the re-arm loop, the two silence windows, the
/// on-device fallback, promoting a last partial. This class is only the
/// adapter: it maps the plugin's callbacks onto that base and translates its
/// `SpeechListenOptions`.
///
/// It cannot do phrase biasing, and that is structural rather than an
/// oversight — see [supportsPhraseBias]. `BiasedSpeechBackend` exists for that.
class PlatformSpeechBackend extends RestartingSpeechBackend {
  PlatformSpeechBackend({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  /// Re-arm well before iOS's own request cap so the seam falls in silence we
  /// chose rather than mid-word.
  static const Duration _listenFor = Duration(seconds: 50);

  final SpeechToText _speech;
  bool _initialized = false;

  @override
  String get id => 'platform';

  /// **False, and this is the one thing `speech_to_text` structurally cannot
  /// do.** `SpeechListenOptions` has a fixed set of fields with no extras
  /// passthrough, and the plugin's own native sides never touch
  /// `contextualStrings` or `EXTRA_BIASING_STRINGS` — its only extension point
  /// is `initialize(options:)`, which is per-process rather than per-listen and
  /// whose Android half reads exactly one name (`noBluetooth`).
  @override
  bool get supportsPhraseBias => false;

  @override
  bool get isUtteranceOpen => _speech.isListening;

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
  /// works. If the recognizer really is missing, `prepare` says so precisely,
  /// at the moment the user asked for it.
  @override
  Future<bool> isCapable() => PlatformBridge.speechRecognitionAvailable();

  @override
  Future<bool> ensureRecognizer() async {
    if (_initialized) {
      return true;
    }
    try {
      // With the permission already held (the base class asked first),
      // initialize() takes the "has permission, completing" path: no dialog,
      // and its answer is now really about the recognizer.
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
  Future<void> openUtterance({
    required SpeechSessionOptions options,
    required bool onDevice,
    required Duration pauseFor,
  }) => _speech.listen(
    onResult: _onResult,
    onSoundLevelChange: _onSoundLevel,
    listenOptions: SpeechListenOptions(
      listenFor: _listenFor,
      // The plugin runs one pause clock, started at `listen()` and pushed
      // forward only by a *result* — sound level doesn't touch it. So this is
      // the long window, and [narrowPause] swaps it once words arrive.
      pauseFor: pauseFor,
      localeId: options.localeId,
      onDevice: onDevice,
      listenMode: ListenMode.dictation,
    ),
    // Two package defaults are load-bearing and so left unset rather than
    // restated: `partialResults` stays on (the transcript line and the level
    // meter are the only proof the microphone is alive), and `cancelOnError`
    // stays off — a no-match must not end the session, since a phrase that
    // wasn't a command is most of what a microphone in an auction hall hears.
  );

  @override
  Future<void> closeUtterance() => _speech.stop();

  /// `changePauseFor` exists in the plugin for precisely this ("allowing a long
  /// first pause then dynamically shortening it once the user starts
  /// speaking") and restarts the clock at the full new duration, after which
  /// every further result pushes it out again.
  ///
  /// Android keeps the long `EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS`
  /// from the intent this listen was armed with; harmless, because the
  /// shortened Dart timer now gets there first and stopping is what asks the
  /// platform for its final result.
  @override
  void narrowPause(Duration pauseFor) => _speech.changePauseFor(pauseFor);

  void _onResult(SpeechRecognitionResult result) => reportResult([
    for (final words in result.alternates)
      SpeechHypothesis(
        words.recognizedWords,
        confidence: words.hasConfidenceRating ? words.confidence : -1,
      ),
  ], isFinal: result.finalResult);

  /// Platform sound levels are not on a shared scale — Android reports an RMS
  /// in roughly -2..10 dB, iOS a normalized-ish figure — and the meter only
  /// needs to answer "is it hearing me". Clamp both into 0..1 and don't
  /// pretend it's calibrated.
  void _onSoundLevel(double level) => reportLevel((level + 2) / 12);

  void _onStatus(String status) {
    if (status == SpeechToText.listeningStatus) {
      return;
    }
    // 'notListening' / 'done' — the utterance ended.
    reportUtteranceClosed();
  }

  void _onError(SpeechRecognitionError error) =>
      reportPlatformError(error.errorMsg);
}
