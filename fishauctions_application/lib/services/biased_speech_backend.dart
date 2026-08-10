import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import 'restarting_speech_backend.dart';
import 'speech_backend.dart';
import 'voice_parser.dart';

final _log = Logger();

/// A recognizer we own, so that we can tell it what words to expect.
///
/// **This exists for one API on each platform and nothing else.**
/// `SFSpeechRecognitionRequest.contextualStrings` and Android's
/// `RecognizerIntent.EXTRA_BIASING_STRINGS` are how you say "this auction has a
/// bidder called NM" — the difference between a recognizer that can hear a
/// club's initials-based bidder numbers and one that structurally cannot.
/// `speech_to_text` exposes neither and has no extension point that could
/// (`SpeechListenOptions` has fixed fields; `initialize(options:)` is
/// per-process and reads exactly one name), so reaching them means owning
/// `android.speech.SpeechRecognizer` and `SFSpeechRecognizer` directly.
///
/// Everything above the recognizer is unchanged: [RestartingSpeechBackend]
/// still runs the session, the two silence windows, the on-device fallback and
/// the last-partial promotion, and the native halves deliberately report the
/// same `error_*` codes `speech_to_text` does so that one error vocabulary
/// serves both. The native side handles **one utterance at a time** and knows
/// nothing about sessions — which is also what keeps it small enough to reason
/// about on two platforms.
class BiasedSpeechBackend extends RestartingSpeechBackend {
  BiasedSpeechBackend({MethodChannel? channel, EventChannel? events})
    : _channel = channel ?? const MethodChannel(_channelName),
      _eventChannel = events ?? const EventChannel(_eventsName);

  static const _channelName = 'com.fishauctions.app/speech';
  static const _eventsName = 'com.fishauctions.app/speech_events';

  /// How many transcriptions to ask the platform for.
  ///
  /// More than the parser scores (`VoiceGrammar.maxAlternates`, 3) on purpose:
  /// the alternate that matches a real lot number is often *not* the one the
  /// recognizer ranked first, and asking for a couple of spares costs nothing.
  /// The parser still only looks at the top few.
  static const int _maxAlternates = 5;

  final MethodChannel _channel;
  final EventChannel _eventChannel;

  StreamSubscription<dynamic>? _subscription;
  Timer? _pauseTimer;
  Duration _pauseWindow = const Duration(seconds: 3);
  bool _open = false;
  bool? _biasSupported;

  @override
  String get id => 'biased';

  @override
  bool get isUtteranceOpen => _open;

  /// Whether the *running* platform will act on the phrase list.
  ///
  /// A runtime question, not a build-time one: `EXTRA_BIASING_STRINGS` is
  /// Android 13+, and `minSdk` here is 28. On an older phone this backend
  /// still works — it is a perfectly good recognizer — it just can't be told
  /// what to expect, and the settings panel should say so rather than promise
  /// something the device won't do. Defaults to false until the platform has
  /// been asked, because claiming a capability we haven't confirmed is the
  /// failure that matters.
  @override
  bool get supportsPhraseBias => _biasSupported ?? false;

