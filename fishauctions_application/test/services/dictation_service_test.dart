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

    // Android's onDevice:true resolves to createOnDeviceSpeechRecognizer, which
    // fails outright with no downloaded language pack instead of falling back.
    // The palette is already waiting on a network call to the model, so there
    // is nothing on-device recognition would protect here.
    test('does not demand an on-device recognizer', () async {
      await DictationService.instance.start(sink: (_) {});
      expect(backend.lastOptions?.preferOnDevice, isFalse);
    });

    // The palette's microphone stayed lit until it was tapped a second time,
    // because most of the ways a phrase ends produce no final transcript to
    // stop on. Ending the session is the recognizer's job, not this one's.
    test('asks for a session that ends with the phrase', () async {
      await DictationService.instance.start(sink: (_) {});
      expect(backend.lastOptions?.continuous, isFalse);
    });

    // The silence window *is* the delay between the user finishing and the
    // microphone going off, and set-winners' three seconds — right for an
    // auctioneer mid-chant — read here as the app not noticing they had
    // stopped talking. On Android it is felt twice over: it sets the
    // recognizer's complete-silence timeout and the plugin's own timer after
    // end-of-speech.
    test(
      'ends a phrase on a browser-length silence, not an auction one',
      () async {
        await DictationService.instance.start(sink: (_) {});
        expect(backend.lastOptions?.pauseFor, DictationService.dictationPause);
        expect(
          backend.lastOptions!.pauseFor,
          lessThan(const SpeechSessionOptions().pauseFor),
        );
      },
    );

    test('reports what it heard when the recognizer ends itself', () async {
      final events = <Map<String, dynamic>>[];
      await DictationService.instance.start(sink: events.add);

      backend
        ..emit(const SpeechEvent.partial([SpeechHypothesis('lots for bob')]))
        ..emit(const SpeechEvent.state(listening: false));
      await Future<void>.delayed(Duration.zero);

      // The page acts on a final transcript — that's what runs the command —
      // and a run of partials followed by silence is a real way for a phrase
      // to end. Web Speech's own stop() delivers a last result for exactly
      // this reason.
      final transcripts = events.where((e) => e['type'] == 'transcript');
      expect(transcripts.last['text'], 'lots for bob');
      expect(transcripts.last['partial'], isFalse);
      expect(events.last['listening'], isFalse);
      expect(DictationService.instance.isListening, isFalse);
    });

    test('a cancelled session submits nothing', () async {
      final events = <Map<String, dynamic>>[];
      await DictationService.instance.start(sink: events.add);
      backend.emit(const SpeechEvent.partial([SpeechHypothesis('lots for')]));
      await Future<void>.delayed(Duration.zero);

      // Tapping the microphone off is cancelling, not submitting.
      await DictationService.instance.stop();
      await Future<void>.delayed(Duration.zero);

      final finals = events.where(
        (e) => e['type'] == 'transcript' && e['partial'] == false,
      );
      expect(finals, isEmpty);
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
