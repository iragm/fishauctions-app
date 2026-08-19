import 'package:fishauctions_application/models/voice_command.dart';
import 'package:fishauctions_application/services/bundled_voice_grammar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_parser_test_support.dart';

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

  group('the recognizer formats money and drops the anchor', () {
    // Both platforms format their transcripts: iOS `formattedString` and
    // Android's RESULTS_RECOGNITION each turn "twenty five dollars" into "$25".
    // The digits are an improvement; losing the word "dollars" is not, because
    // it is the anchor the whole grammar hangs on — so a spoken price filled
    // nothing at all, on either platform, however clearly it was said.
    test('a currency symbol reads as the price anchor', () {
      final commands = heard(parserFor(numericAuction()), r'$25');
      expect(slot(commands, VoiceSlot.price)?.value, '25');
    });

    test('inside a whole command, with the other slots intact', () {
      final commands = heard(
        parserFor(numericAuction()),
        r'Lot 42, bidder 17, $25. Sold.',
      );
      expect(slot(commands, VoiceSlot.lot)?.value, '42');
      expect(slot(commands, VoiceSlot.bidder)?.value, '17');
      expect(slot(commands, VoiceSlot.price)?.value, '25');
      expect(slot(commands, VoiceSlot.sold), isNotNull);
    });

    test('cents survive, and the auction still gets to refuse them', () {
      expect(
        slot(
          heard(
            parserFor(numericAuction(wholeDollars: false)),
            r'lot 12 $7.50',
          ),
          VoiceSlot.price,
        )?.value,
        '7.50',
      );
      expect(
        slot(
          heard(parserFor(numericAuction()), r'lot 12 $7.50'),
          VoiceSlot.price,
        ),
        isNull,
        reason: 'only_whole_dollar_bids refuses cents rather than rounding',
      );
    });

    test('a bare number is still not a price', () {
      // The symbol is the anchor, so removing it must leave the grammar's
      // central rule exactly where it was.
      expect(
        slot(heard(parserFor(numericAuction()), '25'), VoiceSlot.price),
        isNull,
      );
    });
  });

  // The thing set-winners was reported as getting wrong. American English
  // flaps both consonants in "bidder" and "bitter" to the same sound, so no
  // recognizer can tell them apart — there is nothing in the audio to tell
  // apart — and at two plain edits the anchor was invisible to the fuzzy pass.
  // A missed anchor is total: the bidder slot never opens and the whole
  // command is silently dropped.
  group('anchors the speaker did not actually pronounce differently', () {
    test('"bitter" opens the bidder slot', () {
      final commands = heard(
        parserFor(numericAuction()),
        'bitter seventeen twenty five dollars',
      );
      expect(slot(commands, VoiceSlot.bidder)?.value, '17');
      expect(slot(commands, VoiceSlot.price)?.value, '25');
    });

    test('and lands in the unsure band, not filled silently', () {
      // It is still a guess about what was said. Filling the field while
      // visibly asking is the point: a wrong bidder costs money, and a
      // recognizer's homophone is exactly where to be seen doubting.
      final command = slot(
        heard(parserFor(numericAuction()), 'bitter seventeen'),
        VoiceSlot.bidder,
      );
      expect(command, isNotNull);
      expect(command!.confidence, lessThan(bundledVoiceGrammar().confidentAt));
      expect(command.confidence, greaterThan(bundledVoiceGrammar().unsureAt));
    });

    // "lot" is three characters, so the fuzzy pass skips it entirely and it
    // had to be transcribed exactly — on the app's single most-used anchor.
    // A trailing plural is the same word, not a guess about which word, so it
    // is the one variation safe to accept at any length.
    test('a plural still opens its slot', () {
      final commands = heard(parserFor(numericAuction()), 'lots 42');
      expect(slot(commands, VoiceSlot.lot)?.value, '42');
    });

    test('a plural is trusted more than a phonetic guess', () {
      final plural = slot(
        heard(parserFor(numericAuction()), 'lots 42'),
        VoiceSlot.lot,
      );
      final phonetic = slot(
        heard(parserFor(numericAuction()), 'bitter 17'),
        VoiceSlot.bidder,
      );
      expect(plural!.confidence, greaterThan(phonetic!.confidence));
    });

    test('a plural with nothing resolvable after it stays quiet', () {
      // "we have lots of nice fish" must not become a lot number.
      expect(heard(parserFor(numericAuction()), 'lots of nice fish'), isEmpty);
    });

    test('does not fire on words that only look close in spelling', () {
      // "collars"/"dollars" is two edits too, but c and d are not a voicing
      // pair — nobody says one and is heard saying the other. Buying the
      // homophones must not mean buying every two-edit neighbour.
      expect(heard(parserFor(numericAuction()), 'collars thirty'), isEmpty);
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