  @override
  Future<bool> isCapable() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on Object catch (e) {
      // Pessimistic, unlike `PlatformSpeechBackend.isCapable` — and
      // deliberately the opposite call. There, an optimistic answer keeps a
      // working microphone button visible; here, a channel error means this
      // build has no native recognizer at all, and the right response is to
      // fall back to the backend that does (see `Microphone.backendFor`).
      _log.w('Biased speech availability check failed: $e');
      return false;
    }
  }

  @override
  Future<bool> ensureRecognizer() async {
    _biasSupported ??= await _askBiasSupport();
    await _subscription?.cancel();
    _subscription = _eventChannel.receiveBroadcastStream().listen(
      _onPlatformEvent,
      onError: (Object error) {
        // The stream itself failing is not an utterance failing. Reported as a
        // platform error so the session's own retry/backoff rules apply rather
        // than inventing a second set here.
        _log.w('Speech event stream error: $error');
        reportPlatformError('error_client');
      },
    );
    return true;
  }

  Future<bool> _askBiasSupport() async {
    try {
      return await _channel.invokeMethod<bool>('supportsBias') ?? false;
    } on Object catch (e) {
      _log.w('Bias support check failed: $e');
      return false;
    }
  }

  @override
  Future<void> openUtterance({
    required SpeechSessionOptions options,
    required bool onDevice,
    required Duration pauseFor,
  }) async {
    _open = true;
    _armPause(pauseFor);
    try {
      await _channel.invokeMethod<void>('start', {
        'localeId': options.localeId.replaceAll('_', '-'),
        'onDevice': onDevice,
        // Sent so the platform's own endpointer is generous rather than
        // fighting the Dart clock below. On Android this becomes
        // EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS.
        'pauseMillis': pauseFor.inMilliseconds,
        'maxAlternates': _maxAlternates,
        // The entire reason this class exists. Empty means "don't set the
        // extra at all" — biasing towards nothing is not the same as not
        // biasing, and on some Android builds an empty list is worse than
        // absent.
        'biasPhrases': options.biasPhrases,
      });
    } on Object {
      _open = false;
      _pauseTimer?.cancel();
      rethrow;
    }
  }

  @override
  Future<void> closeUtterance() async {
    _pauseTimer?.cancel();
    if (!_open) {
      return;
    }
    _open = false;
    await _channel.invokeMethod<void>('stop');
  }

  @override
  void narrowPause(Duration pauseFor) => _armPause(pauseFor);

  /// The silence clock, run here rather than natively.
  ///
  /// Endpointing is where the two platforms disagree most — Android takes a
  /// silence length as an intent extra it may quietly clamp, iOS has no such
  /// control at all and simply keeps transcribing — so the only way both
  /// behave the same is for Dart to hold the stopwatch and ask the platform to
  /// finish. Re-armed on every result, so the effective rule is "this long
  /// since the last words", which is what a browser does.
  void _armPause(Duration window) {
    _pauseWindow = window;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(window, () {
      // Close the utterance and let the *platform's* answer end it, rather
      // than ending it here as well. Asking a recognizer to stop is asking it
      // for its final result, and that result is the best transcript of the
      // phrase — declaring the phrase over first means the base class flushes
      // a partial, re-arms, and then the real final lands inside the next
      // utterance.
      unawaited(closeUtterance());
      _armWatchdog();
    });
  }

  /// The one case the platform can't be trusted to answer: a recognizer that
  /// was asked to stop and says nothing at all. Without this the session would
  /// sit with `_open` false and no re-arm scheduled — a lit microphone that
  /// has quietly stopped listening, which is the failure mode hardest to spot
  /// mid-auction. Deliberately longer than a normal stop→result turnaround, so
  /// it only ever fires when the platform really has gone quiet.
  void _armWatchdog() {
    _pauseTimer?.cancel();
    _pauseTimer = Timer(const Duration(milliseconds: 1500), () {
      _log.w('Recognizer did not answer a stop; ending the phrase');
      reportUtteranceClosed();
    });
  }

  void _onPlatformEvent(dynamic raw) {
    if (raw is! Map) {
      return;
    }
    final event = Map<Object?, Object?>.from(raw);
    switch (event['type']) {
      case 'result':
        final isFinal = event['final'] == true;
        if (isFinal) {
          _open = false;
          _pauseTimer?.cancel();
        } else {
          // Every partial pushes the silence clock out, not just the first.
          _armPause(_pauseWindow);
        }
        reportResult(_hypotheses(event['alternates']), isFinal: isFinal);
      case 'level':
        final level = event['level'];
        if (level is num) {
          reportLevel(level.toDouble());
        }
      case 'status':
        if (event['listening'] == true) {
          return;
        }
        _open = false;
        _pauseTimer?.cancel();
        reportUtteranceClosed();
      case 'error':
        _open = false;
        _pauseTimer?.cancel();
        final code = event['code'];
        reportPlatformError(code is String ? code : 'error_unknown');
    }
  }

  List<SpeechHypothesis> _hypotheses(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return [
      for (final item in raw)
        if (item is Map)
          SpeechHypothesis(
            '${item['text'] ?? ''}',
            // -1 is "the platform didn't say", which is most of the time —
            // and nothing downstream may read it as "not confident".
            confidence: item['confidence'] is num
                ? (item['confidence'] as num).toDouble()
                : -1,
          ),
    ];
  }

  @override
  Future<void> dispose() async {
    _pauseTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    await super.dispose();
  }
}
