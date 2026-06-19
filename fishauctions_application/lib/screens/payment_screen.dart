import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

import '../services/api_service.dart';
import '../services/square_payment_service.dart';

/// Square Tap to Pay checkout screen. Mirrors the web "quick checkout" page,
/// but takes a contactless tap instead of showing a QR code.
///
/// Flow:
///   1. POST /payments/create/ → amount, currency, idempotency key,
///      reference_id (+ per-invoice seller access_token/location_id)
///   2. Authorize the Square SDK with OAuth creds fetched from the backend
///   3. startPayment() with the backend's reference_id → user taps card →
///      Square captures on-device
///   4. POST /payments/confirm/ → backend verifies the reference_id matches +
///      marks the invoice PAID
///   5. Show the result and pop back to the WebView
class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({required this.invoicePk, super.key});

  final int invoicePk;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  _PaymentContext? _ctx;

  /// Set once Square captures the card on-device. While a capture is
  /// outstanding the card has already been charged, so the only safe recovery
  /// is to re-finalize *this* payment — never to start a second charge.
  String? _capturedPaymentId;
  bool _captureOutstanding = false;

  @override
  void initState() {
    super.initState();
    _createPayment();
  }

  Future<void> _createPayment() async {
    // Starting over is only safe when no charge is in flight.
    //
    // The in-memory `_captureOutstanding` guard below protects retries within
    // this screen instance. The cross-instance backstop (screen recreated, or
    // the process is killed mid-tap) is the backend's idempotency key: it is
    // derived from the invoice pk, so a brand-new create returns the *same*
    // key, which we pass to Square as the paymentAttemptId — Square then
    // de-dupes and the card is never charged twice for one invoice.
    _capturedPaymentId = null;
    _captureOutstanding = false;
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });

    try {
      final res = await ApiService.instance.dio.post<Map<String, dynamic>>(
        'payments/create/',
        data: {'invoice_pk': widget.invoicePk},
      );
      final ctx = _PaymentContext.fromJson(res.data ?? const {});
      if (!mounted) {
        return;
      }
      setState(() {
        _ctx = ctx;
        _phase = _Phase.ready;
      });
    } on DioException catch (e) {
      _fail(_detail(e) ?? 'Could not load invoice. Please try again.');
    } on FormatException catch (e) {
      _fail('Unexpected response from server: ${e.message}');
    }
  }

  Future<void> _startTapToPay() async {
    final ctx = _ctx;
    if (ctx == null) {
      return;
    }
    setState(() {
      _phase = _Phase.processing;
      _error = null;
    });

    final square = SquarePaymentService.instance;
    try {
      await square.ensureAuthorized(
        accessToken: ctx.accessToken,
        locationId: ctx.locationId,
      );

      if (!await square.isDeviceCapable()) {
        _fail(
          'This device can\'t take Tap to Pay payments. It needs NFC and '
          'Android 12 or newer.',
        );
        return;
      }

      final result = await square.charge(
        amountCents: ctx.amountCents,
        currencyCode: ctx.currency,
        paymentAttemptId: ctx.idempotencyKey,
        note: 'Invoice #${widget.invoicePk}',
        // Must be the backend-issued reference_id verbatim — confirm rejects
        // the charge if Square's reference_id doesn't match.
        referenceId: ctx.referenceId,
      );

      // The card has now been charged on-device. From here on, recovery means
      // re-confirming this payment — we must never start a second charge.
      _capturedPaymentId = result.paymentId;
      _captureOutstanding = true;
      if (_capturedPaymentId == null) {
        _fail(
          'The card was charged, but the reader did not return a payment id. '
          'Please check the invoice before charging again.',
        );
        return;
      }

      await _confirmCaptured();
    } on PaymentError catch (e) {
      if (e.code == PaymentErrorCode.canceled) {
        // User backed out — return to the ready state, no error banner.
        if (mounted) {
          setState(() => _phase = _Phase.ready);
        }
        return;
      }
      _fail('Payment failed: ${e.message}');
    } on AuthorizeError catch (e) {
      _fail('Could not start the card reader: ${e.message}');
    } on Exception catch (e) {
      // Any other SDK/platform failure — never leave the spinner hanging.
      _fail('Payment could not be completed: $e');
    }
  }

  /// Finalizes the already-captured payment with the backend. Safe to retry:
  /// it always posts the same [_capturedPaymentId] + idempotency key, so the
  /// card is never charged twice.
  Future<void> _confirmCaptured() async {
    final ctx = _ctx;
    if (ctx == null) {
      return;
    }
    setState(() {
      _phase = _Phase.processing;
      _error = null;
    });
    try {
      final res = await ApiService.instance.dio.post<Map<String, dynamic>>(
        'payments/confirm/',
        data: {
          'invoice_pk': widget.invoicePk,
          'payment_id': _capturedPaymentId,
          'idempotency_key': ctx.idempotencyKey,
        },
      );
      if (!mounted) {
        return;
      }
      final data = res.data ?? const {};
      final receipt =
          data['receipt_number'] ?? data['payment_id'] ?? _capturedPaymentId;
      _captureOutstanding = false;
      // Intentionally keep the Square authorization after a settled charge. An
      // in-person checkout runs many invoices for the same seller back-to-back,
      // and a fresh authorize() per charge would add a slow reader re-init each
      // time. ensureAuthorized() already deauthorizes when the seller changes,
      // and logout releases it — so it's never left authorized across sellers.
      setState(() {
        _phase = _Phase.success;
        _error = receipt == null ? null : 'Receipt $receipt';
      });
      await _showResult(success: true, message: 'Payment confirmed.');
      if (mounted) {
        context.pop();
      }
    } on DioException catch (e) {
      _fail(
        _detail(e) ??
            'The card was charged, but we could not confirm it. Tap to finish '
                '— you will not be charged again.',
      );
    }
  }

  void _fail(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _error = message;
      _phase = _Phase.error;
    });
  }

  String? _detail(DioException e) {
    final data = e.response?.data;
    return data is Map ? data['detail'] as String? : null;
  }

  Future<void> _showResult({required bool success, required String message}) =>
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(success ? 'Payment Complete' : 'Payment Failed'),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Tap to Pay')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (_phase) {
          _Phase.loading => const Center(child: CircularProgressIndicator()),
          _Phase.error => _ErrorView(
            message: _error ?? 'Something went wrong.',
            // While a capture is outstanding, retry must re-confirm the same
            // payment, not start a new charge.
            onRetry: _captureOutstanding ? _confirmCaptured : _createPayment,
            retryLabel: _captureOutstanding ? 'Finish Payment' : 'Try Again',
          ),
          _Phase.ready => _ReadyView(
            invoicePk: widget.invoicePk,
            amountDisplay: _ctx!.amountDisplay,
            onPay: _startTapToPay,
          ),
          _Phase.processing => const _ProcessingView(),
          _Phase.success => const _SuccessView(),
        },
      ),
    ),
  );
}

