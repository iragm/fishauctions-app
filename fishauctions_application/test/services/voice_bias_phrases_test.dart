import 'package:fishauctions_application/models/voice_grammar.dart';
import 'package:fishauctions_application/models/voice_vocabulary.dart';
import 'package:fishauctions_application/services/bundled_voice_grammar.dart';
import 'package:fishauctions_application/services/voice_bias_phrases.dart';
import 'package:flutter_test/flutter_test.dart';

VoiceVocabulary clubAuction() => VoiceVocabulary(
  lotNumbers: const ['1', '2', '3', '42', 'BOB-1'],
  // What a real club looks like: initials alongside numbers, because
  // AuctionTOS.bidder_number is a CharField and nothing stops it.
  bidderNumbers: const ['4', '17', 'NM', 'BOB'],
  onlyWholeDollarBids: true,
);

VoiceGrammar grammarWith({bool biasLowPrices = false}) =>
    bundledVoiceGrammar().copyWith(biasLowPrices: biasLowPrices);

void main() {
  // The question this whole file answers: neither platform's biasing API has
  // any notion of a slot, so the separation has to come from the *phrases*.
  // "seventeen dollars" and "lot seventeen" are different strings, which is
  // what makes "bias prices low" expressible without also telling the
  // recognizer that lot 70 is unlikely.
  group('per-slot biasing out of a flat API', () {
    test('prices are biased without touching lots or bidders', () {
      final phrases = VoiceBiasPhrases.build(
        vocabulary: clubAuction(),
        grammar: grammarWith(biasLowPrices: true),
      );
      expect(phrases, contains('seventeen dollars'));
      // The same number in the lot position is not implied by that, and must
      // not be: it's a different string and the recognizer treats it as one.
      expect(phrases, isNot(contains('seventeen')));
      expect(phrases, isNot(contains('lot seventeen')));
    });

    test('the price list is off unless asked for', () {
      final phrases = VoiceBiasPhrases.build(
        vocabulary: clubAuction(),
        grammar: grammarWith(),
      );
      expect(phrases.any((p) => p.endsWith(' dollars')), isFalse);
    });

    test('every phrase carries the anchor of exactly one slot', () {
      final phrases = VoiceBiasPhrases.build(
        vocabulary: clubAuction(),
        grammar: grammarWith(biasLowPrices: true),
      );
      for (final phrase in phrases) {
        final anchored =
            phrase.startsWith('lot ') ||
            phrase.startsWith('bidder ') ||
            phrase.endsWith(' dollars');
        expect(anchored, isTrue, reason: '"$phrase" belongs to no slot');
      }
    });
  });

  group('spending a budget of about a hundred', () {
    test('identifiers a recognizer cannot guess come first', () {
      // Initials are the whole reason to bias at all: no general-purpose model
      // produces "NM" for a bidder unprompted, and there are never many.
      final phrases = VoiceBiasPhrases.build(
        vocabulary: clubAuction(),
        grammar: grammarWith(biasLowPrices: true),
        budget: 4,
      );
      expect(phrases, hasLength(4));
      expect(phrases.every((p) => p.startsWith('bidder ')), isTrue);
      expect(phrases.join(' '), contains('n m'));
    });

    test('a large auction does not blow past the budget', () {
      final huge = VoiceVocabulary(
        lotNumbers: [for (var i = 1; i <= 800; i++) '$i'],
        bidderNumbers: [for (var i = 1; i <= 200; i++) '$i'],
        onlyWholeDollarBids: true,
      );
      final phrases = VoiceBiasPhrases.build(
        vocabulary: huge,
        grammar: grammarWith(biasLowPrices: true),
      );
      expect(phrases.length, lessThanOrEqualTo(VoiceBiasPhrases.budget));
    });

    test('phrases stay short enough to be worth biasing', () {
      // Apple's guidance is one or two words; longer phrases are *less*
      // likely to be recognized, so a long list of long strings is the worst
      // of both.
      final phrases = VoiceBiasPhrases.build(
        vocabulary: clubAuction(),
        grammar: grammarWith(biasLowPrices: true),
      );
      expect(phrases, isNotEmpty);
      for (final phrase in phrases) {
        expect(phrase.split(' ').length, lessThanOrEqualTo(4));
      }
    });

    test('an empty vocabulary asks for no biasing at all', () {
      final phrases = VoiceBiasPhrases.build(
        vocabulary: VoiceVocabulary.empty,
        grammar: grammarWith(),
      );
      expect(phrases, isEmpty);
    });
  });
}
