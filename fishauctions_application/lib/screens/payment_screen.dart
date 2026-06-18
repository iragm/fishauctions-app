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
///   1. POST /payments/create/ → amount, currency, idempotency key
///   2. Authorize the Square SDK with OAuth creds fetched from the backend
///   3. startPayment() → user taps card → Square captures on-device
///   4. POST /payments/confirm/ → backend verifies + marks the invoice PAID
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

  @override
  void initState() {
    super.initState();
    _createPayment();
  }

  Future<void> _createPayment() async {
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
        referenceId: 'invoice:${widget.invoicePk}',
      );

      await _confirmPayment(ctx, result.paymentId);
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
    } on DioException catch (e) {
      _fail(_detail(e) ?? 'Network error while finalizing the payment.');
    }
  }

  Future<void> _confirmPayment(_PaymentContext ctx, String? paymentId) async {
    final res = await ApiService.instance.dio.post<Map<String, dynamic>>(
      'payments/confirm/',
      data: {
        'invoice_pk': widget.invoicePk,
        'payment_id': paymentId,
        'idempotency_key': ctx.idempotencyKey,
      },
    );
    if (!mounted) {
      return;
    }
    final data = res.data ?? const {};
    final receipt = data['receipt_number'] ?? data['payment_id'] ?? paymentId;
    setState(() {
      _phase = _Phase.success;
      _error = receipt == null ? null : 'Receipt $receipt';
    });
    await _showResult(success: true, message: 'Payment confirmed.');
    if (mounted) {
      context.pop();
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
            onRetry: _createPayment,
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
/// invoice's seller; [amountCents] is the amount in integer minor units.
class _PaymentContext {
  const _PaymentContext({
    required this.amountCents,
    required this.amountDisplay,
    required this.currency,
    required this.accessToken,
    required this.locationId,
    required this.idempotencyKey,
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
    return _PaymentContext(
      amountCents: _toMinorUnits(amount),
      amountDisplay: amount,
      currency: json['currency'] as String? ?? 'USD',
      accessToken: accessToken,
      locationId: locationId,
      idempotencyKey: key,
    );
  }

  final int amountCents;
  final String amountDisplay;
  final String currency;
  final String accessToken;
  final String locationId;
  final String idempotencyKey;

  // Backend sends a decimal string ("15.00"). Square wants integer minor units.
  // Assumes a 2-decimal currency (USD et al.); revisit if JPY is ever enabled.
  static int _toMinorUnits(String amount) =>
      (double.parse(amount) * 100).round();
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
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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
      FilledButton(onPressed: onRetry, child: const Text('Try Again')),
    ],
  );
}
