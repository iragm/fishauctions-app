import 'voice_command.dart';

/// The words voice set-winners listens for, and how much it has to trust a
/// match before acting — served as JSON under `voice` in
/// `GET /api/mobile/config/`, over a bundled default.
///
/// This is data rather than code on purpose, and it's the lesson from v1:
/// which words a given auctioneer actually uses is exactly the thing we will
/// be wrong about on day one, and the old implementation had no way to fix
/// that short of an app release. Same reasoning as `ThermalPrinterProfile`.
class VoiceGrammar {
  const VoiceGrammar({
    required this.anchors,
    this.enabled = true,
    this.backend = 'biased',
    this.localeId = 'en_US',
    this.preferOnDevice = true,
    this.weights = const VoiceConfidenceWeights(),
    this.confidentAt = 0.85,
    this.unsureAt = 0.5,
    this.autoSubmitOnSold = true,
    this.blockAutoSubmitWhenUnsure = true,
    this.maxAlternates = 3,
    this.biasLowPrices = false,
  });

  /// Parse the `voice` block, falling back to [fallback] field by field so a
  /// deployment can override one setting without restating the whole grammar.
  factory VoiceGrammar.fromJson(
    Map<String, dynamic> json, {
    required VoiceGrammar fallback,
  }) {
    final anchors = <VoiceSlot, List<String>>{...fallback.anchors};
    final rawAnchors = json['anchors'];
    if (rawAnchors is Map) {
      for (final slot in VoiceSlot.values) {
        final words = rawAnchors[slot.wireName];
        if (words is List) {
          final parsed = [
            for (final word in words)
              if (word is String && word.trim().isNotEmpty)
                word.trim().toLowerCase(),
          ];
          if (parsed.isNotEmpty) {
            anchors[slot] = parsed;
          }
        }
      }
    }
    final rawWeights = json['weights'];
    return VoiceGrammar(
      anchors: anchors,
      enabled: json['enabled'] is bool
          ? json['enabled'] as bool
          : fallback.enabled,
      backend: _str(json['backend']) ?? fallback.backend,
      localeId: _str(json['locale']) ?? fallback.localeId,
      preferOnDevice: json['prefer_on_device'] is bool
          ? json['prefer_on_device'] as bool
          : fallback.preferOnDevice,
      weights: rawWeights is Map<String, dynamic>
          ? VoiceConfidenceWeights.fromJson(rawWeights)
          : fallback.weights,
      confidentAt: _threshold(json, 'confident') ?? fallback.confidentAt,
      unsureAt: _threshold(json, 'unsure') ?? fallback.unsureAt,
      autoSubmitOnSold: json['auto_submit_on_sold'] is bool
          ? json['auto_submit_on_sold'] as bool
          : fallback.autoSubmitOnSold,
      blockAutoSubmitWhenUnsure: json['block_auto_submit_when_unsure'] is bool
          ? json['block_auto_submit_when_unsure'] as bool
          : fallback.blockAutoSubmitWhenUnsure,
      maxAlternates: json['max_alternates'] is int
          ? json['max_alternates'] as int
          : fallback.maxAlternates,
      biasLowPrices: json['bias_low_prices'] is bool
          ? json['bias_low_prices'] as bool
          : fallback.biasLowPrices,
    );
  }

  /// Kill switch. `false` makes the app report `supported: false`, so the page
  /// hides the microphone button — the way out if a session goes badly.
  final bool enabled;

  /// Which `SpeechBackend` to drive. Unknown values fall back to `platform`
  /// rather than disabling voice, so a config written for a newer build
  /// degrades instead of breaking.
  ///
  /// **Defaults to `biased`**, the recognizer this app drives itself, because
  /// it is the only one that can be told the auction's lot and bidder numbers
  /// — and a club whose bidder numbers are initials is otherwise asking a
  /// general dictation model for strings it has no prior for. A build or
  /// device without the native side falls back to `platform` on its own
  /// (`Microphone.backendFor`), silently, so this costs nothing where it isn't
  /// available. Setting `"backend": "platform"` in the served config is the
  /// kill switch if the new one misbehaves in a hall — a Django row edit
  /// rather than a release.
  final String backend;

