import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

import '../models/app_config.dart';
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

  /// Terminal, unrecoverable capture: the card was charged but the app can
  /// never finish confirming it from here (no payment id came back, or confirm
  /// has failed too many times). The only action left is to dismiss with a
  /// reconcile message — never a re-charge. Distinct from
  /// [_captureOutstanding], which still has a viable "Finish Payment" retry.
  bool _stranded = false;
  int _confirmAttempts = 0;
  static const _maxConfirmAttempts = 3;

  /// Location permission is permanently denied, so the error view offers "Open
  /// Settings" (a re-request can no longer prompt) instead of a "Try Again"
  /// that would silently no-op.
  bool _needsSettings = false;

  /// What the processing spinner says. The same [_Phase.processing] covers two
  /// different network waits — starting the reader (pre-tap) and confirming the
  /// captured payment (post-tap) — so each sets an honest label. Never claims
  /// "hold the card": Square's own full-screen Activity owns the tap UI.
  String _processingMessage = '';

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
    _stranded = false;
    _needsSettings = false;
    _confirmAttempts = 0;
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
      _processingMessage = 'Starting the card reader…';
      _error = null;
    });

    final square = SquarePaymentService.instance;
    try {
      // The Square SDK is initialized from /api/mobile/config/ (warmed at
      // startup). Prefer that app id; fall back to the create response only if
      // config didn't load. No app id at all → Tap to Pay isn't set up.
      final cfg = await _loadConfig();
      // Catch a deployment misconfiguration (e.g. a production app id declared
      // `sandbox`) here, loudly, rather than letting it surface as an opaque
      // authorize/charge failure at the reader.
      if (cfg != null && cfg.hasSquare && !cfg.squareConfigConsistent) {
        _fail(
          'Tap to Pay is misconfigured for this auction (Square environment '
          'mismatch). Please contact the organizer.',
        );
        return;
      }
      final appId = (cfg != null && cfg.hasSquare)
          ? cfg.squareApplicationId
          : ctx.applicationId;
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

      // Square won't start a Tap to Pay charge without runtime location
      // permission — request it before the tap so a denial surfaces here with a
      // clear message instead of an opaque reader failure mid-charge.
      if (!await square.ensureLocationPermission()) {
        _failNeedsLocation(await square.isLocationPermanentlyDenied());
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
        // Charged, but with no id there is nothing to confirm — this can never
        // be finished from the app. Mark it terminal so the sheet offers a
        // dismiss (with a reconcile message) instead of a dead "Finish Payment"
        // that would re-post a null id forever.
        _stranded = true;
        _fail(
          'The card was charged, but the reader did not return a payment id, '
          'so we can\'t record it automatically. Check the invoice — reconcile '
          'it in Square if it stays unpaid. You will not be charged again.',
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
      if (e.code == PaymentErrorCode.locationPermissionNeeded) {
        // Permission was revoked between our check and the tap (or the OS
        // denied it anyway) — treat it like the pre-charge gate.
        _failNeedsLocation(await square.isLocationPermanentlyDenied());
        return;
      }
      if (e.code == PaymentErrorCode.locationServicesDisabled) {
        _fail(
          'Turn on Location (GPS) in your device settings, then try again — '
          'Square Tap to Pay requires it.',
        );
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

  /// The deployment config (Square app id + environment), or null if it hasn't
  /// loaded and can't be fetched. Config is the source of truth (warmed at
  /// startup, cached); the caller falls back to the create response's app id
  /// when this is null.
  Future<AppConfig?> _loadConfig() async {
    final cached = ConfigService.instance.cached;
    if (cached != null) {
      return cached;
    }
    try {
      return await ref.read(configProvider.future);
    } on Exception {
      // Config fetch failed — caller falls back to the create response.
      return null;
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
      _processingMessage = 'Confirming payment…';
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
      // Hold the confirmation long enough for the cashier to read it (and the
      // receipt number) before we dismiss and reload the WebView to PAID.
      await Future<void>.delayed(const Duration(seconds: 4));
      if (mounted) {
        Navigator.of(context).pop(PaymentResult.paid);
      }
    } on DioException catch (e) {
      _confirmAttempts++;
      if (_confirmAttempts >= _maxConfirmAttempts) {
        // Repeated confirm failures (offline, or the backend rejecting) would
        // otherwise trap the cashier behind a "Finish Payment" button that
        // never succeeds. After a few tries, make it dismissible with a
        // reconcile message — the charge is safe on Square either way.
        _stranded = true;
        _fail(
          'The card was charged, but we could not record it after several '
          'tries. Check the invoice — it may update shortly; otherwise '
          'reconcile it in Square. You will not be charged again.',
        );
        return;
      }
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

  /// Location permission is missing. When [permanent] (the user chose "Don't
  /// ask again"), a re-request can't prompt, so the error view surfaces "Open
  /// Settings"; otherwise a plain "Try Again" re-prompts.
  void _failNeedsLocation(bool permanent) {
    _needsSettings = permanent;
    _fail(
      permanent
          ? 'Tap to Pay needs location permission, which is turned off for '
                'auction.fish. Open Settings to allow it, then try again.'
          : 'Tap to Pay needs location permission to accept a card. Please '
                'allow it and try again.',
    );
  }

  Future<void> _openLocationSettings() =>
      SquarePaymentService.instance.openSettings();

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
    // Block back-dismissal only while a charge is outstanding AND still
    // recoverable. Once stranded (terminal), the sheet must be dismissible.
    canPop: !_captureOutstanding || _stranded,
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
          _Phase.processing => _ProcessingView(
            message: _processingMessage,
            amountLabel: _ctx?.amountLabel,
          ),
          _Phase.success => _SuccessView(receipt: _error),
          _Phase.error => _ErrorView(
            message: _error ?? 'Something went wrong.',
            // Stranded (terminal) or permanently-denied location: no retry.
            // Otherwise, while a capture is outstanding, retry must re-confirm
            // the same payment, not start a new charge — and there's no "close"
            // out.
            onRetry: (_stranded || _needsSettings)
                ? null
                : (_captureOutstanding ? _confirmCaptured : _createPayment),
            retryLabel: (_stranded || _needsSettings)
                ? null
                : (_captureOutstanding ? 'Finish Payment' : 'Try Again'),
            // Permanent location denial can only be fixed in OS settings.
            onOpenSettings: _needsSettings ? _openLocationSettings : null,
            onClose: (_stranded || !_captureOutstanding) ? _popCancelled : null,
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
  const _ProcessingView({required this.message, this.amountLabel});

  /// What we're waiting on — set honestly per phase (e.g. "Starting the card
  /// reader…", "Confirming payment…"). Deliberately never instructs the cashier
  /// to tap: Square's full-screen Activity handles the actual card read.
  final String message;

  /// The amount being charged (e.g. `$15.00`), shown so the cashier can confirm
  /// it. Null until the invoice has loaded.
  final String? amountLabel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (amountLabel != null) ...[
        Text(amountLabel!, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
      ],
      const CircularProgressIndicator(),
      const SizedBox(height: 16),
      Text(message, textAlign: TextAlign.center),
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
    this.onRetry,
    this.retryLabel,
    this.onOpenSettings,
    this.onClose,
  });

  final String message;
  final VoidCallback? onRetry;
  final String? retryLabel;

  /// When set, the primary action opens OS settings (a permission the app can
  /// no longer prompt for). Shown instead of a "Try Again" that would no-op.
  final VoidCallback? onOpenSettings;
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
      if (onOpenSettings != null)
        FilledButton(
          onPressed: onOpenSettings,
          child: const Text('Open Settings'),
        ),
      // Stranded errors (and permanent denials) have no retry — dismiss only.
      if (onRetry != null && retryLabel != null) ...[
        if (onOpenSettings != null) const SizedBox(height: 8),
        FilledButton(onPressed: onRetry, child: Text(retryLabel!)),
      ],
      if (onClose != null) ...[
        const SizedBox(height: 8),
        TextButton(onPressed: onClose, child: const Text('Close')),
      ],
    ],
  );
}
