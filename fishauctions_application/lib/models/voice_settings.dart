import 'voice_grammar.dart';

/// The operator's own voice tuning, held on the device.
///
/// **Deliberately device-local rather than server-held**, which is the one
/// place this project's "prefer the backend" rule doesn't apply: every setting
/// here is a property of *this phone in this room* — which microphone it has,
/// whether its language pack is downloaded, how much room noise the recognizer
/// is fighting. The same operator running the same auction from a different
/// handset wants different answers, and syncing these would actively fight
/// them.
///
/// Every field is nullable, and null means "whatever the deployment served".
/// That matters more than it looks: the grammar is served data precisely so it
/// can be retuned centrally, and a device that pinned a copy of today's
/// defaults the first time the panel was opened would never see a single one
/// of those improvements again. Only a setting the operator actually moved is
/// stored.
class VoiceSettings {
  const VoiceSettings({
    this.confidentAt,
    this.preferOnDevice,
    this.biasLowPrices,
  });

  factory VoiceSettings.fromJson(Map<String, dynamic> json) => VoiceSettings(
    confidentAt: _clampedThreshold(json['confident_at']),
    preferOnDevice: json['prefer_on_device'] is bool
        ? json['prefer_on_device'] as bool
        : null,
    biasLowPrices: json['bias_low_prices'] is bool
        ? json['bias_low_prices'] as bool
        : null,
  );

  static const VoiceSettings none = VoiceSettings();

  /// The ends of the confidence slider.
  ///
  /// The floor is not zero and the ceiling is not one, because both ends of
  /// the real range are useless: below about 0.6 the app writes fields off
  /// readings it has no business trusting, and at 1.0 nothing is ever
  /// confident enough to auto-submit, so "sold" stops working entirely and
  /// looks broken. [minConfidentAt] also sits above the default `unsureAt` of
  /// 0.5 — the two thresholds crossing would mean "confident" was a *weaker*
  /// claim than "unsure", which no amount of UI could explain.
  static const double minConfidentAt = 0.6;
  static const double maxConfidentAt = 0.9;

  /// How sure the app must be before it fills a field silently and lets "sold"
  /// submit. Below this it still fills, but marks the field unsure and holds
  /// the submit back.
  ///
  /// This is the knob worth having in the room, because the right answer is a
  /// judgement about *this* auction rather than a fact: an operator watching
  /// the screen wants it low and will catch the mistakes; one calling lots
  /// with their hands full wants it high and would rather retype than have a
  /// wrong bidder recorded silently.
  final double? confidentAt;

  /// Ask the platform to recognize on-device.
  ///
  /// Worth exposing because the trade is genuinely per-room and we can't guess
  /// it: on-device survives bad wifi and answers faster, network recognition
  /// is measurably more accurate. Both platforms support it — Android through
  /// `createOnDeviceSpeechRecognizer`, iOS through
  /// `SFSpeechRecognitionRequest.requiresOnDeviceRecognition` — and both need
  /// the language pack actually downloaded, which is why asking for it can
  /// fail on a phone that reports the *service* as present.
  final bool? preferOnDevice;

  /// Prefer the smaller reading when the recognizer offers both, **for prices
  /// only**.
  ///
  /// "Seventeen" and "seventy" are the classic pair, and in this domain they
  /// are not equally likely: most lots sell for a few dollars, so a tie broken
  /// downwards is right far more often than not. Scoped to prices on purpose —
  /// a bidder number or a lot number has no such distribution, and guessing
  /// the lower of two bidders is how the wrong person gets charged.
  final bool? biasLowPrices;

  bool get isEmpty =>
      confidentAt == null && preferOnDevice == null && biasLowPrices == null;

  /// This deployment's grammar with the operator's overrides on top.
  VoiceGrammar applyTo(VoiceGrammar grammar) => grammar.copyWith(
    confidentAt: confidentAt,
    preferOnDevice: preferOnDevice,
    biasLowPrices: biasLowPrices,
  );

  VoiceSettings merge(VoiceSettings other) => VoiceSettings(
    confidentAt: other.confidentAt ?? confidentAt,
    preferOnDevice: other.preferOnDevice ?? preferOnDevice,
    biasLowPrices: other.biasLowPrices ?? biasLowPrices,
  );

  Map<String, dynamic> toJson() => {
    'confident_at': ?confidentAt,
    'prefer_on_device': ?preferOnDevice,
    'bias_low_prices': ?biasLowPrices,
  };

  /// A threshold from the page, forced into the slider's range.
  ///
  /// Clamped rather than rejected: the page owns the slider's endpoints today
  /// and a future one may not agree with this build about them, and silently
  /// keeping the old value would look to the operator like the control does
  /// nothing.
  static double? _clampedThreshold(Object? raw) =>
      raw is num ? raw.toDouble().clamp(minConfidentAt, maxConfidentAt) : null;
}
