import '../models/voice_command.dart';
import '../models/voice_grammar.dart';
import '../models/voice_vocabulary.dart';
import 'voice_spoken_forms.dart';

/// One hypothesis from the recognizer: what it thinks was said, and how sure
/// it is. [confidence] is `-1` when the platform didn't say — which is common
/// enough that nothing downstream may treat it as "not confident".
class SpeechHypothesis {
  const SpeechHypothesis(this.text, {this.confidence = -1});

  final String text;
  final double confidence;

  bool get hasConfidence => confidence >= 0;
}

/// How an anchor keyword relates to the value it marks.
enum _AnchorKind {
  /// The value follows the keyword: "lot forty two".
  prefix,

  /// The value precedes the keyword: "twenty five dollars".
  suffix,

  /// No value at all: "sold".
  standalone,
}

_AnchorKind _kindOf(VoiceSlot slot) => switch (slot) {
  VoiceSlot.lot || VoiceSlot.bidder => _AnchorKind.prefix,
  VoiceSlot.price => _AnchorKind.suffix,
  _ => _AnchorKind.standalone,
};

class _Parsed {
  _Parsed({
    required this.slot,
    required this.keyword,
    required this.match,
    required this.heard,
    required this.order,
    this.value = '',
    this.candidates = const [],
  });

  final VoiceSlot slot;
  final String value;
  final double keyword;
  final double match;
  final String heard;
  final int order;
  final List<String> candidates;

  /// Ranking key for choosing between hypotheses. Confidence proper is
  /// computed later, once agreement across hypotheses is known.
  double get rank => keyword * match;
}

class _AnchorHit {
  const _AnchorHit(this.slot, this.quality, this.length);

  final VoiceSlot slot;
  final double quality;
  final int length;
}

/// Turns what the recognizer heard into commands for the set-winners page.
///
/// The shape of the grammar is v1's one good idea, kept: every value slot
/// needs an anchor keyword, so a bare number writes nothing and the
/// auctioneer's chant can't corrupt a field. Everything else is different —
/// notably that values are resolved against [VoiceVocabulary] (the identifiers
/// that actually exist in this auction) rather than parsed out of free text.
class VoiceParser {
  VoiceParser({required this.grammar, required this.vocabulary});

  final VoiceGrammar grammar;
  final VoiceVocabulary vocabulary;

  /// Score every hypothesis, then take the best reading of each slot.
  ///
  /// Using all the alternates rather than only the recognizer's top string is
  /// worth real accuracy: the top string is often the one that *doesn't* match
  /// a real lot number. Where the alternates disagree, that disagreement is
  /// the honest confidence signal, and it feeds [VoiceConfidenceInputs].
  List<VoiceCommand> parse(List<SpeechHypothesis> hypotheses) {
    if (hypotheses.isEmpty) {
      return const [];
    }
    final considered = hypotheses.take(grammar.maxAlternates).toList();
    final readings = <List<_Parsed>>[];
    for (final hypothesis in considered) {
      readings.add(_parseText(hypothesis.text));
    }

    // Best reading per slot, across hypotheses.
    final best = <VoiceSlot, _Parsed>{};
    final bestAsr = <VoiceSlot, double>{};
    for (var i = 0; i < readings.length; i++) {
      final asr = considered[i].hasConfidence
          ? considered[i].confidence
          : VoiceConfidenceInputs.neutralAsr;
      for (final parsed in readings[i]) {
        if (_beats(parsed, best[parsed.slot])) {
          best[parsed.slot] = parsed;
          bestAsr[parsed.slot] = asr;
        }
      }
    }
    if (best.isEmpty) {
      return const [];
    }

    final commands = <VoiceCommand>[];
    for (final entry in best.entries) {
      final slot = entry.key;
      final parsed = entry.value;
      final confidence = VoiceConfidenceInputs(
        asr: bestAsr[slot] ?? VoiceConfidenceInputs.neutralAsr,
        keyword: parsed.keyword,
        match: parsed.match,
        agreement: _agreement(readings, parsed),
      ).score(grammar.weights);
      if (confidence < grammar.unsureAt) {
        // Below the floor nothing is written at all — the transcript line is
        // the only feedback, so the operator knows they were heard but not
        // understood.
        continue;
      }
      commands.add(
        VoiceCommand(
          slot: slot,
          value: parsed.value,
          confidence: confidence,
          heard: parsed.heard,
          candidates: parsed.candidates,
        ),
      );
    }
    // Emit in the order the operator said them, so the page fills fields in a
    // sensible sequence and a trailing "sold" lands last.
    commands.sort((a, b) {
      final orderA = best[a.slot]?.order ?? 0;
      final orderB = best[b.slot]?.order ?? 0;
      return orderA.compareTo(orderB);
    });
    return commands;
  }