enum _Phase { loading, ready, processing, success, error }

/// Parsed `/payments/create/` response (fields resolved per invoice on the
/// backend). [accessToken] + [locationId] authorize the Square SDK for the
/// invoice's seller; [amountCents] is the amount in integer minor units;
/// [referenceId] must be passed to Square verbatim so the backend can match
/// the charge at confirm time.
class _PaymentContext {
  const _PaymentContext({
    required this.amountCents,
    required this.amountDisplay,
    required this.currency,
    required this.accessToken,
    required this.locationId,
    required this.idempotencyKey,
    required this.referenceId,
  });

  factory _PaymentContext.fromJson(Map<String, dynamic> json) {
    final amount = json['amount'] as String?;
    if (amount == null) {
      throw const FormatException('missing amount');
    }
    final accessToken = json['access_token'] as String?;
    final locationId = json['location_id'] as String?;
    if (accessToken == null || locationId == null) {
      throw const FormatException('missing access_token/location_id');
    }
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
    return _PaymentContext(
      amountCents: _toMinorUnits(amount, currency),
      amountDisplay: amount,
      currency: currency,
      accessToken: accessToken,
      locationId: locationId,
      idempotencyKey: key,
      referenceId: referenceId,
    );
  }

  final int amountCents;
  final String amountDisplay;
  final String currency;
  final String accessToken;
  final String locationId;
  final String idempotencyKey;
  final String referenceId;

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

class _ReadyView extends StatelessWidget {
  const _ReadyView({
    required this.invoicePk,
    required this.amountDisplay,
    required this.onPay,
  });

  final int invoicePk;
  final String amountDisplay;
  final VoidCallback onPay;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Icon(Icons.contactless, size: 80),
      const SizedBox(height: 16),
      Text(
        '\$$amountDisplay',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      Text(
        'Invoice #$invoicePk',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 8),
      const Text(
        'Hold the card or phone near the top of this device.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 40),
      FilledButton.icon(
        onPressed: onPay,
        icon: const Icon(Icons.nfc),
        label: const Text('Tap to Pay'),
      ),
    ],
  );
}

class _ProcessingView extends StatelessWidget {
  const _ProcessingView();

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      CircularProgressIndicator(),
      SizedBox(height: 16),
      Text('Waiting for the card tap…', textAlign: TextAlign.center),
    ],
  );
}

class _SuccessView extends StatelessWidget {
  const _SuccessView();

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(Icons.check_circle, size: 80, color: Colors.green),
      SizedBox(height: 16),
      Text('Payment complete!'),
    ],
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.onRetry,
    this.retryLabel = 'Try Again',
  });

  final String message;
  final VoidCallback onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Icon(
        Icons.error_outline,
        size: 64,
        color: Theme.of(context).colorScheme.error,
      ),
      const SizedBox(height: 16),
      Text(message, textAlign: TextAlign.center),
      const SizedBox(height: 24),
      FilledButton(onPressed: onRetry, child: Text(retryLabel)),
    ],
  );
}
