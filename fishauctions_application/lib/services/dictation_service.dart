import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'microphone.dart';
import 'speech_backend.dart';

final _log = Logger();

/// What the page is told, in the shape it goes over the bridge as.
typedef DictationEventSink = void Function(Map<String, dynamic> event);

/// Plain speech-to-text for any web page that wants to fill a field by
/// talking — the command palette first (`dictateStart` from its microphone
/// button), anything else after.
///
/// **This is not `VoiceCommandService` with the grammar removed, and the two
/// are not interchangeable.** Voice set-winners matches what it hears against
/// a closed vocabulary of the auction's real bidder and lot numbers, because
/// writing a wrong bidder into a sold lot costs money. Dictation has no such
/// constraint and wants none: the palette's whole point is that you can say
/// anything, and a language model on the far side reads it. So this transports
/// the transcript and nothing else — no slots, no confidence gate, no
/// vocabulary fetch.
///
/// **The page keeps owning the text.** Partials stream in so the user watches
/// the box being typed for them, exactly as the website's own Web Speech
/// implementation does; the final transcript is what the page acts on. The
/// app never submits anything.
///
/// The reason this exists at all is that `window.SpeechRecognition` is absent
/// from both of the app's engines — iOS `WKWebView` has never had the Web
/// Speech API, and Android's System WebView doesn't ship the recognizer that
/// Chrome does — and the shell denies the WebView's own microphone request
/// besides. Without a bridge, the palette's microphone button is simply
/// invisible in the app.
class DictationService {
  DictationService._();

  static final DictationService instance = DictationService._();

  /// The [Microphone] owner name. Claiming under a distinct name is what makes
  /// starting dictation stop a set-winners session rather than both features
  /// fighting over one recognizer.
  static const owner = 'dictation';

  StreamSubscription<SpeechEvent>? _subscription;
  DictationEventSink? _sink;
  bool _listening = false;

  /// The last thing heard but not yet reported as final, and whether a final
  /// has gone out. Together they make sure a phrase the recognizer never
  /// promoted reaches the page anyway — see [_finalizePending].
  String _pending = '';
  bool _sentFinal = false;

  bool get isListening => _listening;

  SpeechBackend get _backend => Microphone.instance.backend;

  /// Whether this phone can dictate. Permission-free and prompt-free — a page
  /// asks this on load to decide whether to show a microphone button at all.
  Future<bool> isSupported() => _backend.isCapable();

  Future<Map<String, dynamic>> state() async => {
    'supported': await isSupported(),
    'listening': _listening,
    'permission': await _backend.hasPermission(),
  };

  /// Begin dictating, reporting everything to [sink].
  ///
  /// **The one place dictation may prompt for the microphone**, because it is
  /// reached from a tap on a microphone button. Returns false when it couldn't
  /// start, having already emitted an `error` event saying why.
  Future<bool> start({required DictationEventSink sink}) async {
    _sink = sink;
    if (_listening) {
      return true;
    }
    final readiness = await _backend.prepare();
    if (readiness != SpeechReadiness.ready) {
      _emit({
        'type': 'error',
        'code': readiness.errorCode,
        'message': readiness.message,
      });
      return false;
    }
    await Microphone.instance.claim(owner, stop);
    await _subscription?.cancel();
    _subscription = _backend.events.listen(_onSpeechEvent);
    _listening = true;
    _pending = '';
    _sentFinal = false;
    // `continuous: false` is wrong for set-winners and right here: an
    // auctioneer talks for half an hour, but a palette command is one sentence
    // and the user is waiting for it to be acted on. The backend ends the
    // session on whatever ends the phrase, which is the part that has to live
    // down there — most of the ways a phrase ends produce no transcript at
    // all, so stopping ourselves on the final result left the microphone lit
    // on every silence and no-match.
    //
    // `preferOnDevice: false` is the one place this deliberately differs from
    // voice set-winners, which forces on-device because an auction hall's wifi
    // is bad and the operator feels every round trip. On Android
    // `onDevice: true` resolves to `createOnDeviceSpeechRecognizer`, which
    // **fails outright** on a phone with no downloaded language pack rather
    // than falling back — and a palette command is already waiting on a network
    // call to the language model, so there is nothing to protect here. Working
    // beats fast.
    await _backend.start(
      const SpeechSessionOptions(preferOnDevice: false, continuous: false),
    );
    return true;
  }

  Future<void> stop() async {
    _listening = false;
    Microphone.instance.release(owner);
    await _backend.stop();
    await _subscription?.cancel();
    _subscription = null;
    _emit({'type': 'state', 'listening': false});
  }

  void _onSpeechEvent(SpeechEvent event) {
    switch (event.type) {
      case SpeechEventType.state:
        if (event.listening) {
          _listening = true;
          _emit({'type': 'state', 'listening': true});
          return;
        }
        // A stop the *recognizer* decided on — the phrase ended. Ignored when
        // we're already stopping, because [stop] clears `_listening` before
        // the backend's own event can arrive and it emits the state itself;
        // without that guard a cancelled session would finalize on its way
        // out and submit the command the user was cancelling.
        if (!_listening) {
          return;
        }
        _finalizePending();
        unawaited(stop());
      case SpeechEventType.level:
        _emit({'type': 'level', 'level': event.level});
      case SpeechEventType.partial:
        _pending = event.bestText;
        _emit({'type': 'transcript', 'text': event.bestText, 'partial': true});
      case SpeechEventType.result:
        _sentFinal = true;
        _pending = '';
        _emit({'type': 'transcript', 'text': event.bestText, 'partial': false});
        // One sentence, then hand it back. Leaving the microphone open after a
        // command has been submitted means the answer being read out, or the
        // room, lands in the box on top of what the user is now reading.
        unawaited(stop());
      case SpeechEventType.error:
        _listening = false;
        _emit({
          'type': 'error',
          'code': event.errorKind?.name ?? 'unknown',
          'message': event.message,
        });
    }
  }

  /// Report what was heard as final when the session ended without the
  /// recognizer ever saying so.
  ///
  /// It ends that way more often than it looks: the platform can deliver a
  /// run of partials and then simply stop, and the page is waiting on a final
  /// transcript to act on — that's what runs the command. Web Speech's own
  /// `stop()` delivers a last result for exactly this reason, so matching it
  /// keeps a page written against the browser working unchanged. Only ever on
  /// the recognizer's own ending: a user who taps the microphone off is
  /// cancelling, not submitting.
  void _finalizePending() {
    if (_sentFinal || _pending.isEmpty) {
      return;
    }
    _sentFinal = true;
    final text = _pending;
    _pending = '';
    _emit({'type': 'transcript', 'text': text, 'partial': false});
  }

  void _emit(Map<String, dynamic> event) {
    try {
      _sink?.call(event);
    } on Object catch (e) {
      _log.w('Dictation event delivery failed: $e');
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _listening = false;
    _sink = null;
    _subscription = null;
    _pending = '';
    _sentFinal = false;
  }
}
