import 'dart:async';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

import '../models/app_config.dart';
import '../models/payment_context.dart';
import '../models/tap_to_pay_diagnostics.dart';
import '../models/tap_to_pay_status.dart';
import '../providers/config_provider.dart';
import '../services/api_service.dart';
import '../services/config_service.dart';
import '../services/square_payment_service.dart';
import '../services/tap_to_pay_service.dart';
import 'tap_to_pay_branding.dart';
import 'tap_to_pay_education.dart';

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

  /// Set when the error view should offer "Open Settings" instead of "Try
  /// Again" — a fix that lives outside this sheet (permanently-denied
  /// location permission, or NFC toggled off) so a plain retry would either
  /// silently no-op or just hit the same dead end again.
  VoidCallback? _settingsAction;

  /// Android Developer options are on, which stops Square from reading a card.
  /// Purely advisory — the charge is still attempted (see
  /// [SquarePaymentService.isDeveloperModeEnabled]); this only decides whether
  /// the sheet shows its warning strip, so the cashier can recognize the
  /// otherwise-opaque failure instead of retrying blindly.
  bool _developerModeOn = false;

  /// What the processing spinner says. The same [_Phase.processing] covers two
  /// different network waits — starting the reader (pre-tap) and confirming the
  /// captured payment (post-tap) — so each sets an honest label. Never claims
  /// "hold the card": Square's own full-screen Activity owns the tap UI.
  String _processingMessage = '';

  /// Square's own receipt URL for the settled payment, when the backend
  /// returns one. Feeds the "Send receipt" action (Apple's requirement 5.10).
  String? _receiptUrl;

  /// Human-readable receipt/reference for the attempt, shown on the outcome
  /// view and included in a shared receipt.
  String? _receiptNumber;

  /// Set when the charge was declined by the card/issuer rather than failing
  /// for a device or configuration reason. Requirement 5.9 wants the outcome
  /// stated plainly, and 5.10 requires the customer to be able to receive a
  /// receipt **even for a decline** — so the outcome view branches on this.
  bool _declined = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkDeveloperMode());
    _createPayment();
  }

  /// Non-blocking, and deliberately not awaited by [_createPayment]: the tap
  /// must not wait on a warning. It resolves in milliseconds, so the strip is
  /// on screen well before Square's full-screen prompt takes over — and it's
  /// still there when the sheet comes back to the error view, which is where a
  /// developer-mode failure actually lands.
  Future<void> _checkDeveloperMode() async {
    final on = await SquarePaymentService.instance.isDeveloperModeEnabled();
    if (mounted && on) {
      setState(() => _developerModeOn = true);
    }
  }

  Future<void> _createPayment() async {
    // Starting over is only safe when no charge is in flight.
    //
    // The in-memory `_captureOutstanding` guard below protects retries within
    // this sheet instance.
    //
    // It used to claim a cross-instance backstop as well: the backend's
    // idempotency key is derived from the invoice pk, so every create returns
    // the same string, and passing that to Square as the paymentAttemptId was
    // supposed to make Square de-dupe. **Square does not de-dupe an attempt
    // id — it refuses it**, with `payment_attempt_id_reused`, and that is a
    // different Square concept from the Payments API's server-side
    // `idempotency_key`, which does collapse duplicates. The visible cost was
    // total: a declined card is routine, the retry reused the id, and the
    // second tap died inside Square's own UI with "contact the developer of
    // this app". So the feature failed exactly when it was needed.
    //
    // Attempt ids are now per attempt (see `_freshAttemptId`). What that gives
    // up is real and worth naming: a charge captured on-device whose confirm
    // never ran (crash, network) leaves the invoice unpaid, and a later tap can
    // now charge a second time where before it would have been refused. That
    // refusal was indiscriminate rather than principled — it could not tell
    // "you already charged this" from "the last card was declined" — but it
    // did sometimes stop a double charge. The durable fix is a server-side
    // attempt record; specced as `BACKEND_SPEC.md` Part TTP-10.
    _capturedPaymentId = null;
    _captureOutstanding = false;
    _stranded = false;
    _settingsAction = null;
    _confirmAttempts = 0;
    _receiptUrl = null;
    _receiptNumber = null;
    _declined = false;
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
      // Authorization is what makes a Tap to Pay reader exist, so this is the
      // first moment there is anything to listen to. The launch/resume warm-up
      // normally got here first, but it bails before subscribing whenever the
      // backend withheld credentials (endpoint 404, `canCharge` false, a failed
      // fetch) — and the charge path authorizes anyway. Without this the reader
      // status stays `unknown` forever and `_awaitReaderReady` below burns its
      // full timeout on "Checking Tap to Pay…" before every single charge.
      // Idempotent.
      TapToPayService.instance.listenToReader();

      // A location that hasn't finished Square's card-processing activation
      // is a separate prerequisite from having a production application id —
      // without it a charge never prompts for a tap (Square shows the same
      // opaque "connect hardware" screen as an unapproved/incapable device).
      // `false` is a definite answer; null (unknown) doesn't block, since
      // some SDK versions/locations may not report the flag at all.
      if (await square.cardProcessingActivated == false) {
        _fail(
          'This Square location hasn\'t been activated for card processing '
          'yet. Finish that step in your Square Dashboard, then try again.',
        );
        return;
      }

      if (!await square.isDeviceCapable()) {
        _fail(
          Platform.isIOS
              ? 'This device can\'t take Tap to Pay payments. It needs an '
                    'iPhone XS or newer on iOS 16.4+.'
              : 'This device can\'t take Tap to Pay payments. It needs NFC '
                    'and Android 12 or newer.',
        );
        return;
      }

      // The device *has* NFC hardware (just checked above) but it may be
      // toggled off — Square can't tell the app that directly (no reader is
      // "present" to it either way), so it shows the same opaque "connect
      // hardware" prompt as an incapable device. Checking the toggle state
      // ourselves turns that into an actionable message.
      if (!await square.isNfcEnabled()) {
        _failNeedsNfc();
        return;
      }

      // iOS: Tap to Pay requires a one-time Apple account link (an
      // interactive Apple sheet). Doing it here — before the location gate
      // and the tap — keeps the first-ever charge flow linear. No-op on
      // Android and on every later charge.
      final bool justLinked;
      try {
        justLinked = await square.ensureAppleAccountLinked();
      } on Exception {
        _fail(
          'Tap to Pay on iPhone needs this device linked to an Apple '
          'account. The link was cancelled or failed — try again.',
        );
        return;
      }
      // Requirement 4.2: merchant education follows an acceptance of the
      // terms, wherever the acceptance happened. This is the likeliest place
      // for a first-ever acceptance — the settings screen is where setup is
      // *offered*, but checkout is where it becomes urgent — and until now
      // education was wired to the settings screen alone, so accepting here
      // educated nobody.
      //
      // Only on a fresh link, and only ever once: every later charge takes the
      // no-op branch above and goes straight to the tap.
      if (justLinked && mounted) {
        await showTapToPayEducation(context);
        if (!mounted) {
          return;
        }
      }

      // Square won't start a Tap to Pay charge without runtime location
      // permission — request it before the tap so a denial surfaces here with a
      // clear message instead of an opaque reader failure mid-charge.
      if (!await square.ensureLocationPermission()) {
        _failNeedsLocation(await square.isLocationPermanentlyDenied());
        return;
      }

      // Apple's requirement 5.7: if the cashier gets here while Tap to Pay is
      // still configuring, they must see an "initializing" screen saying it
      // will be available soon — not a generic spinner, and certainly not the
      // reader's own opaque failure. Normally instant, because the shell warms
      // the reader at launch and on every resume (requirement 1.5).
      await _awaitReaderReady();
      if (!mounted) {
        return;
      }

      // The reader can be *unavailable* rather than merely not-ready-yet, and
      // once the charge starts Square never says which: `startPayment` puts up
      // the native "connect hardware to take card payments" screen, throws no
      // PaymentError, and looks identical whether the cause is NFC, the
      // merchant account, Apple's terms or a rejected app attestation. The
      // reader's own `unavailableReason` is the single machine-readable
      // account of it, so ask before diving in — and ask the reader *list*,
      // since the status callback only fires on changes and a reader that was
      // already unavailable at subscribe time never produced one.
      //
      // Blocking here is deliberate even though every other pre-flight defers
      // to Square: this reason came from Square, not from our own inference,
      // and the screen it saves the cashier from is a dead end. Retry stays
      // available, so a momentary reason costs one button press.
      final blocked = await TapToPayService.instance.blockingReaderReason();
      if (!mounted) {
        return;
      }
      if (blocked != null) {
        _fail(
          '${describeUnavailableReason(blocked)}\n\n'
          'Square reported: $blocked',
        );
        return;
      }

      // Square's Sandbox environment can't simulate a real NFC tap — there's
      // no way to PCI-certify a software card read, so `charge()` in sandbox
      // always surfaces the native "connect hardware to take card payments"
      // prompt unless the Mock Reader overlay is showing to simulate the tap
      // instead. (Real Tap to Pay also needs Square's production approval —
      // see CLAUDE.md — so a not-yet-approved production account hits the
      // same prompt; the overlay only helps in sandbox.)
      var isSandbox = false;
      try {
        isSandbox = await square.environment() == Environment.sandbox;
      } on Exception {
        isSandbox = false;
      }
      if (isSandbox) {
        setState(() {
          _processingMessage =
              'Sandbox: tap the mock reader overlay to simulate a card…';
        });
        try {
          await square.showMockReaderUI();
        } on Exception {
          // Non-fatal — fall through to charge() regardless; its native
          // prompt still explains what's missing if the overlay didn't show.
        }
      }

      final SquareChargeResult result;
      try {
        result = await square.charge(
          amountCents: ctx.amountCents,
          currencyCode: ctx.currency,
          paymentAttemptId:
              ctx.attemptId ?? _freshAttemptId(ctx.idempotencyKey),
          note: 'Invoice #${widget.invoicePk}',
          // Must be the backend-issued reference_id verbatim — confirm rejects
          // the charge if Square's reference_id doesn't match.
          referenceId: ctx.referenceId,
        );
      } finally {
        if (isSandbox) {
          unawaited(square.hideMockReaderUI());
        }
      }

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
      // Reaching this catch means nothing was captured — a capture assigns
      // `_capturedPaymentId` before anything can throw — so the attempt record
      // can be closed unconditionally here.
      unawaited(
        _closeAttempt(
          e.code == PaymentErrorCode.canceled ? 'canceled' : 'failed',
        ),
      );
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
      if (e.code == PaymentErrorCode.paymentAlreadyInProgress) {
        // Square keeps this paymentAttemptId "in progress" for a few minutes
        // after an interrupted attempt (e.g. the app was closed mid-tap) —
        // there is no SDK call to cancel it from here, and no card was
        // charged. It clears itself; the only fix is to wait it out.
        _fail(
          'A previous payment attempt for this invoice is still finishing on '
          "Square's side — this can happen if the app was closed mid-payment. "
          'Wait a couple of minutes, then try again. No card has been '
          'charged for this attempt.',
        );
        return;
      }
      if (e.code == PaymentErrorCode.paymentAttemptIdReused) {
        // Square refuses a repeated attempt id. Attempt ids are per attempt
        // now, so seeing this means a genuine duplicate rather than the old
        // stable-key bug — and the safe reading is that an earlier tap may
        // have gone through. Never word this as a decline: telling a cashier
        // to ask for another card when the first one may already have been
        // charged is the worst available answer.
        _fail(
          'Square has already seen this payment attempt. Nothing was charged '
          'just now, but an earlier tap on this invoice may have gone '
          'through — check this payment in Square before trying again.',
        );
        return;
      }
      if (e.code == PaymentErrorCode.noNetwork) {
        _fail(
          'No connection to Square, so the payment could not be taken. The '
          'card was not charged. Check the connection and try again.',
        );
        return;
      }
      if (e.code == PaymentErrorCode.timeout) {
        // 5.9 names "timed out" as its own outcome, separate from declined.
        _declined = true;
        _fail(
          'The card read timed out. The card was not charged — hold the card '
          'against the top of the phone until it confirms, and try again.',
        );
        return;
      }
      // What's left is the card or issuer refusing — or an SDK failure we
      // can't tell apart from one, since the SDK has no "declined" code.
      // Requirement 5.9 wants the outcome stated as an outcome rather than as
      // an app error, and 5.10 wants a receipt offered for it, which
      // `_declined` switches on. Worded so it is true either way: this used to
      // assert "Payment declined" for every unrecognised code, which is how
      // `payment_attempt_id_reused` reached a cashier as a card problem.
      _declined = true;
      _fail(
        'The payment didn\'t go through. ${e.message}\n\nThe card was not '
        'charged. Ask the customer for another card or payment method, then '
        'try again.',
      );
    } on AuthorizeError catch (e) {
      unawaited(_closeAttempt('failed'));
      if (e.code ==
          AuthorizationErrorCode.locationNotActivatedForCardProcessing) {
        // Same underlying cause as the pre-flight cardProcessingActivated
        // check above — this is the SDK catching it at authorize() time
        // instead, on builds/locations where the flag isn't proactively
        // reported.
        _fail(
          'This Square location hasn\'t been activated for card processing '
          'yet. Finish that step in your Square Dashboard, then try again.',
        );
        return;
      }
      _fail('Could not start the card reader: ${e.message}');
    } on Exception catch (e) {
      unawaited(_closeAttempt('failed'));
      // Any other SDK/platform failure — never leave the spinner hanging.
      _fail('Payment could not be completed: $e');
    }
  }

  /// Waits — showing the "initializing" view — until the Tap to Pay reader
  /// reports ready, or until [_readerReadyTimeout] elapses.
  ///
  /// Apple's requirement 5.7 asks for this screen; the timeout is what keeps it
  /// honest. The reader status is a best-effort signal even with the reader
  /// list read directly below (Android doesn't report Tap to Pay readiness the
  /// same way, and a deployment can leave it unknown), so after the timeout we
  /// start the charge anyway and let Square's own prompt be the authority.
  /// Blocking a charge on our own progress indicator would be strictly worse
  /// than the behaviour this replaces.
  Future<void> _awaitReaderReady() async {
    final service = TapToPayService.instance;
    final status = service.status;
    bool settled() =>
        status.value.isReady ||
        status.value == TapToPayReaderStatus.unavailable;
    // Ask the reader list before waiting on the callback. `status` is fed by
    // Square's reader *change* events, and a reader that armed before the app
    // subscribed never emits one — so a warm reader can leave this notifier at
    // `unknown` for the whole process, and `unknown` is (correctly) treated
    // below as "still configuring". That is a full timeout of "initializing"
    // in front of every charge on a reader that has been ready all along.
    await service.syncStatusFromReaders();
    if (!mounted) {
      return;
    }
    // `unavailable` is an answer, not a stage on the way to one — waiting the
    // full timeout for it only delays the message that explains it.
    if (settled()) {
      return;
    }
    setState(() {
      _phase = _Phase.initializing;
      _error = null;
    });
    final ready = Completer<void>();
    void listener() {
      if (settled() && !ready.isCompleted) {
        ready.complete();
      }
    }

    status.addListener(listener);
    // Same reason as the read above: the wait must not depend on an event that
    // may never come. Assigning an unchanged value notifies nobody, so a poll
    // that finds no news costs a `getReaders()` call and wakes no listener.
    final poll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(service.syncStatusFromReaders()),
    );
    try {
      await ready.future.timeout(
        _readerReadyTimeout,
        onTimeout: () {
          // Deliberately not an error — see the doc comment.
        },
      );
    } finally {
      poll.cancel();
      status.removeListener(listener);
    }
  }

  /// How long the "initializing" view waits for the reader before starting the
  /// charge regardless. Long enough to cover a genuine cold configure, short
  /// enough that a never-arriving status doesn't strand the cashier.
  static const _readerReadyTimeout = Duration(seconds: 12);

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
      _receiptNumber = receipt?.toString();
      // Square's hosted receipt for this payment, when the backend passes it
      // through from GetPayment. It's what makes the "Send receipt" action
      // (requirement 5.10) a real receipt rather than a reference number —
      // absent on deployments that don't return it yet, which the share text
      // handles (BACKEND_SPEC.md Part TTP).
      _receiptUrl = (data['receipt_url'] as String?)?.trim();
      if (_receiptUrl?.isEmpty ?? false) {
        _receiptUrl = null;
      }
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
      // The sheet used to dismiss itself after four seconds. It can't any more:
      // Apple's requirement 5.10 says it must be possible to send the customer
      // a confidential digital receipt from here, and a window that closes on
      // its own is not a way to offer that. The cashier now taps "Done" — one
      // extra tap at the end of a charge, in exchange for the receipt action
      // actually being reachable.
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

  /// Tell the backend an attempt ended without charging anything.
  ///
  /// **Load-bearing for retries.** Once the server refuses a `create` while an
  /// attempt is still open — which is the whole point of tracking them, since
  /// an attempt left open is how a crashed capture is detected — a declined
  /// card would otherwise block the very next tap. Declines are routine, so
  /// without this the durable fix would recreate the bug it replaces.
  ///
  /// Best effort, and deliberately never surfaced: a bookkeeping call failing
  /// must not fail the cashier's payment, and the server ages out stale
  /// attempts anyway. No-ops on a backend that issues no
  /// [PaymentContext.attemptId].
  Future<void> _closeAttempt(String outcome) async {
    final id = _ctx?.attemptId;
    if (id == null || _attemptClosed) {
      return;
    }
    _attemptClosed = true;
    try {
      await ApiService.instance.dio.post<Map<String, dynamic>>(
        'payments/attempt/close/',
        data: {'attempt_id': id, 'outcome': outcome},
        options: Options(validateStatus: (s) => s != null && s < 500),
      );
    } on DioException catch (_) {
      // Offline, or an older backend with no such endpoint. Either way the
      // server's own expiry is the backstop.
    }
  }

  /// A per-attempt id for Square's SDK, derived from the backend's key.
  ///
  /// `paymentAttemptId` must be unique per attempt — a repeat is rejected with
  /// `payment_attempt_id_reused`, which surfaces inside Square's own UI as
  /// "something went wrong, please contact the developer of this app". It is
  /// **not** the Payments API's `idempotency_key`, despite the backend deriving
  /// this value as one; the two names describe opposite behaviours.
  ///
  /// Derived rather than random so a charge is still traceable to its invoice
  /// in Square's dashboard, and clamped to Square's 45-character limit by
  /// trimming the invoice part rather than the nonce, since the nonce is the
  /// half that has to stay intact.
  static String _freshAttemptId(String base) {
    final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    const limit = 45;
    final room = limit - nonce.length - 1;
    final head = base.length > room ? base.substring(0, room) : base;
    return '$head-$nonce';
  }

  /// Whether [_closeAttempt] has already run for this attempt.
  bool _attemptClosed = false;

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
    _settingsAction = permanent
        ? SquarePaymentService.instance.openSettings
        : null;
    _fail(
      permanent
          ? 'Tap to Pay needs location permission, which is turned off for '
                'auction.fish. Open Settings to allow it, then try again.'
          : 'Tap to Pay needs location permission to accept a card. Please '
                'allow it and try again.',
    );
  }

  /// NFC hardware is present (device is otherwise capable) but turned off.
  /// Square shows this as an opaque "connect hardware" prompt with no
  /// catchable error, so this check runs before the tap to give it a
  /// specific, actionable message instead.
  void _failNeedsNfc() {
    _settingsAction = SquarePaymentService.instance.openNfcSettings;
    _fail('Turn on NFC in your phone\'s settings to use Tap to Pay.');
  }

  void _popCancelled() {
    if (mounted) {
      Navigator.of(context).pop(PaymentResult.cancelled);
    }
  }

  /// Sends the customer a receipt for this attempt through the OS share sheet.
  ///
  /// Apple's requirement 5.10: *"Regardless of whether a transaction is
  /// approved or declined, it must be possible to send a confidential digital
  /// receipt to the customer. This could be done via SMS, email, QR code, or
  /// Activity views."* The share sheet **is** an Activity view, which is why
  /// this is a share rather than a bespoke "enter their email" form: it reaches
  /// Messages, Mail, AirDrop and anything else the customer already uses,
  /// without the app ever storing a customer's contact details.
  ///
  /// Confidential by construction — nothing here carries a card number, and the
  /// hosted receipt URL is Square's own single-payment link.
  Future<void> _shareReceipt() async {
    final ctx = _ctx;
    final lines = <String>[
      if (_declined)
        'Payment declined — invoice #${widget.invoicePk}'
      else
        'Payment received — invoice #${widget.invoicePk}',
      if (ctx != null) 'Amount: ${ctx.amountLabel}',
      if (_receiptNumber != null) 'Receipt: $_receiptNumber',
      ?_receiptUrl,
      if (_declined)
        'This card was not charged. The invoice is still outstanding.',
    ];
    final params = ShareParams(
      text: lines.join('\n'),
      subject: 'Receipt for invoice #${widget.invoicePk}',
    );
    try {
      await SharePlus.instance.share(params);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn\'t open the share sheet.')),
        );
      }
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Advisory only, and never on the success view — a charge that went
            // through has nothing left to warn about.
            if (_developerModeOn && _phase != _Phase.success) ...[
              const _DeveloperModeNotice(),
              const SizedBox(height: 16),
            ],
            switch (_phase) {
              _Phase.loading => _LoadingView(onCancel: _popCancelled),
              _Phase.initializing => _InitializingView(
                amountLabel: _ctx?.amountLabel,
              ),
              _Phase.processing => _ProcessingView(
                message: _processingMessage,
                amountLabel: _ctx?.amountLabel,
              ),
              _Phase.success => _SuccessView(
                receipt: _error,
                amountLabel: _ctx?.amountLabel,
                onShareReceipt: _shareReceipt,
                onDone: () => Navigator.of(context).pop(PaymentResult.paid),
              ),
              _Phase.error => _ErrorView(
                message: _error ?? 'Something went wrong.',
                // 5.10: a declined transaction must still be able to send the
                // customer a receipt.
                onShareReceipt: _declined ? _shareReceipt : null,
                // Stranded (terminal) or fixable-only-in-settings: no retry.
                // Otherwise, while a capture is outstanding, retry must
                // re-confirm the same payment, not start a new charge — and
                // there's no "close" out.
                onRetry: (_stranded || _settingsAction != null)
                    ? null
                    : (_captureOutstanding ? _confirmCaptured : _createPayment),
                retryLabel: (_stranded || _settingsAction != null)
                    ? null
                    : (_captureOutstanding ? 'Finish Payment' : 'Try Again'),
                onOpenSettings: _settingsAction,
                onClose: (_stranded || !_captureOutstanding)
                    ? _popCancelled
                    : null,
              ),
            },
          ],
        ),
      ),
    ),
  );
}

