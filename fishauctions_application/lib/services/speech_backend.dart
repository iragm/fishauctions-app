import 'voice_parser.dart';

/// Why a speech session stopped or failed, in terms the UI can act on.
enum SpeechErrorKind {
  /// The microphone (or, on iOS, speech recognition) was refused.
  permission,

  /// No recognition service on the device at all.
  unavailable,

  /// Network-backed recognition couldn't reach the server.
  network,

  /// Anything else — reported with the platform's own message.
  unknown,
}

enum SpeechEventType { state, level, partial, result, error }

/// Everything a backend can tell the session owner.
class SpeechEvent {
  const SpeechEvent.state({required this.listening})
    : type = SpeechEventType.state,
      alternates = const [],
      level = null,
      errorKind = null,
      message = '';

  const SpeechEvent.level(double this.level)
    : type = SpeechEventType.level,
      alternates = const [],
      listening = true,
      errorKind = null,
      message = '';

  const SpeechEvent.partial(this.alternates)
    : type = SpeechEventType.partial,
      level = null,
      listening = true,
      errorKind = null,
      message = '';

  const SpeechEvent.result(this.alternates)
    : type = SpeechEventType.result,
      level = null,
      listening = true,
      errorKind = null,
      message = '';

  const SpeechEvent.error(SpeechErrorKind this.errorKind, this.message)
    : type = SpeechEventType.error,
      alternates = const [],
      level = null,
      listening = false;

  final SpeechEventType type;

  /// n-best transcriptions, best first. Populated for
  /// [SpeechEventType.partial] and [SpeechEventType.result].
  final List<SpeechHypothesis> alternates;

  /// 0..1 microphone level, for the meter.
  final double? level;

  final bool listening;
  final SpeechErrorKind? errorKind;
  final String message;

  String get bestText => alternates.isEmpty ? '' : alternates.first.text;
}

/// Options a session is started with. A backend applies what it can and
/// ignores the rest — [biasPhrases] in particular is honoured by the backends
/// that support phrase biasing and silently dropped by the ones that don't.
class SpeechSessionOptions {
  const SpeechSessionOptions({
    this.localeId = 'en_US',
    this.preferOnDevice = true,
    this.biasPhrases = const [],
  });

  final String localeId;
  final bool preferOnDevice;

  /// The identifiers that exist in this auction. Not used by the default
  /// backend — `speech_to_text` exposes neither iOS `contextualStrings` nor
  /// Android's biasing extras — but carried here so the `biased` and `cloud`
  /// backends need no signature change when they land.
  final List<String> biasPhrases;
}

/// The swappable half of voice recognition.
///
/// The default is the platform recognizer, which is free, needs no keys and
/// runs on-device. It is reached only through this interface so the named
/// upgrade paths — phrase biasing over a platform channel, cloud streaming
/// with keyword boost, a fixed-grammar spotter — are a new class rather than
/// a rewrite. Which one runs is a served config field. See `VOICE.md` §3.1.
abstract class SpeechBackend {
  /// Matches the `voice.backend` config value.
  String get id;

  /// Whether this device can run it at all: a recognition service exists and
  /// the permissions were granted. Called before every session, never cached
  /// — a user can revoke the microphone from Settings mid-auction.
  Future<bool> available();

  /// True when the last [available] call found a recognition service but the
  /// user hasn't granted permission yet, so callers can tell "this phone
  /// can't" from "this phone hasn't been asked".
  bool get needsPermission;

  /// Whether recognition is actually running locally. Only meaningful after
  /// [start]; platforms decide this themselves and may ignore the request.
  bool get isOnDevice;

  Stream<SpeechEvent> get events;

  /// Begin listening. Implementations own their own restart behaviour — the
  /// caller expects a session that lasts until [stop], not one utterance.
  Future<void> start(SpeechSessionOptions options);

  Future<void> stop();

  Future<void> dispose();
}
