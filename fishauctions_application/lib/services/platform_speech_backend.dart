import 'dart:async';

import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

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

  /// How long a pause ends an utterance. Long enough to say "twenty five
  /// dollars" without being cut in half; short enough that a command lands
  /// while the operator is still looking at the screen.
  static const Duration _pauseFor = Duration(seconds: 3);

  final SpeechToText _speech;
  final _events = StreamController<SpeechEvent>.broadcast();

  bool _initialized = false;
  bool _wantListening = false;
  bool _restartScheduled = false;
  bool _needsPermission = false;
  bool _onDevice = false;
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

  @override
  Future<bool> available() async {
    final ready = await _ensureInitialized();
    if (!ready) {
      return false;
    }
    // Deliberately re-read rather than trusting the init-time answer: the
    // microphone can be revoked from Settings while the app is backgrounded,
    // which at an auction means it happened between two lots.
    _needsPermission = !await Permission.microphone.isGranted;
    return true;
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
      _log.w('Speech initialize failed: $e');
      _initialized = false;
    }
    if (!_initialized) {
      // initialize() collapses "no recognition service" and "permission
      // refused" into a single false. They need different messages, so ask
      // the permission layer which one it was.
      _needsPermission = !await Permission.microphone.isGranted;
    }
    return _initialized;
  }

  @override
  Future<void> start(SpeechSessionOptions options) async {
    _options = options;
    if (!await _ensureInitialized()) {
      _events.add(
        SpeechEvent.error(
          _needsPermission
              ? SpeechErrorKind.permission
              : SpeechErrorKind.unavailable,
          _needsPermission
              ? 'Microphone access is off for this app.'
              : 'This device has no speech recognition available.',
        ),
      );
      return;
    }
    _wantListening = true;
    await _listen();
  }

  Future<void> _listen() async {
    if (!_wantListening || _speech.isListening) {
      return;
    }
    try {
      _onDevice = _options.preferOnDevice;
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
          pauseFor: _pauseFor,
          localeId: _options.localeId,
          onDevice: _options.preferOnDevice,
          listenMode: ListenMode.dictation,
        ),
      );
      _events.add(const SpeechEvent.state(listening: true));
    } on Object catch (e) {
      _log.w('Speech listen failed: $e');
      _restartSoon(after: _errorBackoff);
    }
  }

  void _onResult(SpeechRecognitionResult result) {
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
    // 'notListening' / 'done' — the utterance ended. That's normal; re-arm.
    if (_wantListening) {
      _restartSoon();
    } else {
      _events.add(const SpeechEvent.state(listening: false));
    }
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
        _restartSoon();
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
    _log.w('Speech error: ${error.errorMsg} (permanent: ${error.permanent})');
    if (kind == SpeechErrorKind.permission || error.permanent) {
      _wantListening = false;
      _events.add(SpeechEvent.error(kind, _messageFor(kind, error.errorMsg)));
      return;
    }
    _events.add(SpeechEvent.error(kind, _messageFor(kind, error.errorMsg)));
    _restartSoon(after: _errorBackoff);
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