  final String localeId;

  /// Ask the platform to recognize on-device. An auction hall's wifi is bad,
  /// the round trip is the latency the operator feels, and Apple throttles
  /// server-side recognition per app per hour.
  final bool preferOnDevice;

  /// Anchor keywords per slot. Every value slot needs one: a bare number
  /// writes nothing, which is what keeps the auctioneer's chant and the crowd
  /// from corrupting a field.
  final Map<VoiceSlot, List<String>> anchors;

  final VoiceConfidenceWeights weights;

  /// At or above this, fill the field normally.
  final double confidentAt;

  /// At or above this (but below [confidentAt]), fill it but mark it unsure.
  /// Below it, emit no command at all.
  final double unsureAt;

  /// Whether hearing "sold" submits the form.
  final bool autoSubmitOnSold;

  /// Whether an unsure field holds that submit back. On by default: an
  /// auctioneer says "sold" constantly, and a wrong bidder recorded silently
  /// is worse than one more tap.
  final bool blockAutoSubmitWhenUnsure;

  /// How many recognizer hypotheses to score. Past about three the extra
  /// alternates are noise that only widens the chance of a false match.
  final int maxAlternates;

  /// Break a tie between two equally-scored *price* readings by taking the
  /// smaller one. `VoiceSettings.biasLowPrices` says why this is a price-only
  /// rule and must stay one.
  final bool biasLowPrices;

  /// This grammar with a few fields replaced. Only the fields the operator's
  /// device-local settings can override are here — everything else about a
  /// grammar is the deployment's business, and a device that could quietly
  /// rewrite the anchor lists would be a support call nobody could diagnose.
  VoiceGrammar copyWith({
    double? confidentAt,
    bool? preferOnDevice,
    bool? biasLowPrices,
  }) => VoiceGrammar(
    anchors: anchors,
    enabled: enabled,
    backend: backend,
    localeId: localeId,
    preferOnDevice: preferOnDevice ?? this.preferOnDevice,
    weights: weights,
    confidentAt: confidentAt ?? this.confidentAt,
    unsureAt: unsureAt,
    autoSubmitOnSold: autoSubmitOnSold,
    blockAutoSubmitWhenUnsure: blockAutoSubmitWhenUnsure,
    maxAlternates: maxAlternates,
    biasLowPrices: biasLowPrices ?? this.biasLowPrices,
  );

  /// The slot an anchor word belongs to, with how good the match was — 1.0 for
  /// the slot's first (canonical) word, 0.8 for a configured synonym. Fuzzy
  /// anchor matching is applied by the parser, not here.
  ({VoiceSlot slot, double quality})? anchorFor(String token) {
    for (final entry in anchors.entries) {
      final index = entry.value.indexOf(token);
      if (index == 0) {
        return (slot: entry.key, quality: 1);
      }
      if (index > 0) {
        return (slot: entry.key, quality: 0.8);
      }
    }
    return null;
  }

  /// Multi-word anchors ("lot number", "no sale") sorted longest-first, so the
  /// parser can try them before falling back to single tokens.
  List<({VoiceSlot slot, List<String> words, double quality})>
  get phraseAnchors {
    final result = <({VoiceSlot slot, List<String> words, double quality})>[];
    for (final entry in anchors.entries) {
      for (var i = 0; i < entry.value.length; i++) {
        final words = entry.value[i].split(' ');
        if (words.length > 1) {
          result.add((
            slot: entry.key,
            words: words,
            quality: i == 0 ? 1.0 : 0.8,
          ));
        }
      }
    }
    result.sort((a, b) => b.words.length.compareTo(a.words.length));
    return result;
  }

  static String? _str(Object? raw) =>
      raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

  static double? _threshold(Map<String, dynamic> json, String key) {
    final thresholds = json['thresholds'];
    if (thresholds is! Map) {
      return null;
    }
    final value = thresholds[key];
    return value is num ? value.toDouble().clamp(0.0, 1.0) : null;
  }
}
