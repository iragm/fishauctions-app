import '../models/voice_command.dart';
import '../models/voice_grammar.dart';
import '../models/voice_vocabulary.dart';
import 'voice_spoken_forms.dart';

/// Building the phrase-biasing list a recognizer is given before it listens.
///
/// ## Why this file exists rather than a `biasPhrases: vocabulary.everything`
///
/// **Neither platform's biasing API has any notion of a slot, a category or a
/// weight.** iOS takes `SFSpeechRecognitionRequest.contextualStrings` and
/// Android takes `RecognizerIntent.EXTRA_BIASING_STRINGS`; both are one flat
/// array of strings covering the whole utterance, and the recognizer has no
/// idea that a number it is about to emit will land in the price field rather
/// than the lot field.
///
/// That looks at first like "prices can't be biased separately from lots", and
/// it isn't, because **both APIs bias *phrases*, not words**. "seventeen
/// dollars" and "lot seventeen" are different strings. Anchoring each biased
/// value to the keyword that introduces it is what buys per-slot biasing out
/// of an API that doesn't offer any — the same trick, and for the same reason,
/// as the anchored grammar itself.
///
/// ## The budget is the hard part
///
/// Apple's guidance is around **100 phrases**, each **one or two words**;
/// longer lists and longer phrases both get *less* effective, not more, and
/// Android's model dilutes the same way even though it documents no number.
/// A 400-lot auction has far more identifiers than that, so this is a
/// selection problem, and selection has to be by expected value:
///
/// 1. **Non-numeric bidder identifiers** — `NM`, `BOB`.
///    `AuctionTOS.bidder_number` is a `CharField` and some clubs use initials,
///    which a general-purpose recognizer has essentially no chance of
///    producing unprompted. This is where biasing earns its keep, and there
///    are rarely many.
/// 2. **Low prices**, as `<n> dollars` — the "seventeen"/"seventy" pair, in a
///    domain where the small reading is usually right.
/// 3. **Non-numeric lot numbers** — seller-dash lots like `BOB-1`.
/// 4. **Numeric bidders**, anchored.
///
/// Plain numeric *lot* numbers are deliberately last and usually excluded.
/// They're the values a recognizer already gets right, and spending the whole
/// budget on four hundred of them would push out the handful of strings that
/// actually needed help.
abstract final class VoiceBiasPhrases {
  /// How many phrases to hand the recognizer.
  ///
  /// Apple's documented recommendation, and used on both platforms because the
  /// underlying reason — biasing everything is biasing nothing — isn't
  /// Apple-specific.
  static const int budget = 100;

  /// The prices worth naming when [VoiceGrammar.biasLowPrices] is on.
  ///
  /// Ends at 20 because that is where the reported distribution sits ("most
  /// lot sell prices are 5-20"), plus the round numbers above it that people
  /// actually say. Every entry is two words with its anchor, which is what
  /// keeps them inside Apple's "one or two words" guidance.
  static const List<int> lowPrices = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, //
    11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
    25, 30, 35, 40, 45, 50,
  ];

  /// The list to hand `SpeechSessionOptions.biasPhrases`.
  ///
  /// Returns an empty list when there is nothing worth biasing, which a
  /// backend must treat as "don't set the extra at all" rather than "bias
  /// towards nothing".
  static List<String> build({
    required VoiceVocabulary vocabulary,
    required VoiceGrammar grammar,
    int budget = budget,
  }) {
    final out = <String>{};

    void take(Iterable<String> phrases) {
      for (final phrase in phrases) {
        if (out.length >= budget) {
          return;
        }
        final cleaned = normalizePhrase(phrase);
        if (cleaned.isNotEmpty) {
          out.add(cleaned);
        }
      }
    }

    final lotAnchor = _anchorFor(grammar, VoiceSlot.lot);
    final bidderAnchor = _anchorFor(grammar, VoiceSlot.bidder);
    final priceAnchor = _anchorFor(grammar, VoiceSlot.price);

    final textBidders = vocabulary.bidderNumbers.where(_isNotPlainNumber);
    final numericBidders = vocabulary.bidderNumbers.where(
      (value) => !_isNotPlainNumber(value),
    );
    final textLots = vocabulary.lotNumbers.where(_isNotPlainNumber);

    take(_anchored(bidderAnchor, textBidders));
    if (grammar.biasLowPrices && priceAnchor != null) {
      // Suffix anchor: the value comes *before* "dollars", which is also what
      // makes these two-word phrases rather than three.
      take([
        for (final amount in lowPrices)
          '${cardinalToWords(amount)} $priceAnchor',
      ]);
    }
    take(_anchored(lotAnchor, textLots));
    take(_anchored(bidderAnchor, numericBidders));
    return out.toList();
  }

  /// The canonical word for a slot — the first entry in its anchor list, and
  /// only when it's a single word. A multi-word anchor ("lot number") would
  /// push every phrase past the two-word guidance for no benefit.
  static String? _anchorFor(VoiceGrammar grammar, VoiceSlot slot) {
    final words = grammar.anchors[slot];
    if (words == null || words.isEmpty || words.first.contains(' ')) {
      return null;
    }
    return words.first;
  }

  /// `<anchor> <value>` for each value, in the two readings most likely to be
  /// said aloud.
  ///
  /// Capped at two forms per value rather than the full [spokenFormsFor]
  /// expansion, which runs to 24: spending the budget on every way one bidder
  /// *could* be read leaves nothing for the other bidders, and the recognizer
  /// generalizes from a hint better than it copes with a diluted list.
  static Iterable<String> _anchored(String? anchor, Iterable<String> values) {
    if (anchor == null) {
      return const [];
    }
    return [
      for (final value in values)
        for (final form in spokenFormsFor(value).take(2)) '$anchor $form',
    ];
  }

  /// Whether a value is something other than a plain run of digits — an
  /// initial, a seller-dash lot, anything a recognizer won't produce on its
  /// own. These are the ones biasing exists for.
  static bool _isNotPlainNumber(String value) =>
      !RegExp(r'^\d+$').hasMatch(value.trim());
}
