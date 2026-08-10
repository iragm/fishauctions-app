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

/// The outcome of [SpeechBackend.prepare] — everything that has to happen
/// between the user asking for the microphone and the recognizer running.
enum SpeechReadiness {
  /// Permission held and the recognizer is up.
  ready,

  /// The user said no this time. Asking again is legitimate.
  denied,

  /// The OS won't ask again (Android "don't ask again", iOS after the first
  /// refusal). Only Settings can fix it, so the message has to say so.
  deniedForever,

  /// Permission is held but the recognizer still won't start — no recognition
  /// service, no language pack, a platform error.
  unavailable,
}

/// What to tell the user about a [SpeechReadiness] that isn't
/// [SpeechReadiness.ready]. One copy, because both the backend's own guard and
/// the session that drives it report the same failure.
extension SpeechReadinessMessage on SpeechReadiness {
  SpeechErrorKind get errorKind => this == SpeechReadiness.unavailable
      ? SpeechErrorKind.unavailable
      : SpeechErrorKind.permission;

  /// The wire code the page branches on. `permission_denied` is what its
  /// "Microphone blocked" toast keys off.
  String get errorCode => switch (this) {
    SpeechReadiness.ready => 'ready',
    SpeechReadiness.denied ||
    SpeechReadiness.deniedForever => 'permission_denied',
    SpeechReadiness.unavailable => 'unavailable',
  };

  String get message => switch (this) {
    SpeechReadiness.ready => '',
    // Distinguished because they need different actions from the user: one is
    // "tap again and say yes", the other can only be fixed in Settings, and
    // telling someone to tap again when the OS has stopped asking is how a
    // button becomes a dead control.
    SpeechReadiness.deniedForever =>
      "Microphone access is off for this app. Turn it on in your phone's "
          'settings, then tap Listen again.',
    SpeechReadiness.denied =>
      'Voice needs the microphone. Tap Listen again and choose Allow.',
    SpeechReadiness.unavailable =>
      'This device has no speech recognition available.',
  };
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
    this.continuous = true,
    this.pauseFor = const Duration(seconds: 3),
    this.waitForSpeech = const Duration(seconds: 3),
    this.biasPhrases = const [],
  });

  final String localeId;
  final bool preferOnDevice;

  /// How long a silence ends an utterance **once the speaker has started**.
  ///
  /// **This is the whole of the delay between the speaker stopping and the
  /// microphone switching off**, so it belongs to the caller rather than the
  /// backend: it is a different question for an auctioneer than it is for
  /// someone who has just asked the command palette for something and is
  /// waiting on the answer. The default is set-winners' — long enough to say
  /// "twenty five dollars" without being cut in half.
  ///
  /// On Android it becomes `EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS`
  /// *and* the plugin's own post-`onEndOfSpeech` timer, so it is felt twice
  /// over if the platform doesn't deliver a final result promptly. Three
  /// seconds for dictation was roughly twice the browser's wait, which is
  /// exactly what "the app doesn't turn the microphone off the way the web
  /// does" was.
  final Duration pauseFor;

  /// How long to wait for the speaker to begin, before the phrase counts as
  /// never having happened.
  ///
  /// **Separate from [pauseFor] because the browser separates them, and
  /// collapsing the two is what made dictation stop before the user had
  /// finished the first word.** `speech_to_text` runs a single pause clock
  /// that starts at `listen()` and is only ever pushed forward by a *result*
  /// — sound level doesn't touch it — so one 1.5 s window meant the user had
  /// 1.5 s from tapping the microphone to get a partial transcript back, with
  /// network recognition's round trip inside that budget. Anyone who paused to
  /// think, or spoke a beat late, got a microphone that switched itself off
  /// having heard nothing.
  ///
  /// Web Speech has no such rule: Chrome waits several seconds for speech to
  /// begin (then raises `no-speech`) and applies its short trailing-silence
  /// endpointing only afterwards. This is that first window, and the backend
  /// swaps to [pauseFor] the moment a transcript proves someone is talking.
  ///
  /// **Defaults to [pauseFor]'s default, which means one clock and the
  /// behaviour that predates this option.** That is what a *continuous*
  /// session wants and why voice set-winners doesn't set it: there, running
  /// out of patience with a silent speaker only re-arms the recognizer, so the
  /// two windows have never needed to differ. It is a one-shot session, where
  /// the wait ends the session for good, that has to tell them apart.
  final Duration waitForSpeech;

  /// Whether the session outlives one utterance.
  ///
  /// True for voice set-winners: an auctioneer talks for half an hour and the
  /// microphone has to survive every pause in it. False for dictation, which
  /// is one sentence the page then acts on — the same contract as the Web
  /// Speech API's `continuous = false`, so a page written against the browser
  /// behaves the same way here.
  ///
  /// **A continuous backend can't be made one-shot from the outside**, which
  /// is why this is an option rather than something the caller arranges. Only
  /// the backend sees every way an utterance can end, and most of them produce
  /// no final result at all — silence, a no-match, the platform simply
  /// reporting `notListening`. A caller that stops on the final result stays
  /// listening forever on all the others, which is exactly how the command
  /// palette's microphone ended up stuck on until it was tapped a second time.
  final bool continuous;

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

  /// Whether the device has a recognition service at all.
  ///
  /// **Must not prompt for anything, and must not bring the recognizer up.**
  /// This is what answers `voiceGetState`, which a page calls on load to
  /// decide whether to reveal its microphone button — so a permission dialog
  /// here appears out of nowhere, before the user has expressed any interest,
  /// and a "no" to it would then be reported as "this phone can't do voice"
  /// for the rest of the session. Both of those were real bugs; see
  /// `PlatformSpeechBackend.isCapable`.
  ///
  /// Permission state is deliberately *not* part of the answer: a phone that
  /// hasn't been asked yet is still a phone that can do this.
  Future<bool> isCapable();

  /// Acquire the microphone and start the recognizer. **Only ever called from
  /// a user gesture** — this is the one place allowed to raise an OS
  /// permission dialog.
  ///
  /// Never cached: a user can revoke the microphone from Settings mid-auction,
  /// which at an auction means it happened between two lots.
  Future<SpeechReadiness> prepare();

  /// Whether the microphone is already granted. A *check* — like [isCapable]
  /// it must never prompt, because `voiceGetState` reaches it on page load.
  Future<bool> hasPermission();

  /// True when the last [prepare] found a recognition service but no
  /// permission, so callers can tell "this phone can't" from "this phone said
  /// no". Meaningless before the first [prepare] — [isCapable] doesn't look.
  bool get needsPermission;

  /// Whether recognition is actually running locally. Only meaningful after
  /// [start]; platforms decide this themselves and may ignore the request.
  bool get isOnDevice;

  /// Whether this backend does anything with
  /// [SpeechSessionOptions.biasPhrases].
  ///
  /// False for `platform`: `speech_to_text` exposes neither iOS
  /// `contextualStrings` nor Android's `EXTRA_BIASING_STRINGS`, which is the
  /// one lever it can't pull and the reason the `biased` backend is on the
  /// roadmap at all. Surfaced rather than assumed so the settings panel can
  /// tell the operator which half of a feature they've got — the low-price
  /// tie-break works with no biasing whatever, since it chooses between
  /// readings the recognizer already returned.
  bool get supportsPhraseBias => false;

  Stream<SpeechEvent> get events;

  /// Begin listening. Implementations own their own restart behaviour — the
  /// caller expects a session that lasts until [stop], not one utterance.
  Future<void> start(SpeechSessionOptions options);

  Future<void> stop();

  Future<void> dispose();
}
