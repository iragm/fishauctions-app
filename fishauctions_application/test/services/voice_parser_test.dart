import 'package:fishauctions_application/models/voice_command.dart';
import 'package:fishauctions_application/models/voice_vocabulary.dart';
import 'package:fishauctions_application/services/bundled_voice_grammar.dart';
import 'package:fishauctions_application/services/voice_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// A numeric auction, the common case.
VoiceVocabulary numericAuction({bool wholeDollars = true}) => VoiceVocabulary(
  lotNumbers: const ['1', '12', '42', '105'],
  bidderNumbers: const ['4', '17', '50', '105'],
  onlyWholeDollarBids: wholeDollars,
);

/// A seller-dash auction with text bidder numbers — `AuctionTOS.bidder_number`
/// is a CharField and this is what it looks like when someone uses it.
VoiceVocabulary textAuction() => VoiceVocabulary(
  lotNumbers: const ['BOB-1', 'BOB-2', 'ANN-1', '3-1'],
  bidderNumbers: const ['BOB', 'ANN', '3'],
  onlyWholeDollarBids: true,
);

VoiceParser parserFor(VoiceVocabulary vocabulary) =>
    VoiceParser(grammar: bundledVoiceGrammar(), vocabulary: vocabulary);

List<VoiceCommand> heard(VoiceParser parser, String text, {double asr = -1}) =>
    parser.parse([SpeechHypothesis(text, confidence: asr)]);

VoiceCommand? slot(List<VoiceCommand> commands, VoiceSlot wanted) {
  for (final command in commands) {
    if (command.slot == wanted) {
      return command;
    }
  }
  return null;
}

