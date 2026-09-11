import 'package:fishauctions_application/models/voice_grammar.dart';
import 'package:fishauctions_application/services/bundled_voice_grammar.dart';
import 'package:fishauctions_application/services/microphone.dart';
import 'package:fishauctions_application/services/speech_backend.dart';
import 'package:fishauctions_application/services/voice_command_service.dart';
import 'package:fishauctions_application/services/voice_vocabulary_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_speech_backend.dart';
import 'voice_parser_test_support.dart';

/// Comfortably past the served settle time below.
const _settled = Duration(milliseconds: 350);

void main() {
  late FakeSpeechBackend backend;
  late List<Map<String, dynamic>> events;

  List<Map<String, dynamic>> commands() => [
    for (final event in events)
      if (event['type'] == 'command') event,
  ];

  Map<String, dynamic> lastTranscript() =>
      events.lastWhere((event) => event['type'] == 'transcript');

  Future<void> hear(String text, {bool isFinal = false}) async {
    final alternates = [SpeechHypothesis(text)];
    backend.emit(
      isFinal
          ? SpeechEvent.result(alternates)
          : SpeechEvent.partial(alternates),
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() async {
    VoiceCommandService.instance.resetForTesting();
    Microphone.instance.resetForTesting();
    backend = FakeSpeechBackend();
    Microphone.instance.backendForTesting = backend;
    VoiceVocabularyService.instance.offlineForTesting = true;
    // The shortest a deployment may serve, which keeps this file fast
    // without a fake clock.
    VoiceCommandService.instance.applyConfig(const {'commit_after_ms': 200});
    events = [];
    await VoiceCommandService.instance.start(
      auctionSlug: 'spring-auction',
      sink: events.add,
    );
    VoiceVocabularyService.instance.vocabularyForTesting = numericAuction();
  });

  tearDown(VoiceCommandService.instance.stop);

  // The report: "lot one" was on the transcript line straight away and in
  // the field five or six seconds later, because nothing was written until
  // the recognizer's final, and the final waits out a three-second silence.
  test('a value fills once the transcript stops changing', () async {
    await hear('lot forty two');
    await Future<void>.delayed(_settled);
    expect(commands().map((c) => (c['slot'], c['value'])), [('lot', '42')]);
  });

  test('a transcript still changing writes nothing yet', () async {
    await hear('lot forty');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await hear('lot forty two');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(commands(), isEmpty);
    await Future<void>.delayed(_settled);
    expect(commands().map((c) => c['value']), ['42']);
  });

  // The page matches a final itself when no command follows it. Matching one
  // whose values it already has would fill the fields twice.
  test('the final repeats nothing, and the page is told so', () async {
    await hear('lot forty two');
    await Future<void>.delayed(_settled);
    await hear('lot forty two', isFinal: true);
    expect(commands(), hasLength(1));
    expect(lastTranscript()['partial'], isTrue);
  });

  test('a final that disagrees writes the correction', () async {
    await hear('bidder seventeen');
    await Future<void>.delayed(_settled);
    await hear('bidder fifty', isFinal: true);
    expect(commands().map((c) => c['value']), ['17', '50']);
    expect(lastTranscript()['partial'], isFalse);
  });

  // A value written early and corrected is a field that changes once; a sale
  // made early is a sale. So "sold" only hurries the final along.
  test('"sold" waits for the final, and asks for it early', () async {
    await hear('sold');
    await Future<void>.delayed(_settled);
    expect(commands(), isEmpty);
    expect(backend.finishCalls, 1);

    await hear('sold', isFinal: true);
    expect(commands().single['slot'], 'sold');
  });

  test(
    'a final with nothing matched still reaches the page to match',
    () async {
      await hear('elephant', isFinal: true);
      expect(commands(), isEmpty);
      expect(lastTranscript()['partial'], isFalse);
    },
  );

  test('stopping drops a partial that has not settled', () async {
    await hear('lot forty two');
    await VoiceCommandService.instance.stop();
    await Future<void>.delayed(_settled);
    expect(commands(), isEmpty);
  });

  test('commit_after_ms 0 acts on finals only', () async {
    VoiceCommandService.instance.applyConfig(const {'commit_after_ms': 0});
    await hear('lot forty two');
    await hear('sold');
    await Future<void>.delayed(_settled);
    expect(commands(), isEmpty);
    expect(backend.finishCalls, 0);
  });

  test('commit_after_ms is served, clamped, and 0 turns it off', () {
    VoiceGrammar served(Object? value) => VoiceGrammar.fromJson({
      'commit_after_ms': value,
    }, fallback: bundledVoiceGrammar());

    expect(bundledVoiceGrammar().commitAfter, VoiceGrammar.defaultCommitAfter);
    expect(served(450).commitAfter, const Duration(milliseconds: 450));
    expect(served(5).commitAfter, const Duration(milliseconds: 200));
    expect(served(60000).commitAfter, const Duration(milliseconds: 2500));
    expect(served(0).commitAfter, isNull);
    expect(served('soon').commitAfter, VoiceGrammar.defaultCommitAfter);
  });
}
