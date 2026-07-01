/// Parsed `POST /api/mobile/payments/create/` response (fields resolved per
/// invoice on the backend).
///
/// [accessToken] + [locationId] authorize the Square SDK for the invoice's
/// seller; [amountCents] is the amount in integer minor units; [referenceId]
/// must be passed to Square verbatim so the backend can match the charge at
/// confirm time.
///
/// [applicationId] (the deployment's public Square Application ID) is now
/// sourced from `/api/mobile/config/` and initialized early, so it is
/// **optional** here — retained only as a fallback for the SDK init when config
/// failed to load. It is NOT the secret [accessToken].
class PaymentContext {
  const PaymentContext({
    required this.amountCents,
    required this.amountDisplay,
    required this.currency,
    required this.accessToken,
    required this.locationId,
    required this.idempotencyKey,
    required this.referenceId,
    this.applicationId,
  });

  factory PaymentContext.fromJson(Map<String, dynamic> json) {
    final amount = json['amount'] as String?;
    if (amount == null) {
      throw const FormatException('missing amount');
    }
    final accessToken = json['access_token'] as String?;
    final locationId = json['location_id'] as String?;
    if (accessToken == null || locationId == null) {
      throw const FormatException('missing access_token/location_id');
    }
    // Optional now: the SDK is initialized from /api/mobile/config/. Kept as a
    // fallback app id in case config didn't load. Empty string is treated as
    // absent.
    final rawAppId = json['square_application_id'] as String?;
    final applicationId = (rawAppId == null || rawAppId.isEmpty)
        ? null
        : rawAppId;
    final key = json['idempotency_key'] as String?;
    if (key == null) {
      throw const FormatException('missing idempotency_key');
    }
    // The backend ties the charge to this reference_id and rejects confirm if
    // Square's reference_id doesn't match — so it's required, not optional.
    final referenceId = json['reference_id'] as String?;
    if (referenceId == null || referenceId.isEmpty) {
      throw const FormatException('missing reference_id');
    }
    final currency = json['currency'] as String? ?? 'USD';
    return PaymentContext(
      amountCents: _toMinorUnits(amount, currency),
      amountDisplay: amount,
      currency: currency,
      accessToken: accessToken,
      locationId: locationId,
      idempotencyKey: key,
      referenceId: referenceId,
      applicationId: applicationId,
    );
  }

  final int amountCents;
  final String amountDisplay;
  final String currency;
  final String accessToken;
  final String locationId;
  final String idempotencyKey;
  final String referenceId;
  final String? applicationId;

  // Most currencies use 2 minor-unit decimals; a few (JPY) use 0. Anything not
  // listed defaults to 2.
  static const _zeroDecimalCurrencies = {'JPY'};

  static final _digitsOnly = RegExp(r'^\d*$');

  // Backend sends a decimal string ("15.00"). Square wants integer minor units
  // (cents for USD, whole yen for JPY). Parse the digits directly — never via
  // `double` — so the amount the card is charged is exact, with no
  // binary-floating-point drift (e.g. 0.07 * 100 = 7.0000000000000009).
  static int _toMinorUnits(String amount, String currency) {
    final decimals = _zeroDecimalCurrencies.contains(currency.toUpperCase())
        ? 0
        : 2;
    final parts = amount.trim().split('.');
    if (parts.length > 2) {
      throw FormatException('invalid amount: $amount');
    }
    final whole = parts[0];
    final frac = parts.length == 2 ? parts[1] : '';
    if ((whole.isEmpty && frac.isEmpty) ||
        !_digitsOnly.hasMatch(whole) ||
        !_digitsOnly.hasMatch(frac)) {
      throw FormatException('invalid amount: $amount');
    }
    // Normalize the fractional part to exactly `decimals` digits. If the
    // backend ever sends more precision than the currency holds, round half-up
    // rather than truncate so we never undercharge by a cent.
    final padded = frac.padRight(decimals, '0');
    final wholePart = whole.isEmpty ? '0' : whole;
    var minor = int.parse('$wholePart${padded.substring(0, decimals)}');
    if (padded.length > decimals && padded.codeUnitAt(decimals) - 0x30 >= 5) {
      minor += 1;
    }
    return minor;
  }
}
