import 'package:logger/logger.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

import '../utils/android_platform.dart';

final _log = Logger();

/// Outcome of a completed Tap to Pay charge. [paymentId] is the Square payment
/// id the backend uses to reconcile/verify the charge via Square's API.
class SquareChargeResult {
  const SquareChargeResult({required this.paymentId});

  final String? paymentId;
}

/// Wraps the Square Mobile Payments SDK for Tap to Pay.
///
/// Auth model: the seller's Square account is chosen **per invoice** on the
/// Django side, so the access token + location id arrive in the
/// `/payments/create/` response. The app passes them to the SDK's `authorize()`
/// at payment time. Nothing Square-related is embedded in the app binary.
class SquarePaymentService {
  SquarePaymentService._();
  static final SquarePaymentService instance = SquarePaymentService._();

  final _sdk = SquareMobilePaymentsSdk();

  /// True when the SDK already holds a valid authorization for a location.
  Future<bool> get isAuthorized async =>
      await _sdk.authManager.getAuthorizationState() ==
      AuthorizationState.authorized;

  /// Whether this physical device can take a Tap to Pay payment at all
  /// (Android: NFC + API 31+); otherwise a charge fails as unsupported.
  Future<bool> isDeviceCapable() => _sdk.tapToPaySettings.isDeviceCapable();

  /// Authorizes the SDK for [locationId] using the per-invoice [accessToken].
  ///
  /// [applicationId] is the deployment's Square Application ID (from
  /// `/api/mobile/config/`, warmed at startup); the SDK is initialized with it
  /// first, since authorize() can't run on an uninitialized SDK. Init is
  /// once-per-process and idempotent (see [AndroidPlatform.initializeSquare]),
  /// so re-calling it here after the startup warm-up is a no-op.
  ///
  /// Different invoices can belong to different sellers, so if the device is
  /// already authorized for a *different* location we deauthorize and switch.
  /// No-op when already authorized for [locationId].
  Future<void> ensureAuthorized({
    required String applicationId,
    required String accessToken,
    required String locationId,
  }) async {
    await AndroidPlatform.initializeSquare(applicationId);
    if (await isAuthorized) {
      final current = await _sdk.authManager.getAuthorizedLocation();
      if (current?.id == locationId) {
        return;
      }
      await _sdk.authManager.deauthorize();
    }
    try {
      await _sdk.authManager.authorize(accessToken, locationId);
    } on AuthorizeError catch (e) {
      _log.e('Square authorize failed: ${e.code} — ${e.message}');
      rethrow;
    }
  }

  /// Runs a Tap to Pay charge for [amountCents] (minor units), in
  /// [currencyCode].
  ///
  /// [paymentAttemptId] must be stable across retries of the same logical
  /// payment so Square de-duplicates — pass the backend's idempotency key.
  ///
  /// Returns on a captured payment. Throws [PaymentError] on cancel/failure
  /// (check `code == PaymentErrorCode.canceled` to detect a user cancel).
  Future<SquareChargeResult> charge({
    required int amountCents,
    required String currencyCode,
    required String paymentAttemptId,
    String? note,
    String? referenceId,
  }) async {
    final payment = await _sdk.paymentManager.startPayment(
      PaymentParameters(
        amountMoney: Money(
          amount: amountCents,
          currencyCode: _currencyFor(currencyCode),
        ),
        // ProcessingMode.autoDetect (0): process online when connected.
        processingMode: ProcessingMode.autoDetect.index,
        paymentAttemptId: paymentAttemptId,
        autocomplete: true,
        note: note,
        referenceId: referenceId,
      ),
      const PromptParameters(
        additionalPaymentMethods: [],
        mode: PromptMode.defaultMode,
      ),
    );
    return SquareChargeResult(paymentId: payment.id);
  }

  /// Releases the current authorization (e.g. on logout).
  Future<void> deauthorize() => _sdk.authManager.deauthorize();

  CurrencyCode _currencyFor(String code) {
    switch (code.toUpperCase()) {
      case 'USD':
        return CurrencyCode.usd;
      case 'CAD':
        return CurrencyCode.cad;
      case 'AUD':
        return CurrencyCode.aud;
      case 'EUR':
        return CurrencyCode.eur;
      case 'GBP':
        return CurrencyCode.gbp;
      case 'JPY':
        return CurrencyCode.jpy;
      default:
        // Fail loudly rather than silently charge in the wrong currency.
        throw ArgumentError.value(code, 'currencyCode', 'unsupported currency');
    }
  }
}
