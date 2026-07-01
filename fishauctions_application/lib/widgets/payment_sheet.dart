import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

import '../models/payment_context.dart';
import '../providers/config_provider.dart';
import '../services/api_service.dart';
import '../services/config_service.dart';
import '../services/square_payment_service.dart';

/// How a [PaymentSheet] ended. [paid] means the invoice is settled — the caller
/// should refresh the checkout page so it re-renders PAID (HTMX-style).
/// [cancelled] (also the value when the sheet is dismissed) means nothing was
/// charged; leave the page as-is so its "Tap to Pay" button can retry.
enum PaymentResult { paid, cancelled }

/// Square Tap to Pay checkout as a modal sheet over the WebView, so the cashier
/// never leaves the quick-checkout page. Mirrors the web page but takes a
/// contactless tap instead of showing a QR.
///
/// The tap starts automatically once the invoice loads — the cashier just taps
/// a card. A user cancel dismisses the sheet (the page's own "Tap to Pay"
/// button is the retry); a pre-charge failure offers "Try Again"; a
/// post-charge failure keeps the sheet open with "Finish Payment" so a charged
/// card is never stranded unconfirmed.
///
/// Flow:
///   1. POST /payments/create/ → amount, currency, idempotency key,
///      reference_id (+ per-invoice seller access_token/location_id)
///   2. Authorize the Square SDK (app id from /api/mobile/config/, warmed at
///      startup; per-invoice access_token/location_id from create)
///   3. startPayment() with the backend's reference_id → user taps → Square
///      captures on-device
///   4. POST /payments/confirm/ → backend verifies + marks the invoice PAID
///   5. Pop [PaymentResult.paid]; the WebView reloads to the PAID page
class PaymentSheet extends ConsumerStatefulWidget {
  const PaymentSheet({required this.invoicePk, super.key});

  final int invoicePk;

  /// Presents the sheet over [context]. It is not dismissible by tap/drag —
  /// dismissal is only through the sheet's own controls (or the back button,
  /// which is blocked while a charge is outstanding) — so a charged-but-
  /// unconfirmed payment can't be swiped away. Returns [PaymentResult.paid]
  /// on a settled charge, otherwise null/[PaymentResult.cancelled].
  static Future<PaymentResult?> show(BuildContext context, int invoicePk) =>
      showModalBottomSheet<PaymentResult>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => PaymentSheet(invoicePk: invoicePk),
      );

  @override
  ConsumerState<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<PaymentSheet> {
  _Phase _phase = _Phase.loading;
  String? _error;
  PaymentContext? _ctx;

  /// Set once Square captures the card on-device. While a capture is
  /// outstanding the card has already been charged, so the only safe recovery
  /// is to re-finalize *this* payment — never to start a second charge, and
  /// never to dismiss the sheet.
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
    // this sheet instance. The cross-instance backstop (sheet recreated, or the
    // process is killed mid-tap) is the backend's idempotency key: it is
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
      final ctx = PaymentContext.fromJson(res.data ?? const {});
      if (!mounted) {
        return;
      }
      _ctx = ctx;
      // Auto-start the tap so the cashier only has to tap a card. A user cancel
      // dismisses the sheet; a failure surfaces an in-sheet retry.
      await _startTapToPay();
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
      // The Square SDK is initialized from /api/mobile/config/ (warmed at
      // startup). Prefer that app id; fall back to the create response only if
      // config didn't load. No app id at all → Tap to Pay isn't set up.
      final appId = await _resolveApplicationId(ctx);
      if (appId == null) {
        _fail('Tap to Pay isn\'t set up for this auction.');
        return;
      }
      await square.ensureAuthorized(
        applicationId: appId,
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
        // User backed out of the Square prompt — dismiss the sheet so the
        // page's own "Tap to Pay" button can relaunch. Nothing was charged.
        _popCancelled();
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

  /// The Square Application ID to initialize/authorize with. Config is the
  /// source of truth (warmed at startup, cached); the create response's app id
  /// is only a fallback for when config failed to load.
  Future<String?> _resolveApplicationId(PaymentContext ctx) async {
    final cached = ConfigService.instance.cached;
    if (cached != null) {
      return cached.hasSquare ? cached.squareApplicationId : ctx.applicationId;
    }
    try {
      final cfg = await ref.read(configProvider.future);
      return cfg.hasSquare ? cfg.squareApplicationId : ctx.applicationId;
    } on Exception {
      // Config fetch failed — fall back to whatever create provided.
      return ctx.applicationId;
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
      // Brief confirmation, then dismiss so the WebView reloads to PAID.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) {
        Navigator.of(context).pop(PaymentResult.paid);
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

  void _popCancelled() {
    if (mounted) {
      Navigator.of(context).pop(PaymentResult.cancelled);
    }
  }

  String? _detail(DioException e) {
    final data = e.response?.data;
    return data is Map ? data['detail'] as String? : null;
  }

  // While a charge is outstanding, block the back button so the sheet can't be
  // dismissed before the payment is confirmed (the card has been charged).
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_captureOutstanding,
    child: SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: switch (_phase) {
          _Phase.loading => _LoadingView(onCancel: _popCancelled),
          _Phase.processing => const _ProcessingView(),
          _Phase.success => _SuccessView(receipt: _error),
          _Phase.error => _ErrorView(
            message: _error ?? 'Something went wrong.',
            // While a capture is outstanding, retry must re-confirm the same
            // payment, not start a new charge — and there's no "close" out.
            onRetry: _captureOutstanding ? _confirmCaptured : _createPayment,
            retryLabel: _captureOutstanding ? 'Finish Payment' : 'Try Again',
            onClose: _captureOutstanding ? null : _popCancelled,
          ),
        },
      ),
    ),
  );
}

enum _Phase { loading, processing, success, error }

class _LoadingView extends StatelessWidget {
  const _LoadingView({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const CircularProgressIndicator(),
      const SizedBox(height: 16),
      const Text('Loading invoice…', textAlign: TextAlign.center),
      const SizedBox(height: 16),
      TextButton(onPressed: onCancel, child: const Text('Cancel')),
    ],
  );
}

class _ProcessingView extends StatelessWidget {
  const _ProcessingView();

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.contactless, size: 64),
      SizedBox(height: 16),
      Text(
        'Hold the card near the top of this device…',
        textAlign: TextAlign.center,
      ),
      SizedBox(height: 16),
      CircularProgressIndicator(),
    ],
  );
}

class _SuccessView extends StatelessWidget {
  const _SuccessView({this.receipt});

  final String? receipt;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.check_circle, size: 64, color: Colors.green),
      const SizedBox(height: 16),
      const Text('Payment complete!'),
      if (receipt != null) ...[
        const SizedBox(height: 4),
        Text(
          receipt!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      ],
    ],
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.retryLabel,
    this.onClose,
  });

  final String message;
  final VoidCallback onRetry;
  final String retryLabel;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Icon(
        Icons.error_outline,
        size: 56,
        color: Theme.of(context).colorScheme.error,
      ),
      const SizedBox(height: 16),
      Text(message, textAlign: TextAlign.center),
      const SizedBox(height: 24),
      FilledButton(onPressed: onRetry, child: Text(retryLabel)),
      if (onClose != null) ...[
        const SizedBox(height: 8),
        TextButton(onPressed: onClose, child: const Text('Close')),
      ],
    ],
  );
}
