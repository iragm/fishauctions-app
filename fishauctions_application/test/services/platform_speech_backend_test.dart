import 'dart:async';

import 'package:fishauctions_application/services/platform_speech_backend.dart';
import 'package:fishauctions_application/services/speech_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Stands in for `android.speech.SpeechRecognizer` / `SFSpeechRecognizer`, so
/// a test can produce the things only real hardware produces: an utterance
/// that ends in silence, a language pack that isn't installed, an error the
/// platform insists is permanent when it isn't.
class FakeSpeechToText implements SpeechToText {
  final List<SpeechListenOptions> listenCalls = [];
  int stopCalls = 0;
  bool initializeResult = true;

  /// Whether `listen` itself refuses, as opposed to failing later through the
  /// error callback.
  bool listenSucceeds = true;

  SpeechErrorListener? _onError;
  SpeechStatusListener? _onStatus;
  SpeechResultListener? _onResult;
  bool _listening = false;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize({
    SpeechErrorListener? onError,
    SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration? finalTimeout,
    List<dynamic>? options,
  }) async {
    _onError = onError;
    _onStatus = onStatus;
    return initializeResult;
  }

  @override
  Future<void> listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    SpeechSoundLevelChange? onSoundLevelChange,
    dynamic cancelOnError = false,
    dynamic partialResults = true,
    dynamic onDevice = false,
    ListenMode listenMode = ListenMode.confirmation,
    dynamic sampleRate = 0,
    SpeechListenOptions? listenOptions,
  }) async {
    if (!listenSucceeds) {
      throw PlatformException(code: 'listenFailedError');
    }
    _onResult = onResult;
    listenCalls.add(listenOptions ?? SpeechListenOptions());
    _listening = true;
    _onStatus?.call(SpeechToText.listeningStatus);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _endSession();
  }

  void _endSession() {
    if (!_listening) {
      return;
    }
    _listening = false;
    _onStatus?.call(SpeechToText.notListeningStatus);
  }

  /// The platform reporting a failure. `permanent` defaults to true because
  /// that is what Android's plugin puts on **every** error it forwards —
  /// `speechError.put("permanent", true)`, unconditionally.
  void fail(String errorMsg, {bool permanent = true}) {
    _endSession();
    _onError?.call(SpeechRecognitionError(errorMsg, permanent));
  }

  /// A recognized phrase. A partial is one of the stream of guesses that
  /// arrives while someone is still talking.
  void say(String words, {required bool isFinal}) {
    _onResult?.call(
      SpeechRecognitionResult([
        SpeechRecognitionWords(words, null, 0.9),
      ], isFinal ? ResultType.finalResult.value : ResultType.partial.value),
    );
    if (isFinal) {
      _endSession();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSpeechToText speech;
  late PlatformSpeechBackend backend;
  late List<SpeechEvent> events;
  late StreamSubscription<SpeechEvent> subscription;

  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUp(() {
    // prepare() is not what's under test here: every test below starts from a
    // phone whose owner has already allowed the microphone. 1 is
    // PermissionStatus.granted.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          permissions,
          (call) async => call.method == 'requestPermissions' ? {7: 1} : 1,
        );
    speech = FakeSpeechToText();
    backend = PlatformSpeechBackend(speech: speech);
    events = [];
    subscription = backend.events.listen(events.add);
  });

  tearDown(() async {
    await subscription.cancel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null);
  });

  /// Long enough for the 350 ms re-arm to have happened, or provably not.
  Future<void> waitForRestart() =>
      Future<void>.delayed(const Duration(milliseconds: 500));

  /// Let the event stream deliver. Events are queued rather than handed
  /// straight to listeners, so anything emitted from a platform callback
  /// arrives a microtask after the call that caused it.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Iterable<SpeechEvent> errorsIn(List<SpeechEvent> all) =>
      all.where((e) => e.type == SpeechEventType.error);

  group('a continuous session (voice set-winners)', () {
    test('survives the silence at the end of every phrase', () async {
      await backend.start(const SpeechSessionOptions());
      expect(speech.listenCalls, hasLength(1));

      // How both platforms say "the speaker stopped talking".
      speech.fail('error_no_match');
      await waitForRestart();

      expect(speech.listenCalls, hasLength(2));
      expect(errorsIn(events), isEmpty);
      await backend.stop();
    });

    // Android's plugin writes `"permanent": true` on every error it forwards,
    // with nothing behind the value. Believing it ended a half-hour auction on
    // the first hiccup.
    test('does not end on one error the platform calls permanent', () async {
      await backend.start(const SpeechSessionOptions(preferOnDevice: false));

      speech.fail('error_network');
      await waitForRestart();

      expect(errorsIn(events), isEmpty);
      expect(speech.listenCalls, hasLength(2));
      await backend.stop();
    });

    test('gives up after three failures in a row', () async {
      await backend.start(const SpeechSessionOptions(preferOnDevice: false));

      speech
        ..fail('error_network')
        ..fail('error_network')
        ..fail('error_network');
      await settle();

      final reported = errorsIn(events).single;
      expect(reported.errorKind, SpeechErrorKind.network);
      expect(reported.message, isNotEmpty);
    });
  });

  // The set-winners bug: the phone has a recognition service (so every
  // availability check passes) but no downloaded language pack, and voice asks
  // for on-device recognition because an auction hall's wifi is bad. Android
  // answers ERROR_LANGUAGE_UNAVAILABLE. Network recognition works on the same
  // phone in the same breath — which is why palette dictation was fine.
  group('on-device recognition this phone cannot actually do', () {
    test('falls back to network instead of reporting no voice', () async {
      await backend.start(const SpeechSessionOptions());
      expect(speech.listenCalls.single.onDevice, isTrue);

      speech.fail('error_language_unavailable');
      await waitForRestart();

      expect(speech.listenCalls, hasLength(2));
      expect(speech.listenCalls.last.onDevice, isFalse);
      // The plugin caches its Android recognizer intent on everything *but*
      // onDevice, so the retry has to differ in something it does watch or it
      // keeps EXTRA_PREFER_OFFLINE and fails identically.
      expect(
        speech.listenCalls.last.pauseFor,
        isNot(speech.listenCalls.first.pauseFor),
      );
      // Nothing is said to the user: it recovered, and "this device has no
      // speech recognition available" was both wrong and unactionable.
      expect(errorsIn(events), isEmpty);
      expect(backend.isOnDevice, isFalse);
      await backend.stop();
    });

    test('does not try on-device again in the same process', () async {
      await backend.start(const SpeechSessionOptions());
      speech.fail('error_language_unavailable');
      await waitForRestart();
      await backend.stop();

      await backend.start(const SpeechSessionOptions());
      expect(speech.listenCalls.last.onDevice, isFalse);
      await backend.stop();
    });
  });

  group('a one-shot session (palette dictation)', () {
    test('ends when the phrase ends, transcript or not', () async {
      await backend.start(const SpeechSessionOptions(continuous: false));

      // Nothing recognized — no final result will ever arrive, which is the
      // case that left the palette's microphone lit until it was tapped again.
      speech.fail('error_no_match');
      await waitForRestart();

      expect(speech.listenCalls, hasLength(1));
      expect(events.last.type, SpeechEventType.state);
      expect(events.last.listening, isFalse);
      expect(errorsIn(events), isEmpty);
    });

    test('ends on a final transcript', () async {
      await backend.start(const SpeechSessionOptions(continuous: false));

      speech.say('add a lot for bob', isFinal: true);
      await waitForRestart();

      expect(speech.listenCalls, hasLength(1));
      expect(
        events.map((e) => e.type),
        containsAllInOrder([SpeechEventType.result, SpeechEventType.state]),
      );
      expect(events.last.listening, isFalse);
    });

    test('reports a failed start rather than retrying forever', () async {
      speech.listenSucceeds = false;
      await backend.start(const SpeechSessionOptions(continuous: false));
      await settle();

      expect(errorsIn(events), hasLength(1));
      expect(speech.listenCalls, isEmpty);
    });
  });

  test('a refused microphone ends any session immediately', () async {
    await backend.start(const SpeechSessionOptions(preferOnDevice: false));

    speech.fail('error_permission');
    await waitForRestart();

    expect(errorsIn(events).single.errorKind, SpeechErrorKind.permission);
    expect(speech.listenCalls, hasLength(1));
  });
}