  /// Whether [challenger] should replace [incumbent] as the reading of its
  /// slot.
  ///
  /// Score first, and for everything except a tie that is the whole story.
  /// Ties are common and were being broken by nothing better than the order
  /// the recognizer happened to list its alternates in: a price reading scores
  /// `keyword × match` with `match` fixed at 1, so **"seventeen dollars" and
  /// "seventy dollars" tie exactly**, and whichever the platform put first won.
  bool _beats(_Parsed challenger, _Parsed? incumbent) {
    if (incumbent == null) {
      return true;
    }
    if (challenger.rank != incumbent.rank) {
      return challenger.rank > incumbent.rank;
    }
    return _prefersLower(challenger, incumbent);
  }

  /// The low-price tie-break, on for [VoiceGrammar.biasLowPrices].
  ///
  /// A domain fact rather than a general heuristic: these lots mostly sell for
  /// single-digit to twenty-dollar sums, so when the recognizer genuinely
  /// can't tell "seventeen" from "seventy" the smaller reading is right far
  /// more often. It costs nothing to be wrong occasionally here — the operator
  /// is looking at the price field and a mistyped price is corrected in place.
  ///
  /// **Prices only, and it must stay that way.** Bidder and lot numbers have
  /// no such distribution — they're drawn from whatever the auction assigned —
  /// and quietly preferring the lower of two candidate *bidders* is how the
  /// wrong person gets charged, silently, with the field looking confident.
  ///
  /// Note that this is a separate mechanism from phrase biasing and works with
  /// no native code at all: biasing changes what the recognizer *offers*, this
  /// changes which of two things it already offered we take.
  bool _prefersLower(_Parsed challenger, _Parsed incumbent) {
    if (!grammar.biasLowPrices || challenger.slot != VoiceSlot.price) {
      return false;
    }
    final a = double.tryParse(challenger.value);
    final b = double.tryParse(incumbent.value);
    if (a == null || b == null) {
      return false;
    }
    return a < b;
  }

  /// Fraction of the hypotheses that produced this slot at all and agreed with
  /// [winner]'s value. A slot only one hypothesis saw scores 1.0 — there's
  /// nothing to disagree with, and penalising it would just mean an alternate
  /// list of length one always reads as doubtful.
  double _agreement(List<List<_Parsed>> readings, _Parsed winner) {
    var saw = 0;
    var agreed = 0;
    for (final reading in readings) {
      for (final parsed in reading) {
        if (parsed.slot != winner.slot) {
          continue;
        }
        saw++;
        if (parsed.value == winner.value) {
          agreed++;
        }
        break;
      }
    }
    return saw == 0 ? 1 : agreed / saw;
  }

  /// Parse one transcript into slot readings.
  ///
  /// A single left-to-right walk, because a continuous recognizer routinely
  /// hands back a whole sentence — "lot forty two bidder seventeen twenty five
  /// dollars sold" is one result, not four.
  List<_Parsed> _parseText(String text) {
    final tokens = tokenize(text);
    if (tokens.isEmpty) {
      return const [];
    }
    final out = <_Parsed>[];
    final buffer = <String>[];
    VoiceSlot? open;
    var openQuality = 1.0;
    var index = 0;
    var order = 0;

    void flushOpen() {
      if (open != null && buffer.isNotEmpty) {
        final parsed = _resolveValue(open, openQuality, buffer, order++);
        if (parsed != null) {
          out.add(parsed);
        }
      }
      buffer.clear();
    }

    while (index < tokens.length) {
      final hit = _anchorAt(tokens, index);
      if (hit == null) {
        buffer.add(tokens[index]);
        index++;
        continue;
      }
      var extra = 0;
      switch (_kindOf(hit.slot)) {
        case _AnchorKind.prefix:
          flushOpen();
          open = hit.slot;
          openQuality = hit.quality;
        case _AnchorKind.suffix:
          // "twenty five dollars and fifty cents" — the cents trail *after*
          // the anchor, so the price span has to reach past it.
          final cents = _centsAfter(tokens, index + hit.length);
          extra = cents.length;
          out.addAll(
            _resolvePrice(
              open,
              openQuality,
              buffer,
              hit.quality,
              () => order++,
              centTokens: cents,
            ),
          );
          open = null;
          buffer.clear();
        case _AnchorKind.standalone:
          flushOpen();
          open = null;
          out.add(
            _Parsed(
              slot: hit.slot,
              keyword: hit.quality,
              match: 1,
              heard: tokens.skip(index).take(hit.length).join(' '),
              order: order++,
            ),
          );
      }
      index += hit.length + extra;
    }
    flushOpen();
    return out;
  }

