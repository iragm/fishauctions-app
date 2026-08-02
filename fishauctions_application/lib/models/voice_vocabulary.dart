import '../services/voice_spoken_forms.dart';

/// How well an utterance matched the closed vocabulary. The numbers are the
/// table in `VOICE.md` §4.2 and feed straight into the confidence score.
class VocabularyMatch {
  const VocabularyMatch({
    required this.value,
    required this.score,
    required this.consumed,
    this.candidates = const [],
  });

  /// The value exactly as the auction stores it — `'42'`, `'BOB'`, `'BOB-1'`.
  /// Case and dashes are preserved; the page writes this verbatim into the
  /// form, so it has to be what the server will accept.
  final String value;

  /// 0..1 quality of the match.
  final double score;

  /// How many leading tokens of the phrase this match used. Lets the caller
  /// hand the remaining tokens to another slot ("bidder seventeen twenty five
  /// dollars").
  final int consumed;

  /// Other values that matched about as well. Non-empty only for a genuinely
  /// ambiguous match, so the page can ask instead of guessing.
  final List<String> candidates;
}

/// Scores for each match outcome. Named so the reasoning stays visible at the
/// call site rather than being four bare literals.
///
/// The values are chosen against the default thresholds (confident 0.85,
/// unsure 0.5) and a neutral platform confidence, so that each outcome lands
/// in the tier it's described as landing in:
///
/// | outcome   | typical confidence | tier      |
/// |-----------|--------------------|-----------|
/// | exact     | 0.89               | confident |
/// | fuzzy     | 0.72               | unsure    |
/// | ambiguous | 0.58               | unsure    |
/// | unknown   | 0.55               | unsure    |
///
/// Only an exact hit on a value this auction really has is ever filled
/// silently. Everything else fills the field *and* visibly asks — and a weak
/// match compounded with a weak anchor keyword falls below 0.5 and isn't
/// written at all.
abstract final class VocabularyScore {
  /// The phrase is a spoken form of exactly one value.
  static const double exact = 1;

  /// One value within edit distance 1 — a plausible mishearing, but only one
  /// thing it could have been.
  static const double fuzzy = 0.8;

  /// Two or more values are equally plausible. Stays in the unsure band on
  /// purpose: the point of detecting ambiguity is to offer the pick-list, and
  /// a command that never reaches the page can't offer anything.
  static const double ambiguous = 0.65;

  /// Parses as an identifier but isn't in the vocabulary. Not zero, because a
  /// bidder registered thirty seconds ago is genuinely absent from the last
  /// vocabulary fetch — and a voice pipeline that silently ignores them would
  /// send the operator back to the keyboard exactly when the hall is busiest.
  static const double unknown = 0.62;
}

/// The set of identifiers that are legal answers in one auction, indexed by
/// how they're said.
///
/// Built once per fetch — expanding a few hundred values into spoken forms is
/// the expensive part and must not happen per utterance.
class VoiceVocabulary {
  VoiceVocabulary({
    required this.lotNumbers,
    required this.bidderNumbers,
    required this.onlyWholeDollarBids,
    this.currencySymbol = r'$',
  }) : _lotIndex = _buildIndex(lotNumbers),
       _bidderIndex = _buildIndex(bidderNumbers);

  factory VoiceVocabulary.fromJson(Map<String, dynamic> json) =>
      VoiceVocabulary(
        lotNumbers: _stringList(json['lot_numbers']),
        bidderNumbers: _stringList(json['bidder_numbers']),
        onlyWholeDollarBids: json['only_whole_dollar_bids'] == true,
        currencySymbol: json['currency_symbol'] is String
            ? json['currency_symbol'] as String
            : r'$',
      );

  /// An empty vocabulary. Every match against it lands on
  /// [VocabularyScore.unknown], so voice still runs — everything is just
  /// marked unsure, which is the honest outcome when we can't check.
  static final VoiceVocabulary empty = VoiceVocabulary(
    lotNumbers: const [],
    bidderNumbers: const [],
    onlyWholeDollarBids: false,
  );

  /// `lot_number_display` for the auction's unsold lots, verbatim.
  final List<String> lotNumbers;

  /// `AuctionTOS.bidder_number` (plus club-managed shadows), verbatim. These
  /// are `CharField`s and often text — see [VoiceVocabulary] docs.
  final List<String> bidderNumbers;

