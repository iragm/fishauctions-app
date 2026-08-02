import 'dart:math' as math;

/// The slots the set-winners page understands. Everything the voice pipeline
/// produces is one of these; the page ignores slots it doesn't know, which is
/// what lets either side add one without shipping the other (`VOICE.md` §3.3).
enum VoiceSlot {
  /// Lot identifier — writes `#lot`.
  lot,

  /// Bidder identifier — writes `#winner`.
  bidder,

  /// Winning price — writes `#price`.
  price,

  /// Submit the sale (`action=save`).
  sold,

  /// End the lot unsold (`action=end_unsold`).
  unsold,

  /// Undo the last sale, when the page's undo link is showing.
  undo,

  /// Wipe the three fields.
  clear,

  /// Accept whatever is currently marked unsure.
  confirm;

  /// The wire name used in the JS bridge payload.
  String get wireName => name;

  /// Slots that carry a value the operator dictated, as opposed to the ones
  /// that are pure actions. Only these get a confidence tier and can block an
  /// auto-submit.
  bool get isValueSlot =>
      this == VoiceSlot.lot ||
      this == VoiceSlot.bidder ||
      this == VoiceSlot.price;
}

/// How much the pipeline trusts a value, after the grammar's thresholds are
/// applied. The page renders one of three states from this (`VOICE.md` §5).
enum VoiceConfidenceTier {
  /// Fill the field normally.
  confident,

  /// Fill it, but mark it and hold back any auto-submit.
  unsure,

  /// Don't fill anything — show the transcript only.
  rejected,
}

/// One resolved instruction, ready for the page.
///
/// [confidence] is *computed* rather than taken from the recognizer, because
/// the platform reports `-1` ("not available") far more often than expected —
/// routinely for iOS on-device results and Android partials. See
/// [VoiceConfidenceInputs] for what goes into it.
class VoiceCommand {
  const VoiceCommand({
    required this.slot,
    required this.confidence,
    required this.heard,
    this.value = '',
    this.candidates = const [],
    this.blockedBy = const [],
  });

  final VoiceSlot slot;

  /// The value to write, verbatim as the auction stores it — `'42'`, `'BOB'`,
  /// `'BOB-1'`. Empty for action slots.
  final String value;

  /// 0..1.
  final double confidence;

  /// What the recognizer produced for this command, for the "heard …" line.
  final String heard;

  /// Other vocabulary entries that matched nearly as well. Non-empty only when
  /// the match was genuinely ambiguous, so the page can offer a pick-list
  /// instead of silently choosing.
  final List<String> candidates;

  /// For [VoiceSlot.sold]: the value slots that are missing or unsure, and so
  /// are holding back the auto-submit. Empty means "safe to save".
  final List<String> blockedBy;

  VoiceConfidenceTier tierFor({
    required double confidentAt,
    required double unsureAt,
  }) {
    if (confidence >= confidentAt) {
      return VoiceConfidenceTier.confident;
    }
    return confidence >= unsureAt
        ? VoiceConfidenceTier.unsure
        : VoiceConfidenceTier.rejected;
  }

  Map<String, dynamic> toJson() => {
    'type': 'command',
    'slot': slot.wireName,
    'value': value,
    'confidence': double.parse(confidence.toStringAsFixed(3)),
    'heard': heard,
    'candidates': candidates,
    'blocked_by': blockedBy,
  };

  @override
  String toString() =>
      'VoiceCommand(${slot.wireName}, "$value", '
      '${confidence.toStringAsFixed(2)})';
}

/// The four independent signals behind [VoiceCommand.confidence].
///
/// Three of them are ours, which is the point: a platform that never reports a
/// confidence still yields a meaningful number, and one that reports a bad one
/// can't single-handedly wave a wrong value through.
class VoiceConfidenceInputs {
  const VoiceConfidenceInputs({
    required this.keyword,
    required this.match,
    required this.agreement,
    this.asr = neutralAsr,
  });

  /// What the platform said, when it said anything. `speech_to_text` uses -1
  /// for "not available"; callers substitute [neutralAsr] in that case rather
  /// than treating silence as doubt.
  static const double neutralAsr = 0.8;

  /// Platform confidence, 0..1.
  final double asr;

  /// Anchor-keyword quality: 1.0 exact, 0.8 a configured synonym, 0.6 a fuzzy
  /// hit ("butter" → "bidder").
  final double keyword;

  /// Vocabulary match quality — the table in `VOICE.md` §4.2.
  final double match;

  /// Fraction of the scored hypotheses that resolved this slot identically.
  final double agreement;

  /// Weighted combination. The square root on [asr] deliberately flattens it:
  /// it's the least trustworthy input and shouldn't dominate.
  double score(VoiceConfidenceWeights w) {
    final asrTerm = math.pow(asr.clamp(0.0, 1.0), w.asr).toDouble();
    final agreementTerm =
        (1 - w.agreement) + w.agreement * agreement.clamp(0.0, 1.0);
    final raw =
        asrTerm *
        math.pow(keyword.clamp(0.0, 1.0), w.keyword).toDouble() *
        math.pow(match.clamp(0.0, 1.0), w.match).toDouble() *
        agreementTerm;
    return raw.clamp(0.0, 1.0);
  }
}

/// Exponents/weights for [VoiceConfidenceInputs.score], served in the grammar
/// so a deployment can retune without an app release.
class VoiceConfidenceWeights {
  const VoiceConfidenceWeights({
    this.asr = 0.5,
    this.keyword = 1.0,
    this.match = 1.0,
    this.agreement = 0.4,
  });

  factory VoiceConfidenceWeights.fromJson(Map<String, dynamic> json) =>
      VoiceConfidenceWeights(
        asr: _weight(json['asr'], 0.5),
        keyword: _weight(json['keyword'], 1),
        match: _weight(json['match'], 1),
        agreement: _weight(json['agreement'], 0.4),
      );

  final double asr;
  final double keyword;
  final double match;

  /// How much of the score the alternates' agreement can swing: the term is
  /// `(1 - agreement) + agreement * fraction`, so 0 disables it entirely.
  final double agreement;

  static double _weight(Object? raw, double fallback) {
    final value = raw is num ? raw.toDouble() : null;
    return value == null || value < 0 ? fallback : value;
  }
}
