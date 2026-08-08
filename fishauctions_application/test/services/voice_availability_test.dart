import 'package:fishauctions_application/services/microphone.dart';
import 'package:fishauctions_application/services/speech_backend.dart';
import 'package:fishauctions_application/services/voice_command_service.dart';
import 'package:fishauctions_application/services/voice_vocabulary_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_speech_backend.dart';

void main() {
  late FakeSpeechBackend backend;

  setUp(() {
    VoiceCommandService.instance.resetForTesting();
    Microphone.instance.resetForTesting();
    backend = FakeSpeechBackend();
    Microphone.instance.backendForTesting = backend;
    // Keep the vocabulary fetch off the network: this file is about what the
    // app asks the *OS* for, and a real request here is slow and flaky.
    VoiceVocabularyService.instance.offlineForTesting = true;
  });

  group('voiceGetState', () {
    // The page calls this on load. Anything it touches happens before the user
    // has shown the slightest interest in voice — which is how the microphone
    // dialog ended up appearing the moment the set-winners page rendered.
    test('never prepares the recognizer or asks for permission', () async {
      await VoiceCommandService.instance.state();
      expect(backend.prepareCalls, 0);
    });

    // The regression: SpeechToText.initialize() reports the *permission* as
    // the device's capability, so a phone that simply hadn't been asked yet
    // was told it couldn't do voice at all, and the button stayed hidden with
    // no way to change that.
    test('is supported on a capable phone with no permission yet', () async {
      backend
        ..capable = true
        ..permitted = false;
      final state = await VoiceCommandService.instance.state();
      expect(state['supported'], isTrue);
      expect(state['permission'], isFalse);
    });

    test('is unsupported when the device has no recognizer', () async {
      backend.capable = false;
      final state = await VoiceCommandService.instance.state();
      expect(state['supported'], isFalse);
      // Nothing claims permission on a phone we never got as far as asking.
      expect(state['permission'], isFalse);
    });

    test('the deployment kill switch wins over a capable device', () async {
      VoiceCommandService.instance.applyConfig(const {'enabled': false});
      final state = await VoiceCommandService.instance.state();
      expect(state['supported'], isFalse);
      expect(backend.prepareCalls, 0);
    });
  });

  group('voiceStart', () {
    test('is where the permission is actually asked for', () async {
      await VoiceCommandService.instance.start(
        auctionSlug: 'spring-auction',
        sink: (_) {},
      );
      expect(backend.prepareCalls, 1);
      expect(backend.startCalls, 1);
    });

    // A refusal has to reach the page as an error it can print, and the two
    // refusals need different words: one is "tap again", the other can only be
    // fixed in Settings.
    test('reports a refusal as an error event, not a dead button', () async {
      backend.readiness = SpeechReadiness.deniedForever;
      final events = <Map<String, dynamic>>[];
      final started = await VoiceCommandService.instance.start(
        auctionSlug: 'spring-auction',
        sink: events.add,
      );
      expect(started, isFalse);
      expect(backend.startCalls, 0);
      expect(events.single['type'], 'error');
      expect(events.single['code'], 'permission_denied');
      expect(events.single['message'], contains('settings'));
    });

    test(
      'a one-off denial says to tap again rather than to open Settings',
      () async {
        backend.readiness = SpeechReadiness.denied;
        final events = <Map<String, dynamic>>[];
        await VoiceCommandService.instance.start(
          auctionSlug: 'spring-auction',
          sink: events.add,
        );
        expect(events.single['code'], 'permission_denied');
        expect(events.single['message'], contains('Allow'));
      },
    );

    test(
      'no recognizer is reported as unavailable, not as a refusal',
      () async {
        backend.readiness = SpeechReadiness.unavailable;
        final events = <Map<String, dynamic>>[];
        await VoiceCommandService.instance.start(
          auctionSlug: 'spring-auction',
          sink: events.add,
        );
        expect(events.single['code'], 'unavailable');
      },
    );
  });
}