  /// When true the price parser refuses cents, which deletes a whole class of
  /// error. The server enforces the same rule in `validate_price`.
  final bool onlyWholeDollarBids;

  final String currencySymbol;

  final Map<String, List<String>> _lotIndex;
  final Map<String, List<String>> _bidderIndex;

  bool get isEmpty => lotNumbers.isEmpty && bidderNumbers.isEmpty;

  static Map<String, List<String>> _buildIndex(List<String> values) {
    final index = <String, List<String>>{};
    for (final value in values) {
      if (value.trim().isEmpty) {
        continue;
      }
      for (final form in spokenFormsFor(value)) {
        (index[form] ??= <String>[]).add(value);
      }
    }
    return index;
  }

  static List<String> _stringList(Object? raw) => raw is List
      ? [
          for (final item in raw)
            if (item != null && '$item'.trim().isNotEmpty) '$item',
        ]
      : const [];

  /// Best interpretation of [tokens] as a lot identifier.
  VocabularyMatch? matchLot(List<String> tokens) =>
      _match(tokens, _lotIndex, lotNumbers);

  /// Best interpretation of [tokens] as a bidder identifier.
  VocabularyMatch? matchBidder(List<String> tokens) =>
      _match(tokens, _bidderIndex, bidderNumbers);

  /// Longest-first prefix search: the phrase after an anchor can run into the
  /// next command ("bidder seventeen twenty five dollars"), so try the longest
  /// prefix that the vocabulary recognises and report how much it used.
  VocabularyMatch? _match(
    List<String> tokens,
    Map<String, List<String>> index,
    List<String> values,
  ) {
    if (tokens.isEmpty) {
      return null;
    }
    for (var length = tokens.length; length >= 1; length--) {
      final phrase = tokens.take(length).join(' ');
      final hits = index[phrase];
      if (hits == null || hits.isEmpty) {
        continue;
      }
      final distinct = hits.toSet().toList();
      if (distinct.length == 1) {
        return VocabularyMatch(
          value: distinct.first,
          score: VocabularyScore.exact,
          consumed: length,
        );
      }
      // The same spoken form belongs to two different values — the one case
      // where the recognizer was right and the data is still ambiguous.
      return VocabularyMatch(
        value: distinct.first,
        score: VocabularyScore.ambiguous,
        consumed: length,
        candidates: distinct,
      );
    }
    return _fuzzy(tokens, index) ?? _literal(tokens, values);
  }

  /// Nothing matched exactly; look for keys one edit away. Only the whole
  /// phrase is tried fuzzily — allowing fuzzy *prefixes* too would match
  /// almost anything against a large auction.
  VocabularyMatch? _fuzzy(
    List<String> tokens,
    Map<String, List<String>> index,
  ) {
    final phrase = tokens.join(' ');
    if (phrase.length < 3) {
      return null;
    }
    final near = <String>{};
    for (final key in index.keys) {
      if (boundedEditDistance(phrase, key, 1) <= 1) {
        near.addAll(index[key]!);
      }
    }
    if (near.isEmpty) {
      return null;
    }
    final values = near.toList();
    return VocabularyMatch(
      value: values.first,
      score: values.length == 1
          ? VocabularyScore.fuzzy
          : VocabularyScore.ambiguous,
      consumed: tokens.length,
      candidates: values.length == 1 ? const [] : values,
    );
  }

  /// Last resort: the phrase reads as an identifier but this auction has no
  /// such value. Returns it anyway at [VocabularyScore.unknown] so a
  /// just-registered bidder can still be typed — marked unsure, and the
  /// server refuses it if it really doesn't exist.
  VocabularyMatch? _literal(List<String> tokens, List<String> values) {
    final digits = parseDigitString(tokens);
    final cardinal = parseCardinal(tokens);
    final spelled = parseSpelledLetters(tokens);
    final guess = digits ?? (cardinal != null ? '$cardinal' : spelled);
    if (guess == null) {
      return null;
    }
    // Don't invent a value when we have a real vocabulary and it disagrees
    // about *everything* — that means we misheard, not that the data is
    // stale. With no vocabulary at all (fetch failed) we have no such signal.
    if (values.isNotEmpty && tokens.length > 3) {
      return null;
    }
    return VocabularyMatch(
      value: guess,
      score: VocabularyScore.unknown,
      consumed: tokens.length,
    );
  }
}
