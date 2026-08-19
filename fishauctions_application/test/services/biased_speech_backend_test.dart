import 'dart:async';

import 'package:fishauctions_application/services/biased_speech_backend.dart';
import 'package:fishauctions_application/services/speech_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for `BiasedSpeechBridge.kt` / `BiasedSpeechBridge.swift`. The
/// native halves can't be run here, but the contract between them and Dart can:
/// what `start` is handed, and what Dart does with each event shape they emit.
class FakeSpeechPlatform {
  FakeSpeechPlatform() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'available':
              return available;
            case 'supportsBias':
              return supportsBias;
            default:
              return null;
          }
        });
    // An EventChannel is a MethodChannel underneath: `listen`/`cancel` arrive
    // as method calls, and events go back over the same name.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (call) async => null);
  }

  static const method = MethodChannel('com.fishauctions.app/speech');
  static const events = MethodChannel('com.fishauctions.app/speech_events');

  final List<MethodCall> calls = [];
  bool available = true;
  bool supportsBias = true;

  MethodCall? get lastStart =>
      calls.where((c) => c.method == 'start').lastOrNull;

  Map<Object?, Object?> get startArgs =>
      lastStart!.arguments as Map<Object?, Object?>;

  /// Push an event as the native side would.
  Future<void> emit(Map<String, Object?> payload) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope(payload),
          (_) {},
        );
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(method, null)
      ..setMockMethodCallHandler(events, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSpeechPlatform platform;
  late BiasedSpeechBackend backend;
  late List<SpeechEvent> events;
  late StreamSubscription<SpeechEvent> subscription;

  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          permissions,
          (call) async => call.method == 'requestPermissions' ? {7: 1} : 1,
        );
    platform = FakeSpeechPlatform();
    backend = BiasedSpeechBackend();
    events = [];
    subscription = backend.events.listen(events.add);
  });

  tearDown(() async {
    await subscription.cancel();
    platform.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  const listening = SpeechSessionOptions(
    preferOnDevice: false,
    biasPhrases: ['bidder n m', 'seventeen dollars'],
  );

  group('what the native side is asked for', () {
    test('the phrase list reaches the platform', () async {
      // The entire reason this backend exists. If this argument stops being
      // sent, the class is an elaborate way to do what speech_to_text already
      // did.
      await backend.start(listening);
      await settle();

      expect(platform.startArgs['biasPhrases'], [
        'bidder n m',
        'seventeen dollars',
      ]);
    });

    test('the locale is sent in the platform\'s spelling', () async {
      // Dart carries `en_US` (the served config's form); both recognizers want
      // a BCP-47 tag.
      await backend.start(listening);
      await settle();

      expect(platform.startArgs['localeId'], 'en-US');
    });

    test('a listen is armed with the long window, not the short one', () async {
      await backend.start(
        const SpeechSessionOptions(
          preferOnDevice: false,
          pauseFor: Duration(milliseconds: 1500),
          waitForSpeech: Duration(seconds: 8),
        ),
      );
      await settle();

      expect(platform.startArgs['pauseMillis'], 8000);
    });

    test('more alternates than the parser scores', () async {
      // The alternate that matches a real lot number is often not the one the
      // recognizer ranked first, and spares cost nothing.
      await backend.start(listening);
      await settle();

      expect(platform.startArgs['maxAlternates'], greaterThan(3));
    });
  });

  group('bias support is a question about the running device', () {
    test('reported false until the platform has been asked', () {
      // EXTRA_BIASING_STRINGS is Android 13+ and minSdk is 28, so a real share
      // of phones get this recognizer without its point. Claiming a capability
      // we have not confirmed is the failure that matters.
      expect(backend.supportsPhraseBias, isFalse);
    });

    test('picked up when the session starts', () async {
      await backend.start(listening);
      await settle();

      expect(backend.supportsPhraseBias, isTrue);
    });

    test('a platform that cannot bias still recognizes speech', () async {
      platform.supportsBias = false;
      await backend.start(listening);
      await settle();

      expect(backend.supportsPhraseBias, isFalse);
      // …and listening began anyway.
      expect(platform.lastStart, isNotNull);
      expect(events.first.type, SpeechEventType.state);
      expect(events.first.listening, isTrue);
    });

    test('an absent native side reports itself uncapable', () async {
      platform.available = false;
      expect(await backend.isCapable(), isFalse);
    });
  });

  group('events from the native side', () {
    test('a final transcript comes through with its alternates', () async {
      await backend.start(listening);
      await settle();
      await platform.emit({
        'type': 'result',
        'final': true,
        'alternates': [
          {'text': 'lot forty two', 'confidence': 0.9},
          {'text': 'lot forty to', 'confidence': -1.0},
        ],
      });
      await settle();

      final result = events.singleWhere(
        (e) => e.type == SpeechEventType.result,
      );
      expect(result.bestText, 'lot forty two');
      expect(result.alternates, hasLength(2));
    });

    test('a phrase that ends without a final is still reported', () async {
      // The same rule as the platform backend, and it lives in the shared base
      // class precisely so both get it: only one of the ways a phrase can end
      // produces a final, and short commands are the likeliest to go.
      await backend.start(listening);
      await settle();
      await platform.emit({
        'type': 'result',
        'final': false,
        'alternates': [
          {'text': 'lot 5'},
        ],
      });
      await platform.emit({'type': 'error', 'code': 'error_no_match'});
      await settle();

      final result = events.singleWhere(
        (e) => e.type == SpeechEventType.result,
      );
      expect(result.bestText, 'lot 5');
      expect(
        events.where((e) => e.type == SpeechEventType.error),
        isEmpty,
        reason: 'a no-match is a speaker who stopped, not a failure',
      );
    });

    test('levels arrive already normalized', () async {
      await backend.start(listening);
      await settle();
      await platform.emit({'type': 'level', 'level': 0.4});
      await settle();

      expect(
        events.singleWhere((e) => e.type == SpeechEventType.level).level,
        0.4,
      );
    });

    test('a real failure is reported with a message', () async {
      await backend.start(
        const SpeechSessionOptions(preferOnDevice: false, continuous: false),
      );
      await settle();
      await platform.emit({'type': 'error', 'code': 'error_permission'});
      await settle();

      final error = events.singleWhere((e) => e.type == SpeechEventType.error);
      expect(error.errorKind, SpeechErrorKind.permission);
      expect(error.message, isNotEmpty);
    });

    test('a second prepare does not cost the event subscription', () async {
      // `prepare()` runs twice for every session — VoiceCommandService calls
      // it, then RestartingSpeechBackend.start calls it again — and it used to
      // cancel and re-listen the event stream each time. Neither half of that
      // is ordered against the other: cancelling a broadcast subscription does
      // not wait for EventChannel's `onCancel`, which both messages the
      // platform *and* clears the binary messenger's handler for the channel
      // name — the handler the new subscription just installed. The losing
      // outcome was a running recognizer whose events reached nobody: the
      // microphone indicator lit, and not one level, transcript or result.
      await backend.prepare();
      await backend.start(listening);
      await settle();
      await platform.emit({
        'type': 'result',
        'final': true,
        'alternates': [
          {'text': 'lot forty two'},
        ],
      });
      await settle();

      expect(
        events.where((e) => e.type == SpeechEventType.result),
        hasLength(1),
      );
    });

    test('a malformed event is ignored rather than fatal', () async {
      await backend.start(listening);
      await settle();
      await platform.emit({'type': 'result', 'final': true});
      await platform.emit({'nonsense': true});
      await settle();

      expect(events.where((e) => e.type == SpeechEventType.error), isEmpty);
    });
  });
}
