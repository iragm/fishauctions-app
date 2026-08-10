import 'package:fishauctions_application/models/voice_command.dart';
import 'package:fishauctions_application/models/voice_settings.dart';
import 'package:fishauctions_application/services/bundled_voice_grammar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_parser_test_support.dart';

void main() {
  group('overrides on top of the served grammar', () {
    test('an untouched setting leaves the deployment in charge', () {
      // The reason every field is nullable. A device that stamped a copy of
      // today's defaults the first time the panel opened would never see a
      // single central retune again.
      final grammar = VoiceSettings.none.applyTo(bundledVoiceGrammar());
      expect(grammar.confidentAt, bundledVoiceGrammar().confidentAt);
      expect(grammar.preferOnDevice, bundledVoiceGrammar().preferOnDevice);
    });

    test('a moved slider wins over the deployment', () {
      final grammar = const VoiceSettings(
        confidentAt: 0.65,
        preferOnDevice: false,
      ).applyTo(bundledVoiceGrammar());
      expect(grammar.confidentAt, 0.65);
      expect(grammar.preferOnDevice, isFalse);
      // …and changes nothing it wasn't asked to change.
      expect(grammar.unsureAt, bundledVoiceGrammar().unsureAt);
      expect(grammar.anchors, bundledVoiceGrammar().anchors);
    });

    test('a threshold outside the slider is clamped, not dropped', () {
      // Silently keeping the old value would read, on the panel, as a control
      // that does nothing.
      expect(
        VoiceSettings.fromJson(const {'confident_at': 0.99}).confidentAt,
        VoiceSettings.maxConfidentAt,
      );
      expect(
        VoiceSettings.fromJson(const {'confident_at': 0.1}).confidentAt,
        VoiceSettings.minConfidentAt,
      );
    });

    test('the slider can never cross the unsure floor', () {
      // "Confident" being a weaker claim than "unsure" is not a state any UI
      // could explain.
      expect(
        VoiceSettings.minConfidentAt,
        greaterThan(bundledVoiceGrammar().unsureAt),
      );
    });

    test('one control at a time, without resetting the others', () {
      final merged = const VoiceSettings(
        confidentAt: 0.7,
        preferOnDevice: false,
      ).merge(const VoiceSettings(biasLowPrices: true));
      expect(merged.confidentAt, 0.7);
      expect(merged.preferOnDevice, isFalse);
      expect(merged.biasLowPrices, isTrue);
    });

    test('survives a round trip through storage', () {
      const settings = VoiceSettings(
        confidentAt: 0.75,
        preferOnDevice: false,
        biasLowPrices: true,
      );
      final restored = VoiceSettings.fromJson(settings.toJson());
      expect(restored.confidentAt, 0.75);
      expect(restored.preferOnDevice, isFalse);
      expect(restored.biasLowPrices, isTrue);
    });
  });

  // "If in doubt, guess 17 instead of 70." This works with no native code at
  // all: it picks between readings the recognizer already returned, where
  // phrase biasing changes what it returns in the first place.
  group('the low-price tie-break', () {
    List<VoiceCommand> both(String first, String second, {required bool low}) {
      final parser = VoiceParser(
        grammar: bundledVoiceGrammar().copyWith(biasLowPrices: low),
        vocabulary: numericAuction(),
      );
      return parser.parse([SpeechHypothesis(first), SpeechHypothesis(second)]);
    }

    test('takes the smaller of two tied price readings', () {
      // A price scores keyword × match with match pinned at 1, so these two
      // tie exactly and the winner used to be whichever the platform listed
      // first — i.e. nothing.
      final commands = both('seventy dollars', 'seventeen dollars', low: true);
      expect(slot(commands, VoiceSlot.price)?.value, '17');
    });

    test('regardless of which one the recognizer preferred', () {
      final commands = both('seventeen dollars', 'seventy dollars', low: true);
      expect(slot(commands, VoiceSlot.price)?.value, '17');
    });

    test('off by default, leaving the recognizer\'s order alone', () {
      final commands = both('seventy dollars', 'seventeen dollars', low: false);
      expect(slot(commands, VoiceSlot.price)?.value, '70');
    });

    test('never touches bidders, however tied they are', () {
      // The rule is a fact about what lots sell for. Bidder numbers have no
      // such distribution, and quietly preferring the lower of two candidates
      // is how the wrong person gets charged — silently, in a field that looks
      // confident.
      final parser = VoiceParser(
        grammar: bundledVoiceGrammar().copyWith(biasLowPrices: true),
        vocabulary: numericAuction(),
      );
      final commands = parser.parse([
        const SpeechHypothesis('bidder fifty'),
        const SpeechHypothesis('bidder seventeen'),
      ]);
      expect(slot(commands, VoiceSlot.bidder)?.value, '50');
    });

    test('a better-scoring reading still beats a smaller one', () {
      // The tie-break is a tie-break. An exact vocabulary hit must not lose to
      // a weaker reading just because the number is smaller.
      final parser = VoiceParser(
        grammar: bundledVoiceGrammar().copyWith(biasLowPrices: true),
        vocabulary: numericAuction(),
      );
      final commands = parser.parse([
        const SpeechHypothesis('twenty five dollars'),
        // A fuzzy anchor scores 0.6 against the exact 1.0 above.
        const SpeechHypothesis('five dollers'),
      ]);
      expect(slot(commands, VoiceSlot.price)?.value, '25');
    });
  });
}