  /// The tokens making up a trailing cents phrase just after a "dollars"
  /// anchor, including the word "cents" itself; empty when there isn't one.
  ///
  /// Bounded to a few tokens and stopped by any other anchor, so "twenty five
  /// dollars lot twelve … cents" can't reach across half a sentence and
  /// invent a fractional price.
  List<String> _centsAfter(List<String> tokens, int from) {
    const maxLookahead = 4;
    for (var i = from; i < tokens.length && i - from < maxLookahead; i++) {
      if (tokens[i] == 'cents' || tokens[i] == 'cent') {
        return tokens.sublist(from, i + 1);
      }
      if (_anchorAt(tokens, i) != null) {
        return const [];
      }
    }
    return const [];
  }

  /// The anchor starting at [index], if any. Multi-word anchors ("lot number",
  /// "no sale") are tried first so "lot number five" doesn't fire on "lot" and
  /// then try to resolve "number five" as an identifier.
  _AnchorHit? _anchorAt(List<String> tokens, int index) {
    for (final phrase in grammar.phraseAnchors) {
      if (index + phrase.words.length > tokens.length) {
        continue;
      }
      var matches = true;
      for (var i = 0; i < phrase.words.length; i++) {
        if (tokens[index + i] != phrase.words[i]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return _AnchorHit(phrase.slot, phrase.quality, phrase.words.length);
      }
    }
    final token = tokens[index];
    final exact = grammar.anchorFor(token);
    if (exact != null) {
      return _AnchorHit(exact.slot, exact.quality, 1);
    }
    return _fuzzyAnchor(token);
  }

  /// An anchor one edit away — "bidders" for "bidder", "dollar" for "dollars"
  /// — counting a voiced/voiceless swap as no edit at all, so "bitter" reaches
  /// the bidder slot.
  ///
  /// That last part is not a loosened threshold, it's a different kind of
  /// miss. "bitter" is two edits from "bidder" and was therefore invisible
  /// here, but it is *zero* phonetic edits away: American English flaps both
  /// consonants to the same sound, so the recognizer is not making a mistake
  /// an acoustic model could fix — there is nothing in the audio that
  /// distinguishes them. Raising the plain edit budget to 2 instead would have
  /// caught it at the cost of matching genuinely different words ("dollars"
  /// and "collars" are two apart); [boundedEditDistance]'s `ignoreVoicing`
  /// buys the homophones and nothing else.
  ///
  /// Restricted to words of five characters or more, which is also why "lot"
  /// and "sold" never match fuzzily: at three or four characters an edit
  /// distance of 1 covers so much of English ("sold"/"gold"/"bold"/"old") that
  /// ordinary speech would start firing anchors, which is exactly the failure
  /// this grammar exists to prevent.
  ///
  /// The one exception is a **trailing plural**, checked first and at any
  /// length ([_singular]). It is the most common variation a recognizer
  /// produces, it is the same word rather than a guess about which word, and
  /// it carries none of the risk the length guard exists for: "lots" stems to
  /// "lot" and cannot be confused with "got" or "not". Without it the app's
  /// single most-used anchor — three characters, so no fuzzy pass at all — had
  /// to be transcribed exactly or the whole utterance was dropped.
  ///
  /// A fuzzy anchor scores 0.6, which lands the resulting command just above
  /// the unsure threshold — so it fills the field and visibly asks, rather
  /// than either ignoring the operator or quietly trusting a guess. A plural
  /// scores 0.8, the same as a configured synonym, because it isn't a guess.
  _AnchorHit? _fuzzyAnchor(String token) {
    final singular = _singular(token);
    if (singular != null) {
      final stem = grammar.anchorFor(singular);
      if (stem != null) {
        final quality = stem.quality < 0.8 ? stem.quality : 0.8;
        return _AnchorHit(stem.slot, quality, 1);
      }
    }
    if (token.length < 5) {
      return null;
    }
    for (final entry in grammar.anchors.entries) {
      for (final word in entry.value) {
        if (word.contains(' ') || (word.length - token.length).abs() > 1) {
          continue;
        }
        if (boundedEditDistance(token, word, 1, ignoreVoicing: true) <= 1) {
          return _AnchorHit(entry.key, 0.6, 1);
        }
      }
    }
    return null;
  }

  /// [token] with a trailing plural removed, or null if it has none.
  ///
  /// Deliberately the crude rule and not a stemmer: anchors are a fixed
  /// handful of short common nouns and verbs, and every irregular plural in
  /// English is a word this grammar will never contain. A stemmer would buy
  /// nothing here and would happily turn "pass" into "pas".
  static String? _singular(String token) {
    if (token.length > 4 && token.endsWith('es')) {
      return token.substring(0, token.length - 2);
    }
    // Not "ss": "pass" and "dollars" must not stem to "pas" and "dollar" by
    // this route — the first is already an anchor and the second is reached
    // exactly, both before this runs.
    if (token.length > 3 && token.endsWith('s') && !token.endsWith('ss')) {
      return token.substring(0, token.length - 1);
    }
    return null;
  }

  _Parsed? _resolveValue(
    VoiceSlot slot,
    double keyword,
    List<String> tokens,
    int order,
  ) {
    final match = slot == VoiceSlot.lot
        ? vocabulary.matchLot(tokens)
        : vocabulary.matchBidder(tokens);
    if (match == null) {
      return null;
    }
    return _Parsed(
      slot: slot,
      value: match.value,
      keyword: keyword,
      match: match.score,
      heard: tokens.join(' '),
      order: order,
      candidates: match.candidates,
    );
  }

  /// Split the tokens sitting in front of a "dollars" anchor.
  ///
  /// They can belong to two slots: "bidder seventeen twenty five dollars"
  /// leaves `seventeen twenty five` pending with the bidder slot still open.
  /// The vocabulary decides where the seam is — it reports how many tokens its
  /// match consumed, and whatever is left is the amount. That's more reliable
  /// than any positional rule, because "seventeen" being a real bidder is the
  /// actual evidence.
  List<_Parsed> _resolvePrice(
    VoiceSlot? open,
    double openQuality,
    List<String> tokens,
    double priceQuality,
    int Function() nextOrder, {
    List<String> centTokens = const [],
  }) {
    if (tokens.isEmpty) {
      return const [];
    }
    final out = <_Parsed>[];
    if (open != null) {
      final match = open == VoiceSlot.lot
          ? vocabulary.matchLot(tokens)
          : vocabulary.matchBidder(tokens);
      if (match != null && match.consumed < tokens.length) {
        final remainder = tokens.sublist(match.consumed);
        final amount = parseAmount(
          remainder,
          centTokens: centTokens,
          allowCents: !vocabulary.onlyWholeDollarBids,
        );
        if (amount != null) {
          out
            ..add(
              _Parsed(
                slot: open,
                value: match.value,
                keyword: openQuality,
                match: match.score,
                heard: tokens.take(match.consumed).join(' '),
                order: nextOrder(),
                candidates: match.candidates,
              ),
            )
            ..add(
              _Parsed(
                slot: VoiceSlot.price,
                value: amount,
                keyword: priceQuality,
                match: 1,
                heard: [...remainder, ...centTokens].join(' '),
                order: nextOrder(),
              ),
            );
          return out;
        }
      }
    }
    // No seam, or the remainder wasn't a number: the whole run is the amount.
    final amount = parseAmount(
      tokens,
      centTokens: centTokens,
      allowCents: !vocabulary.onlyWholeDollarBids,
    );
    if (amount != null) {
      out.add(
        _Parsed(
          slot: VoiceSlot.price,
          value: amount,
          keyword: priceQuality,
          match: 1,
          heard: tokens.join(' '),
          order: nextOrder(),
        ),
      );
    }
    return out;
  }
}

/// Read a spoken money amount. Returns the value formatted the way the price
/// field wants it (`'25'`, `'25.50'`), or null when it isn't a number.
///
/// [tokens] are the words before the "dollars" anchor; [centTokens] the ones
/// after it, ending in "cents", when the operator said both halves. Keeping
/// them apart is what makes "twenty five dollars and fifty cents" unambiguous
/// — flattened into one list, `twenty five fifty` has no reliable seam.
///
/// When [allowCents] is false — the auction's `only_whole_dollar_bids` — cents
/// are refused outright rather than rounded. That deletes a whole class of
/// error, and the server enforces the same rule in `validate_price`.
String? parseAmount(
  List<String> tokens, {
  required bool allowCents,
  List<String> centTokens = const [],
}) {
  if (tokens.isEmpty) {
    return null;
  }
  final dollars = _parseDollars(tokens);
  if (dollars == null) {
    return null;
  }
  if (centTokens.isEmpty) {
    return _formatAmount(dollars, allowCents: allowCents);
  }
  // Drop the trailing "cents"/"cent".
  final cents = parseCardinal(centTokens.sublist(0, centTokens.length - 1));
  if (cents == null || cents >= 100) {
    return _formatAmount(dollars, allowCents: allowCents);
  }
  return _formatAmount(dollars + cents / 100, allowCents: allowCents);
}

double? _parseDollars(List<String> tokens) {
  // Already formatted by the recognizer ("25.50"). normalizePhrase keeps a
  // decimal point between digits precisely so this survives.
  if (tokens.length == 1) {
    final literal = double.tryParse(tokens.first);
    if (literal != null) {
      return literal;
    }
  }
  final cardinal = parseCardinal(tokens);
  return cardinal?.toDouble();
}

String? _formatAmount(double value, {required bool allowCents}) {
  if (value < 0) {
    return null;
  }
  final whole = value.roundToDouble() == value;
  if (!allowCents && !whole) {
    return null;
  }
  return whole ? '${value.toInt()}' : value.toStringAsFixed(2);
}
