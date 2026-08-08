import 'package:fishauctions_application/services/dictation_service.dart';
import 'package:fishauctions_application/services/microphone.dart';
import 'package:fishauctions_application/services/speech_backend.dart';
import 'package:fishauctions_application/services/voice_command_service.dart';
import 'package:fishauctions_application/services/voice_parser.dart';
import 'package:fishauctions_application/services/voice_vocabulary_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_speech_backend.dart';

void main() {
  late FakeSpeechBackend backend;

  setUp(() {
    DictationService.instance.resetForTesting();
    VoiceCommandService.instance.resetForTesting();
    Microphone.instance.resetForTesting();
    backend = FakeSpeechBackend();
    Microphone.instance.backendForTesting = backend;
    VoiceVocabularyService.instance.offlineForTesting = true;
  });

  group('dictateGetState', () {
    // Same rule as voiceGetState: the palette asks this to decide whether to
    // show a microphone button, which happens before the user has asked for
    // anything.
    test('never prepares the recognizer', () async {
      final state = await DictationService.instance.state();
      expect(state['supported'], isTrue);
      expect(backend.prepareCalls, 0);
    });

    test('reports a phone with no recognizer as unsupported', () async {
      backend.capable = false;
      final state = await DictationService.instance.state();
      expect(state['supported'], isFalse);
    });
  });

  group('dictation', () {
    test('streams partials and stops itself on the final transcript', () async {
      final events = <Map<String, dynamic>>[];
      await DictationService.instance.start(sink: events.add);
      expect(backend.startCalls, 1);

      backend
        ..emit(const SpeechEvent.partial([SpeechHypothesis('add a lot for')]))
        ..emit(
          const SpeechEvent.result([SpeechHypothesis('add a lot for bob')]),
        );
      await Future<void>.delayed(Duration.zero);

      final transcripts = events.where((e) => e['type'] == 'transcript');
      expect(transcripts.first['partial'], isTrue);
      expect(transcripts.last['text'], 'add a lot for bob');
      expect(transcripts.last['partial'], isFalse);
      // A palette command is one sentence. Staying open would put the room —
      // or the answer being read back — into the box the user is reading.
      expect(DictationService.instance.isListening, isFalse);
      expect(backend.stopCalls, greaterThan(0));
    });

    test('a refusal comes back as an error event', () async {
      backend.readiness = SpeechReadiness.deniedForever;
      final events = <Map<String, dynamic>>[];
      final started = await DictationService.instance.start(sink: events.add);
      expect(started, isFalse);
      expect(backend.startCalls, 0);
      expect(events.single['code'], 'permission_denied');
    });
  });

  // One microphone, one recognizer. Two SpeechToText objects contend for the
  // same platform service rather than giving you two — and these two features
  // overlap on exactly one screen, since the palette opens over the
  // set-winners page.
  group('microphone arbitration', () {
    test('starting voice stops dictation', () async {
      await DictationService.instance.start(sink: (_) {});
      expect(Microphone.instance.holder, 'dictation');

      await VoiceCommandService.instance.start(
        auctionSlug: 'spring-auction',
        sink: (_) {},
      );
      expect(Microphone.instance.holder, 'voice');
      expect(DictationService.instance.isListening, isFalse);
    });

    test('starting dictation stops voice', () async {
      await VoiceCommandService.instance.start(
        auctionSlug: 'spring-auction',
        sink: (_) {},
      );
      expect(VoiceCommandService.instance.isListening, isTrue);

      await DictationService.instance.start(sink: (_) {});
      expect(Microphone.instance.holder, 'dictation');
      expect(VoiceCommandService.instance.isListening, isFalse);
    });

    test('a late stop cannot evict whoever claimed it since', () async {
      await DictationService.instance.start(sink: (_) {});
      await VoiceCommandService.instance.start(
        auctionSlug: 'spring-auction',
        sink: (_) {},
      );
      // The dictation session is already over; its stop must not take the
      // microphone away from the voice session that replaced it.
      await DictationService.instance.stop();
      expect(Microphone.instance.holder, 'voice');
    });
  });
}