enum _Phase { loading, initializing, processing, success, error }

/// Apple's requirement 5.7: the cashier pressed the Tap to Pay button while the
/// reader is still being configured, so they get a screen that says so and says
/// it will be available soon — rather than an indefinite spinner or, worse,
/// Square's opaque "connect hardware" prompt.
///
/// It also renders the reader's live configuration progress (requirement
/// 3.9.1), which is the same signal the settings screen shows.
class _InitializingView extends StatelessWidget {
  const _InitializingView({this.amountLabel});

  final String? amountLabel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (amountLabel != null) ...[
        Text(amountLabel!, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
      ],
      ValueListenableBuilder<TapToPayReaderStatus>(
        valueListenable: TapToPayService.instance.status,
        builder: (context, status, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: double.infinity,
              child: LinearProgressIndicator(),
            ),
            const SizedBox(height: 16),
            Text(status.message, textAlign: TextAlign.center),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(
        '$tapToPayName will be available in a moment.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

/// Warns that Android Developer options are on, which stops Square's reader
/// from taking a tap. Deliberately a passive strip, not a gate: the app can't
/// turn developer mode off, the tap is still attempted, and without this the
/// failure is indistinguishable from "no reader available".
class _DeveloperModeNotice extends StatelessWidget {
  const _DeveloperModeNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 20,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Developer options are on for this phone. Square Tap to Pay '
              "won't read a card while they are — turn them off in Settings › "
              'System › Developer options if the tap fails.',
              style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

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

/// The approved outcome (requirement 5.9), plus the receipt action Apple
/// requires be available for it (5.10).
class _SuccessView extends StatelessWidget {
  const _SuccessView({
    required this.onShareReceipt,
    required this.onDone,
    this.receipt,
    this.amountLabel,
  });

  final String? receipt;
  final String? amountLabel;
  final Future<void> Function() onShareReceipt;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Icon(Icons.check_circle, size: 64, color: Colors.green),
      const SizedBox(height: 16),
      Text(
        amountLabel == null ? 'Approved' : 'Approved — $amountLabel',
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      if (receipt != null) ...[
        const SizedBox(height: 4),
        Text(
          receipt!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      ],
      const SizedBox(height: 24),
      OutlinedButton.icon(
        onPressed: onShareReceipt,
        icon: const Icon(Icons.ios_share),
        label: const Text('Send receipt to customer'),
      ),
      const SizedBox(height: 8),
      FilledButton(onPressed: onDone, child: const Text('Done')),
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
    this.onShareReceipt,
  });

  final String message;
  final VoidCallback? onRetry;
  final String? retryLabel;

  /// When set, the primary action opens OS settings (a permission the app can
  /// no longer prompt for). Shown instead of a "Try Again" that would no-op.
  final VoidCallback? onOpenSettings;
  final VoidCallback? onClose;

  /// Set only for a *declined* transaction, where Apple's requirement 5.10
  /// still expects the customer to be able to receive a receipt. Deliberately
  /// null for device/config failures: nothing was presented to a customer
  /// there, so there is no receipt to send.
  final Future<void> Function()? onShareReceipt;

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
      if (onShareReceipt != null) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onShareReceipt,
          icon: const Icon(Icons.ios_share),
          label: const Text('Send receipt to customer'),
        ),
      ],
      if (onClose != null) ...[
        const SizedBox(height: 8),
        TextButton(onPressed: onClose, child: const Text('Close')),
      ],
    ],
  );
}