void main() {
  group('anchored slots', () {
    test('fills lot, bidder and price from one utterance', () {
      // A continuous recognizer hands back whole sentences, not one command
      // at a time.
      final commands = heard(
        parserFor(numericAuction()),
        'lot forty two bidder seventeen twenty five dollars',
      );
      expect(slot(commands, VoiceSlot.lot)?.value, '42');
      expect(slot(commands, VoiceSlot.bidder)?.value, '17');
      expect(slot(commands, VoiceSlot.price)?.value, '25');
    });

    test('emits in the order they were spoken', () {
      final commands = heard(
        parserFor(numericAuction()),
        'lot twelve bidder four fifty dollars sold',
      );
      expect(commands.map((c) => c.slot).toList(), [
        VoiceSlot.lot,
        VoiceSlot.bidder,
        VoiceSlot.price,
        VoiceSlot.sold,
      ]);
    });

    test('a bare number writes nothing without an anchor', () {
      // The whole reason the grammar is anchored: an auctioneer's chant and
      // the crowd are full of numbers, and none of them are commands.
      expect(heard(parserFor(numericAuction()), 'forty two'), isEmpty);
      expect(
        heard(parserFor(numericAuction()), 'do I hear one hundred five'),
        isEmpty,
      );
    });

    test('recognises standalone actions', () {
      final parser = parserFor(numericAuction());
      expect(slot(heard(parser, 'sold'), VoiceSlot.sold), isNotNull);
      expect(slot(heard(parser, 'undo'), VoiceSlot.undo), isNotNull);
      expect(slot(heard(parser, 'no sale'), VoiceSlot.unsold), isNotNull);
    });

    test('multi-word anchors beat their first word', () {
      // "lot number five" must not fire on "lot" and then try to resolve
      // "number five" as an identifier.
      final commands = heard(parserFor(numericAuction()), 'lot number twelve');
      expect(slot(commands, VoiceSlot.lot)?.value, '12');
    });
  });

  group('splitting a run of numbers between two slots', () {
    test('the vocabulary decides where the seam is', () {
      // "seventeen twenty five" is pending with the bidder slot still open;
      // 17 being a real bidder is the evidence that the seam is after it.
      final commands = heard(
        parserFor(numericAuction()),
        'bidder seventeen twenty five dollars',
      );
      expect(slot(commands, VoiceSlot.bidder)?.value, '17');
      expect(slot(commands, VoiceSlot.price)?.value, '25');
    });

    test('a price with no open slot is still a price', () {
      final commands = heard(parserFor(numericAuction()), 'thirty dollars');
      expect(slot(commands, VoiceSlot.price)?.value, '30');
    });
  });

  group('text bidder numbers and seller-dash lots', () {
    test('matches a spoken text bidder number', () {
      final commands = heard(parserFor(textAuction()), 'bidder bob');
      expect(slot(commands, VoiceSlot.bidder)?.value, 'BOB');
    });

    test('matches a spelled text bidder number', () {
      expect(
        slot(
          heard(parserFor(textAuction()), 'bidder bee oh bee'),
          VoiceSlot.bidder,
        )?.value,
        'BOB',
      );
      expect(
        slot(
          heard(parserFor(textAuction()), 'bidder bravo oscar bravo'),
          VoiceSlot.bidder,
        )?.value,
        'BOB',
      );
    });

    test('matches a seller-dash lot number, dash spoken or not', () {
      final parser = parserFor(textAuction());
      expect(slot(heard(parser, 'lot bob one'), VoiceSlot.lot)?.value, 'BOB-1');
      expect(
        slot(heard(parser, 'lot bob dash two'), VoiceSlot.lot)?.value,
        'BOB-2',
      );
      expect(slot(heard(parser, 'lot three one'), VoiceSlot.lot)?.value, '3-1');
    });

    test('keeps the value in the auction\'s own casing', () {
      // The page writes this straight into the form, so it has to be what the
      // server will accept — not a normalized version of it.
      expect(
        slot(
          heard(parserFor(textAuction()), 'lot ann one'),
          VoiceSlot.lot,
        )?.value,
        'ANN-1',
      );
    });
  });

  group('confidence', () {
    test('an exact match on a real value is confident', () {
      final command = slot(
        heard(parserFor(numericAuction()), 'lot forty two', asr: 0.9),
        VoiceSlot.lot,
      );
      expect(command!.confidence, greaterThanOrEqualTo(0.85));
    });

    test('is meaningful even when the platform reports nothing', () {
      // speech_to_text returns -1 far more often than expected — iOS
      // on-device results and Android partials routinely have no rating. A
      // design that keys off it alone would mark everything unsure.
      final command = slot(
        heard(parserFor(numericAuction()), 'lot forty two'),
        VoiceSlot.lot,
      );
      expect(command!.confidence, greaterThanOrEqualTo(0.85));
    });

    test('a value this auction does not have is filled but unsure', () {
      // A bidder registered thirty seconds ago is genuinely absent from the
      // last vocabulary fetch, so this can't be a hard reject.
      final command = slot(
        heard(parserFor(numericAuction()), 'bidder nine'),
        VoiceSlot.bidder,
      );
      expect(command!.value, '9');
      expect(command.confidence, lessThan(0.85));
      expect(command.confidence, greaterThanOrEqualTo(0.5));
    });

    test('an ambiguous match fills, asks, and names the candidates', () {
      // A real collision in a seller-dash auction: lot "11" and lot "1-1" are
      // both said "one one". The recognizer was right and the data is still
      // ambiguous, which is the one case that has to reach the operator.
      final vocabulary = VoiceVocabulary(
        lotNumbers: const ['11', '1-1'],
        bidderNumbers: const [],
        onlyWholeDollarBids: true,
      );
      final command = slot(
        heard(parserFor(vocabulary), 'lot one one'),
        VoiceSlot.lot,
      );
      expect(command, isNotNull);
      expect(command!.confidence, lessThan(0.85));
      expect(command.confidence, greaterThanOrEqualTo(0.5));
      expect(command.candidates, containsAll(['11', '1-1']));
    });

    test('disagreement between alternates lowers confidence', () {
      final parser = parserFor(numericAuction());
      final agreeing = parser.parse(const [
        SpeechHypothesis('lot forty two'),
        SpeechHypothesis('lot forty two'),
      ]);
      final disagreeing = parser.parse(const [
        SpeechHypothesis('lot forty two'),
        SpeechHypothesis('lot twelve'),
      ]);
      expect(
        slot(disagreeing, VoiceSlot.lot)!.confidence,
        lessThan(slot(agreeing, VoiceSlot.lot)!.confidence),
      );
    });

    test('scores every alternate, not just the recognizer\'s first', () {
      // The top string is often the one that isn't a real lot number.
      final commands = parserFor(numericAuction()).parse(const [
        SpeechHypothesis('lot 43'),
        SpeechHypothesis('lot forty two'),
      ]);
      expect(slot(commands, VoiceSlot.lot)?.value, '42');
    });
  });

  group('prices', () {
    test('refuses cents when the auction is whole-dollar only', () {
      // validate_price enforces the same rule server-side; refusing here
      // deletes the error before it reaches a field.
      final commands = heard(
        parserFor(numericAuction()),
        'lot twelve 25.50 dollars',
      );
      expect(slot(commands, VoiceSlot.price), isNull);
    });

    test('accepts cents when the auction allows them', () {
      final commands = heard(
        parserFor(numericAuction(wholeDollars: false)),
        'lot twelve 25.50 dollars',
      );
      expect(slot(commands, VoiceSlot.price)?.value, '25.50');
    });

    test('reads an explicit cents phrase', () {
      final commands = heard(
        parserFor(numericAuction(wholeDollars: false)),
        'twenty five dollars and fifty cents',
      );
      expect(slot(commands, VoiceSlot.price)?.value, '25.50');
    });

    test('reads a multi-word amount as one number', () {
      expect(
        slot(
          heard(parserFor(numericAuction()), 'one hundred five dollars'),
          VoiceSlot.price,
        )?.value,
        '105',
      );
    });
  });
}
