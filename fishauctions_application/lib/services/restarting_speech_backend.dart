import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';

import 'speech_backend.dart';
import 'voice_parser.dart';

final _log = Logger();

/// Everything a [SpeechBackend] needs that isn't "how do I reach a
/// recognizer": the session, the permissions, and four bug fixes that took
/// hardware to find.
///
/// **This exists because both backends are per-utterance underneath.**
/// Android's `SpeechRecognizer` ends after each phrase and iOS caps a request
/// at about a minute, whether you reach them through `speech_to_text` or
/// through our own channel. Selling an auction is half an hour of talking, so
/// something has to keep re-arming, decide which platform "errors" are really
/// just a speaker who stopped, and get the words out when a phrase ends
/// without a final result. That logic is identical for every backend, and it
/// is exactly the logic that has been wrong three times:
///
/// - `permanent` on an Android error means nothing (the plugin sets it on
///   every error it forwards), so a session must not end on one failure.
/// - On-device recognition can be *available* and still fail for want of a
///   language pack, and the cure — fall back to network, once, silently — is
///   not obvious from the error.
/// - A browser has two silence windows and these APIs have one, so the wait
///   for a speaker to *begin* has to be separated from the wait for them to
///   *finish* ([SpeechSessionOptions.waitForSpeech]).
/// - Only one of the four ways a phrase can end produces a final result, so
///   the last partial has to be promoted or whole commands vanish.
///
/// Duplicating that per backend would mean fixing the fifth one twice.
/// Subclasses supply only [openUtterance], [closeUtterance], [ensureRecognizer]
/// and [isUtteranceOpen], and report what the platform says back through
/// [reportResult] / [reportLevel] / [reportPlatformError] /
/// [reportUtteranceClosed].
abstract class RestartingSpeechBackend implements SpeechBackend {
  /// Android throws `ERROR_RECOGNIZER_BUSY` when a listen follows a stop too
  /// closely, and the failure looks exactly like a dead microphone from the
  /// outside. Anything under about a quarter second is unreliable in practice.
  static const Duration restartDelay = Duration(milliseconds: 350);

  /// After a genuine error, back off instead of hammering the service.
  static const Duration errorBackoff = Duration(seconds: 2);

  /// How many failures in a row end a continuous session. One is too few — a
  /// recognizer that hiccups mid-auction should recover by itself — and
  /// unlimited is a microphone that stays lit while nothing works.
  static const int maxConsecutiveFailures = 3;

  /// The platform error codes that mean "the speaker stopped talking", not
  /// that anything went wrong. Treating them as failures is what makes naive
  /// continuous listening die at the first silence.
  ///
  /// The native backend deliberately reports these same strings, so this
  /// vocabulary is the one contract both platforms and both backends share.
  static const Set<String> benignErrors = {
    'error_no_match',
    'error_speech_timeout',
    'error_retry',
    'error_busy',
  };

  final StreamController<SpeechEvent> _events =
      StreamController<SpeechEvent>.broadcast();

  bool _wantListening = false;
  bool _restartScheduled = false;
  bool _needsPermission = false;
  bool _onDevice = false;

  /// Set once on-device recognition has been tried and failed, and never
  /// cleared: a missing language pack doesn't arrive mid-session, and this
  /// object is shared by both features, so paying the failed attempt once per
  /// process is right. Downloading the pack takes effect on the next launch.
  bool _onDeviceUnavailable = false;

  bool _speechStarted = false;
  List<SpeechHypothesis> _pending = const [];
  bool _sawFinal = false;
  int _consecutiveFailures = 0;
  Timer? _restartTimer;
  SpeechSessionOptions _options = const SpeechSessionOptions();

  @override
  Stream<SpeechEvent> get events => _events.stream;

  @override
  bool get needsPermission => _needsPermission;

  @override
  bool get isOnDevice => _onDevice;

  @override
  bool get supportsPhraseBias => false;

  /// The session's options, for subclasses that need more of them than
  /// [openUtterance] is handed.
  @protected
  SpeechSessionOptions get options => _options;

  /// Whether an utterance is currently open on the platform. Guards a re-arm
  /// against doubling up.
  @protected
  bool get isUtteranceOpen;

  /// Bring the recognizer up. Called with the microphone already granted, so
  /// a false here really does mean "this device can't", not "nobody asked".
  @protected
  Future<bool> ensureRecognizer();

