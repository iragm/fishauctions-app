import 'package:fishauctions_application/models/voice_command.dart';
import 'package:fishauctions_application/models/voice_grammar.dart';
import 'package:fishauctions_application/services/bundled_voice_grammar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceGrammar config merge', () {
    test('an absent block leaves the bundled defaults alone', () {
      final grammar = bundledVoiceGrammar();
      expect(grammar.enabled, isTrue);
      expect(grammar.anchors[VoiceSlot.lot]?.first, 'lot');
      expect(grammar.confidentAt, 0.85);
    });

    test('overriding one anchor list keeps the rest', () {
      // The point of serving the grammar: a hall that says "paddle" should be
      // a Django edit, not an app release — and not a rewrite of every other
      // anchor either.
      final grammar = VoiceGrammar.fromJson(const {
        'anchors': {
          'bidder': ['paddle', 'bidder'],
        },
      }, fallback: bundledVoiceGrammar());
      expect(grammar.anchors[VoiceSlot.bidder], ['paddle', 'bidder']);
      expect(grammar.anchors[VoiceSlot.lot]?.first, 'lot');
      expect(grammar.anchors[VoiceSlot.sold]?.first, 'sold');
    });

    test('thresholds and weights come through', () {
      final grammar = VoiceGrammar.fromJson(const {
        'thresholds': {'confident': 0.95, 'unsure': 0.6},
        'weights': {'agreement': 0.8},
      }, fallback: bundledVoiceGrammar());
      expect(grammar.confidentAt, 0.95);
      expect(grammar.unsureAt, 0.6);
      expect(grammar.weights.agreement, 0.8);
    });

    test('enabled:false is the kill switch', () {
      final grammar = VoiceGrammar.fromJson(const {
        'enabled': false,
      }, fallback: bundledVoiceGrammar());
      expect(grammar.enabled, isFalse);
    });

    test('a malformed block is ignored rather than fatal', () {
      final grammar = VoiceGrammar.fromJson(const {
        'anchors': 'not a map',
        'thresholds': 42,
        'enabled': 'yes',
      }, fallback: bundledVoiceGrammar());
      expect(grammar.enabled, isTrue);
      expect(grammar.anchors[VoiceSlot.lot]?.first, 'lot');
      expect(grammar.confidentAt, 0.85);
    });

    test('anchorFor ranks the canonical word above its synonyms', () {
      final grammar = bundledVoiceGrammar();
      expect(grammar.anchorFor('bidder')?.quality, 1.0);
      expect(grammar.anchorFor('buyer')?.quality, 0.8);
      expect(grammar.anchorFor('elephant'), isNull);
    });
  });

  group('VoiceCommand', () {
    test('tiers split at the configured thresholds', () {
      VoiceConfidenceTier tierOf(double confidence) => VoiceCommand(
        slot: VoiceSlot.lot,
        confidence: confidence,
        heard: '',
      ).tierFor(confidentAt: 0.85, unsureAt: 0.5);

      expect(tierOf(0.9), VoiceConfidenceTier.confident);
      expect(tierOf(0.85), VoiceConfidenceTier.confident);
      expect(tierOf(0.7), VoiceConfidenceTier.unsure);
      expect(tierOf(0.5), VoiceConfidenceTier.unsure);
      expect(tierOf(0.4), VoiceConfidenceTier.rejected);
    });

    test('serializes to the shape the page receives', () {
      final json = const VoiceCommand(
        slot: VoiceSlot.bidder,
        value: 'BOB',
        confidence: 0.912345,
        heard: 'bidder bob',
        candidates: ['BOB', 'BOB-1'],
        blockedBy: ['price'],
      ).toJson();
      expect(json['type'], 'command');
      expect(json['slot'], 'bidder');
      expect(json['value'], 'BOB');
      expect(json['confidence'], 0.912);
      expect(json['heard'], 'bidder bob');
      expect(json['candidates'], ['BOB', 'BOB-1']);
      expect(json['blocked_by'], ['price']);
    });

    test('only value slots can block a save', () {
      expect(VoiceSlot.lot.isValueSlot, isTrue);
      expect(VoiceSlot.bidder.isValueSlot, isTrue);
      expect(VoiceSlot.price.isValueSlot, isTrue);
      expect(VoiceSlot.sold.isValueSlot, isFalse);
      expect(VoiceSlot.undo.isValueSlot, isFalse);
    });
  });

  group('confidence composition', () {
    const weights = VoiceConfidenceWeights();

    test('a missing platform rating does not read as doubt', () {
      // speech_to_text reports -1 constantly; callers substitute the neutral
      // prior, and an otherwise perfect match must still clear "confident".
      const inputs = VoiceConfidenceInputs(keyword: 1, match: 1, agreement: 1);
      expect(inputs.score(weights), greaterThanOrEqualTo(0.85));
    });

    test('a bad platform rating alone cannot wave a value through', () {
      const inputs = VoiceConfidenceInputs(
        asr: 0.1,
        keyword: 1,
        match: 1,
        agreement: 1,
      );
      expect(inputs.score(weights), lessThan(0.85));
    });

    test('disagreeing alternates demote an otherwise perfect match', () {
      const agreeing = VoiceConfidenceInputs(
        keyword: 1,
        match: 1,
        agreement: 1,
      );
      const split = VoiceConfidenceInputs(keyword: 1, match: 1, agreement: 0.5);
      expect(split.score(weights), lessThan(agreeing.score(weights)));
      expect(split.score(weights), lessThan(0.85));
    });

    test('stays within 0..1 for absurd inputs', () {
      const inputs = VoiceConfidenceInputs(
        asr: 5,
        keyword: 3,
        match: 2,
        agreement: 9,
      );
      expect(inputs.score(weights), lessThanOrEqualTo(1.0));
      expect(inputs.score(weights), greaterThanOrEqualTo(0.0));
    });
  });
}