  /// Start listening for one phrase.
  ///
  /// [pauseFor] is the **long** window — how long to wait for the speaker to
  /// begin. Narrowing it to the trailing-silence window once words arrive is
  /// [narrowPause]'s job, and the base class calls that on the first result.
  @protected
  Future<void> openUtterance({
    required SpeechSessionOptions options,
    required bool onDevice,
    required Duration pauseFor,
  });

  /// Ask the platform to finish the current phrase and hand over whatever it
  /// has. Must be safe to call when nothing is open.
  @protected
  Future<void> closeUtterance();

  /// Swap the long "has anyone started talking?" window for the short
  /// trailing-silence one, now that someone demonstrably has. Optional — a
  /// backend whose platform endpoints for itself can ignore it.
  @protected
  void narrowPause(Duration pauseFor) {}

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
    // Ask for the microphone ourselves, before any recognizer can. Doing it
    // here rather than inside a plugin's initialize() keeps the dialog on the
    // user's tap, and keeps "refused" and "no recognizer" as two answers
    // rather than one false.
    //
    // iOS needs two grants, not one: SFSpeechRecognizer's own authorization is
    // separate from the microphone's, and it traps on first use without it.
    // Both are asked here so the pair arrives together.
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
    return await ensureRecognizer()
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

  @override
  Future<void> stop() async {
    _wantListening = false;
    _restartTimer?.cancel();
    _restartScheduled = false;
    try {
      await closeUtterance();
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

  Future<void> _listen() async {
    if (!_wantListening || isUtteranceOpen) {
      return;
    }
    _speechStarted = false;
    _sawFinal = false;
    _pending = const [];
    _onDevice = _options.preferOnDevice && !_onDeviceUnavailable;
    try {
      await openUtterance(
        options: _options,
        onDevice: _onDevice,
        // The *long* window, not the trailing-silence one: until words arrive
        // this is a deadline on the speaker starting, with a network
        // recognizer's round trip inside the budget.
        pauseFor: _waitForSpeechNow,
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
      _restartSoon(after: errorBackoff);
    }
  }

  /// [SpeechSessionOptions.waitForSpeech], nudged by a millisecond once we've
  /// fallen back to network recognition — a workaround for `speech_to_text`,
  /// not a tuning knob, kept here because both backends go through one path.
  ///
  /// Its Android side rebuilds the recognizer `Intent` only when the language
  /// tag, partial-results flag, listen mode or pause length changes; `onDevice`
  /// is not on that list, and it is what puts `EXTRA_PREFER_OFFLINE` on the
  /// intent. So a fallback attempt inherits the flag from the on-device attempt
  /// that just failed and fails the same way. Changing the pause forces the
  /// rebuild; a millisecond is not observable anywhere else.
  Duration get _waitForSpeechNow => _onDeviceUnavailable
      ? _options.waitForSpeech + const Duration(milliseconds: 1)
      : _options.waitForSpeech;

  /// A transcript from the platform, partial or final.
  @protected
  void reportResult(
    List<SpeechHypothesis> alternates, {
    required bool isFinal,
  }) {
    // Words came back, so whatever went wrong before is behind us.
    _consecutiveFailures = 0;
    _tightenPauseOnFirstWords();
    final cleaned = [
      for (final alternate in alternates)
        if (alternate.text.trim().isNotEmpty) alternate,
    ];
    if (cleaned.isEmpty) {
      return;
    }
    if (isFinal) {
      _sawFinal = true;
      _pending = const [];
      _events.add(SpeechEvent.result(cleaned));
      return;
    }
    _pending = cleaned;
    _events.add(SpeechEvent.partial(cleaned));
  }

  /// Microphone loudness, already normalized to 0..1 — platform scales don't
  /// agree and the meter only answers "is it hearing me".
  @protected
  void reportLevel(double level) =>
      _events.add(SpeechEvent.level(level.clamp(0.0, 1.0)));

  /// The platform said the current phrase is over, however it ended.
  @protected
  void reportUtteranceClosed() {
    if (!_wantListening) {
      _events.add(const SpeechEvent.state(listening: false));
      return;
    }
    _endOfUtterance();
  }

  /// A platform error, by its `error_*` code.
  @protected
  void reportPlatformError(String code) {
    if (benignErrors.contains(code)) {
      if (_wantListening) {
        _endOfUtterance();
      }
      return;
    }
    final kind = switch (code) {
      'error_permission' ||
      'error_insufficient_permissions' => SpeechErrorKind.permission,
      'error_network' || 'error_network_timeout' => SpeechErrorKind.network,
      'error_language_not_supported' ||
      'error_language_unavailable' => SpeechErrorKind.unavailable,
      _ => SpeechErrorKind.unknown,
    };
    // Android's `permanent` flag is deliberately not consulted anywhere: the
    // plugin sets it on *every* error it forwards, with nothing behind the
    // value, so trusting it ends the session on the first hiccup of a
    // half-hour auction. What actually can't be retried is decided here.
    _log.w('Speech error: $code');
    if (kind == SpeechErrorKind.permission) {
      _fail(kind, _messageFor(kind, code));
      return;
    }
    // The one failure with a known cure: on-device recognition was asked for
    // (an auction hall's wifi is bad, so it's the default) and this phone has
    // the recognition service without the downloaded language pack. Every
    // availability check passes, and network recognition works on the same
    // phone in the same breath.
    if (_onDevice && !_onDeviceUnavailable) {
      _onDeviceUnavailable = true;
      _onDevice = false;
      _log.i(
        'On-device recognition failed ($code); using network recognition '
        'from here on',
      );
      _restartSoon();
      return;
    }
    _consecutiveFailures++;
    if (!_options.continuous ||
        _consecutiveFailures >= maxConsecutiveFailures) {
      _fail(kind, _messageFor(kind, code));
      return;
    }
    // Not reported to the page: a transient failure that the next re-arm fixes
    // two seconds later isn't news, and putting it on screen means the button
    // resets itself while the microphone is in fact still coming back.
    _restartSoon(after: errorBackoff);
  }

  /// The recognizer finished a phrase. A continuous session re-arms; a
  /// one-shot one is over, and says so.
  void _endOfUtterance() {
    // Before anything else: whatever was heard has to get out, or a re-arm
    // overwrites it and the phrase is gone.
    _flushPendingAsFinal();
    if (_options.continuous) {
      _restartSoon();
      return;
    }
    _wantListening = false;
    _restartTimer?.cancel();
    _restartScheduled = false;
    _events.add(const SpeechEvent.state(listening: false));
  }

  /// Report the last partial as the utterance's result, when the platform
  /// ended the phrase without ever promoting one.
  ///
  /// **Without this an entire command can be heard and silently thrown away,
  /// and short ones are the most likely to go** — which is what "saying 'lot
  /// five' never fills anything" was. `VoiceCommandService` acts on final
  /// results only (a half-recognized number written into a field and then
  /// corrected reads as the app typing nonsense), but only *one* of the ways a
  /// phrase can end produces a final: `ERROR_NO_MATCH` on a short or noisy
  /// utterance, `ERROR_SPEECH_TIMEOUT`, and the platform simply reporting done
  /// all arrive with the words sitting in the last partial. In a continuous
  /// session [_endOfUtterance] emits nothing else, so the caller has no way to
  /// notice and finalize for itself.
  ///
  /// Web Speech delivers a last result on `stop()` for exactly this reason.
  /// Never on an explicit [stop]: that path doesn't route through
  /// [_endOfUtterance], which is correct — someone switching the microphone
  /// off is cancelling, not submitting.
  void _flushPendingAsFinal() {
    if (_sawFinal || _pending.isEmpty) {
      return;
    }
    final alternates = _pending;
    _pending = const [];
    _sawFinal = true;
    _events.add(SpeechEvent.result(alternates));
  }

  /// A *partial* is enough to prove someone is talking, and waiting for a
  /// final would defeat the point: most ways a phrase ends produce no final.
  /// Only the first one of an utterance does anything.
  void _tightenPauseOnFirstWords() {
    if (_speechStarted || _options.pauseFor >= _options.waitForSpeech) {
      return;
    }
    _speechStarted = true;
    if (!isUtteranceOpen) {
      return;
    }
    try {
      narrowPause(_options.pauseFor);
    } on Object catch (e) {
      // Non-fatal by construction: failing to shorten the window costs a
      // longer wait before the microphone switches off, never a lost phrase.
      _log.w('Could not shorten the speech pause: $e');
    }
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

  void _restartSoon({Duration after = restartDelay}) {
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
}
