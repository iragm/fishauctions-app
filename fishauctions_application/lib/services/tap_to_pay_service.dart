import 'dart:async';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

import '../models/tap_to_pay_diagnostics.dart';
import '../models/tap_to_pay_status.dart';
import '../utils/platform_bridge.dart';
import '../widgets/tap_to_pay_awareness.dart';
import 'api_service.dart';
import 'square_payment_service.dart';

/// Everything about Tap to Pay that isn't the charge itself: who's allowed to
/// use it, getting the reader warmed up before the cashier needs it, whether
/// this merchant has accepted Apple's terms, and Apple's merchant education.
///
/// This exists because Apple reviews Tap to Pay apps against a published
/// checklist (the *Tap to Pay on iPhone App & Marketing Requirements and Review
/// Guide*), and several of its **required** items are things the charge path
/// alone can't satisfy:
///
/// - **1.5** the app must trigger Tap to Pay's preparation/warm-up at launch or
///   foreground, not at checkout — hence [prepare].
/// - **1.6** the merchant's terms-acceptance status must be read from Apple
///   every time, never cached in an app variable — hence [isEnabled] going
///   straight to the SDK on every call, with no memoization anywhere in this
///   file. Resist adding one.
/// - **3.9.1 / 5.7** the app must show a configuration-progress indicator while
///   the reader gets ready — hence [status], fed by Square's reader callback.
/// - **3.5 / 3.6** accepting the terms must be an explicit action available
///   outside the checkout flow — hence [enable] and the settings screen.
/// - **3.8 / 3.8.1** only an authorized merchant may accept the terms, and
///   everyone else must be told to contact an admin — hence [eligibility].
/// - **4.1 / 4.2** Apple's own education sheet must be shown after acceptance —
///   hence [presentEducation].
///
/// Degradation contract, matching the rest of the app: the eligibility endpoint
/// 404ing (a deployment without `BACKEND_SPEC.md` Part TTP) disables *pre*-
/// authorization for the process and leaves eligibility unknown. It never
/// disables Tap to Pay — the per-invoice `/payments/create/` path is untouched
/// and still authorizes at charge time, exactly as it does today.
class TapToPayService {
  TapToPayService._();
  static final TapToPayService instance = TapToPayService._();

  /// The reader's readiness, for the progress indicators Apple requires
  /// (3.9.1 and 5.7). Starts [TapToPayReaderStatus.unknown]; Square's reader
  /// callback drives it from there.
  final ValueNotifier<TapToPayReaderStatus> status = ValueNotifier(
    TapToPayReaderStatus.unknown,
  );

  /// What the backend says about this operator's Tap to Pay standing, or null
  /// until the first successful fetch (or on a deployment without the
  /// endpoint). Drives the settings screen and the awareness moment.
  final ValueNotifier<TapToPayEligibility?> eligibility = ValueNotifier(null);

  /// Set false for the process once the eligibility endpoint 404s, so an older
  /// deployment costs one request rather than one per foreground.
  bool _endpointAvailable = true;

  /// Guards against overlapping [prepare] runs — the shell calls it at mount
  /// and again on every resume, and a slow authorize must not stack.
  bool _preparing = false;

  ReaderCallbackReference? _readerCallback;

  /// The last reason Square gave for the Tap to Pay reader being unavailable
  /// — the SDK enum's name, e.g. `tapToPayIsNotLinked`, `internalError`.
  ///
  /// This used to be thrown away ("the charge path produces far better
  /// diagnostics"), which was true only while the charge path had catchable
  /// failures left to report. Once Square declines to arm the reader there is
  /// no [PaymentError] at all — just the native "connect hardware to take card
  /// payments" screen — and this string is the only account of why.
  String? _lastUnavailableReason;

  String? get lastUnavailableReason => _lastUnavailableReason;

  /// True on the platform Apple's requirements apply to. Android has its own
  /// Tap to Pay story (already shipping and verified) and none of Apple's
  /// education/terms APIs; the guide-driven UI is therefore iOS-only, while
  /// the *charge* path stays shared.
  bool get isApplePlatform => Platform.isIOS;

  /// Whether this merchant has accepted Apple's Tap to Pay terms on this
  /// device — asked of Apple through the SDK on **every** call.
  ///
  /// Apple's requirement 1.6 is explicit that this must not be held in an app
  /// variable: the merchant can unlink their Apple Account from Settings (or
  /// on another device) at any time, and a cached `true` would send the app
  /// into a charge that can only fail. Cheap enough to ask every time.
  Future<bool> isEnabled() async {
    if (!Platform.isIOS) {
      // Android Tap to Pay has no Apple-account link step; it's enabled as
      // soon as the SDK is authorized.
      return SquarePaymentService.instance.isAuthorized;
    }
    try {
      return await SquarePaymentService.instance.isAppleAccountLinked();
    } on Object {
      // The SDK throws when it isn't initialized yet (no config fetched, or a
      // deployment with no Square). Not enabled, and not an error worth
      // surfacing here — the setup screen reports it as "not set up".
      return false;
    }
  }

  /// Fetches this operator's Tap to Pay standing from the backend and, when
  /// they're a merchant, pre-authorizes the SDK so the reader is warm.
  ///
  /// This is Apple's requirement 1.5 ("at the launch of your app or when it
  /// comes to the foreground, your app must trigger the initial preparation
  /// and warming-up of Tap to Pay") and it's also what makes 5.6 achievable —
  /// the Tap to Pay UI has to appear within one second of the button press,
  /// 90% of the time, which a cold `authorize()` at checkout cannot do.
  ///
  /// Best-effort throughout: nothing here is allowed to throw into the shell,
  /// and failing to warm up only costs the first charge its old latency.
  Future<void> prepare({required String? applicationId}) async {
    if (_preparing || !_endpointAvailable) {
      return;
    }
    _preparing = true;
    try {
      final info = await _fetchEligibility();
      if (info == null) {
        return;
      }
      eligibility.value = info;
      // No credentials means there's nothing to warm: either the user isn't a
      // merchant, or the backend deliberately withheld them (it only issues a
      // token to someone who could charge an invoice right now).
      if (applicationId == null || !info.canCharge) {
        return;
      }
      listenToReader();
      // Deliberately no "already prepared for this location" short-circuit
      // here. `ensureAuthorized` is itself a no-op when the SDK still holds an
      // authorization for the same location — it just reads two SDK getters —
      // and it *does* re-authorize when the SDK has dropped it. Caching the
      // answer in this class instead would make the on-resume warm-up
      // (requirement 1.5's "or when it comes to the foreground") do nothing in
      // exactly the case it exists for.
      await SquarePaymentService.instance.ensureAuthorized(
        applicationId: applicationId,
        accessToken: info.accessToken!,
        locationId: info.locationId!,
      );
      // Again, because the call above is the first thing guaranteed to have
      // initialized the SDK — and `listenToReader` declines to subscribe
      // before that, since on Android touching the plugin first ends the
      // process. Idempotent: it returns immediately once subscribed.
      listenToReader();
      // And read the reader's status outright, because subscribing to a change
      // feed after the change has happened learns nothing — see
      // [syncStatusFromReaders]. This is also what makes the on-resume warm-up
      // worth running: it re-reads a reader that armed while we were away.
      await syncStatusFromReaders();
    } on Object catch (e) {
      // An authorize failure at warm-up time is not the cashier's problem yet:
      // the charge path re-authorizes and reports failures with real context.
      debugPrint('Tap to Pay warm-up skipped: $e');
    } finally {
      _preparing = false;
    }
  }

  /// GETs the eligibility/pre-authorization payload, or null when this
  /// deployment doesn't serve it (404 → disabled for the process) or the
  /// request failed (transient; retried on the next foreground).
  Future<TapToPayEligibility?> _fetchEligibility() async {
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'payments/authorization/',
      );
      return TapToPayEligibility.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _endpointAvailable = false;
      }
      return null;
    }
  }

  /// Subscribes to Square's reader changes so [status] tracks the reader's
  /// configuration progress. Idempotent — the shell prepares on every resume.
  ///
  /// Public because [prepare] is not the only path that authorizes the SDK,
  /// and it is the *authorization* that makes a reader exist. Warm-up bails
  /// before subscribing whenever the backend withholds credentials — the
  /// endpoint 404ing, `canCharge` false, or a transient fetch failure — and in
  /// every one of those cases the per-invoice charge path still authorizes and
  /// still needs a reader. Without a subscription [status] stays
  /// [TapToPayReaderStatus.unknown] for the life of the process, which the
  /// payment sheet reads as "still configuring" and waits the full reader
  /// timeout on, every single charge, showing "Checking Tap to Pay…".
  void listenToReader() {
    if (_readerCallback != null) {
      return;
    }
    if (!SquarePaymentService.instance.isInitialized) {
      // Nothing to subscribe to yet, and on Android asking anyway ends the
      // process (see PlatformBridge.squareInitialized). `prepare` calls this
      // again after `ensureAuthorized`, which initializes.
      return;
    }
    try {
      _readerCallback = SquarePaymentService.instance.onReaderChanged((event) {
        final reader = event.reader;
        // Only the Tap to Pay "reader" matters here. A deployment could in
        // principle have a physical Square reader paired too, and its firmware
        // updates must not drive the Tap to Pay progress indicator.
        if (reader.model != ReaderModel.tapToPay) {
          return;
        }
        // Set the reason *before* the notifier fires: a listener woken by the
        // status change must not read a reason from the previous event.
        final reason = reader.statusInfo.unavailableReason?.name;
        _lastUnavailableReason = reason;
        if (reason != null) {
          // The only place this failure is ever legible from outside the app.
          debugPrint(
            'Tap to Pay reader unavailable: $reason — '
            '${describeUnavailableReason(reason)}',
          );
        }
        status.value = TapToPayReaderStatus.fromSquare(
          reader.statusInfo.status,
          reader.statusInfo.unavailableReason,
        );
      });
      // The subscription can only report what happens next, and by here the
      // reader may already be armed. Not awaited: subscribing is the caller's
      // ask, and this is a best-effort catch-up on what it missed.
      unawaited(syncStatusFromReaders());
    } on Object catch (e) {
      // No reader stream (SDK not initialized, plugin gap) — the indicator just
      // stays "unknown", which the UI renders as a neutral spinner.
      debugPrint('Tap to Pay reader status unavailable: $e');
    }
  }

  /// Sets [status] from the reader **list**, which is the state rather than the
  /// change feed [listenToReader] subscribes to.
  ///
  /// Square only emits a reader event when something *changes*, and this app
  /// cannot subscribe until the SDK is initialized and authorized (on Android,
  /// asking earlier ends the process) — while authorizing is the very thing
  /// that makes the Tap to Pay reader exist and start arming. So the reader
  /// routinely reaches `ready` a moment before, or in the same breath as, the
  /// subscription that would have reported it, and no event ever arrives.
  ///
  /// [status] then sits at [TapToPayReaderStatus.unknown] for the life of the
  /// process. Nothing looks broken: the settings screen renders it as
  /// "Checking Tap to Pay…", and the payment sheet — which treats `unknown` as
  /// "still configuring", correctly — waits its full reader timeout on an
  /// "initializing" screen before **every single charge**, on a reader that
  /// has been ready the whole time.
  ///
  /// Leaves [status] untouched when no Tap to Pay reader is listed yet: that is
  /// "nothing to report", not "unavailable".
  Future<void> syncStatusFromReaders() async {
    try {
      for (final reader in await SquarePaymentService.instance.readers()) {
        if (reader.model != ReaderModel.tapToPay) {
          continue;
        }
        // Reason before status, same ordering as the callback: a listener woken
        // by the status change must not read the previous reason.
        _lastUnavailableReason = reader.statusInfo.unavailableReason?.name;
        status.value = TapToPayReaderStatus.fromSquare(
          reader.statusInfo.status,
          reader.statusInfo.unavailableReason,
        );
        return;
      }
    } on Object catch (e) {
      // Same rule as everywhere else here: our own diagnostics never block a
      // charge. An unreadable list leaves the status where it was.
      debugPrint('Tap to Pay reader list unreadable: $e');
    }
  }

  /// The SDK's current reader list, flattened to primitives.
  Future<List<TapToPayReaderLine>> readerLines() async {
    final readers = await SquarePaymentService.instance.readers();
    return [
      for (final r in readers)
        TapToPayReaderLine(
          model: r.model.name,
          status: r.statusInfo.status.name,
          id: r.id,
          name: r.name,
          unavailableReason: r.statusInfo.unavailableReason?.name,
        ),
    ];
  }

  /// Why a tap can't happen right now, or null when nothing objects.
  ///
  /// Reads the reader **list** rather than [lastUnavailableReason], because
  /// the callback only fires on *changes*: a reader that has been unavailable
  /// since before the app subscribed never produces one, which is exactly the
  /// case at checkout on a cold start.
  ///
  /// A probe that throws also answers null. Never block a charge on our own
  /// diagnostics — same rule as [prepare] and the reader-ready timeout: if
  /// this is wrong, Square's prompt is still the authority.
  Future<String?> blockingReaderReason() async {
    try {
      for (final line in await readerLines()) {
        if (line.isTapToPay) {
          return line.unavailableReason;
        }
      }
      return null;
    } on Object catch (e) {
      debugPrint('Tap to Pay reader probe failed: $e');
      return null;
    }
  }

  /// Everything that decides whether a tap can happen, in one snapshot.
  ///
  /// Each field is collected independently: a probe that throws contributes
  /// its error to the report instead of aborting it, because the half that did
  /// come back is usually the half that matters. Also `debugPrint`ed, so the
  /// same block reaches `flutter logs` / `idevicesyslog` on a build with no
  /// debugger attached.
  Future<TapToPayDiagnostics> diagnose({String? applicationId}) async {
    // The callback is what fills `lastUnavailableReason`, and a diagnostics
    // run is often the first thing that happens on a device the warm-up
    // declined to subscribe on. Cheap and idempotent.
    listenToReader();
    // So that the `readerStatus` line agrees with the reader list printed
    // underneath it — the callback may never have fired at all.
    await syncStatusFromReaders();
    final errors = <String>[];
    Future<T?> probe<T>(String label, Future<T> Function() read) async {
      try {
        return await read();
      } on Object catch (e) {
        errors.add('$label: $e');
        return null;
      }
    }

    final square = SquarePaymentService.instance;
    final environment = await probe(
      'environment',
      () async => (await square.environment())?.name,
    );
    final capable = await probe('isDeviceCapable', square.isDeviceCapable);
    final linked = Platform.isIOS
        ? await probe('isAppleAccountLinked', square.isAppleAccountLinked)
        : null;
    final authorized = await probe('isAuthorized', () => square.isAuthorized);
    final location = await probe(
      'authorizedLocation',
      square.authorizedLocation,
    );
    final readers =
        await probe('getReaders', readerLines) ?? const <TapToPayReaderLine>[];
    final os = await probe('osVersion', PlatformBridge.osVersion) ?? '';
    final standing = eligibility.value;

    final report = TapToPayDiagnostics(
      capturedAt: DateTime.now(),
      platform: Platform.operatingSystem,
      osVersion: os,
      readers: readers,
      errors: errors,
      applicationId: applicationId,
      environment: environment,
      deviceCapable: capable,
      appleAccountLinked: linked,
      authorized: authorized,
      locationId: location?.id,
      locationName: location?.name,
      merchantId: location?.merchantId,
      cardProcessingActivated: location?.cardProcessingActivated,
      eligible: standing?.eligible,
      canCharge: standing?.canCharge,
      sellerName: standing?.sellerName,
      eligibilityMessage: standing?.message,
      readerStatus: status.value.name,
      lastUnavailableReason: _lastUnavailableReason,
    );
    debugPrint(report.toReport());
    return report;
  }

  /// Runs the merchant's acceptance of Apple's Tap to Pay Terms and Conditions
  /// — Apple's own sheet, presented by the Square SDK's `linkAppleAccount()`.
  ///
  /// This is requirement 3.5's "clear action to accept the Terms and
  /// Conditions", and calling it from the settings screen is what satisfies
  /// 3.6 (enablement must be reachable outside the checkout flow). Returns
  /// true once the account is linked.
  ///
  /// Deliberately does **not** present education itself — the caller does that
  /// straight after, because requirement 4.2 wants education *after* the terms
  /// are accepted, and only the caller knows whether it's in a context where a
  /// second sheet makes sense.
  Future<bool> enable() async {
    if (!Platform.isIOS) {
      return SquarePaymentService.instance.isAuthorized;
    }
    await SquarePaymentService.instance.ensureAppleAccountLinked();
    return isEnabled();
  }

  /// Shows Apple's merchant-education sheet (requirement 4.1), returning
  /// whether it actually appeared. False on iOS 17 and earlier, on Android,
  /// and if the sheet errors — the caller then shows its own text fallback.
  Future<bool> presentEducation() async {
    final outcome = await PlatformBridge.presentTapToPayEducation();
    if (outcome != 'presented') {
      debugPrint(
        'Tap to Pay education not shown ($outcome): '
        '${lastEducationError ?? 'no reason reported'}',
      );
    }
    return outcome == 'presented';
  }

  /// Why Apple's sheet last fell back to the app's own text, or null.
  ///
  /// Requirement 4.1 makes Apple's sheet mandatory from iOS 18, so a fallback
  /// on a modern iPhone is a defect rather than a graceful degradation — and it
  /// is invisible, because the fallback is a perfectly ordinary-looking sheet.
  /// The screen surfaces this so the difference is legible without a debugger.
  String? get lastEducationError => PlatformBridge.lastTapToPayEducationError;

  /// Whether Apple's education sheet exists on this OS (iOS 18+).
  Future<bool> educationAvailable() =>
      PlatformBridge.tapToPayEducationAvailable();

  /// Why Tap to Pay is unavailable on this device, distinguishing "your iOS is
  /// too old" from "this iPhone will never work".
  ///
  /// Apple's requirement 1.4: *"For iOS versions prior to 17.6, your app must
  /// handle the `PaymentCardReaderError.osVersionNotSupported` error by
  /// displaying a message informing the user that they need to update to the
  /// latest iOS version."* We never see that error — Square's SDK owns the
  /// reader and collapses every cause into a single
  /// `isDeviceCapable() == false` — so the OS version is read separately and
  /// takes precedence below 17.6, which is exactly the boundary Apple names.
  ///
  /// The threshold is 17.6 and not the 16.4 Tap to Pay floor on purpose. Apple
  /// treats anything below 17.6 as a version where the OS is a plausible cause,
  /// and the cost of the two mistakes is not symmetric: telling an iPhone XS
  /// owner on iOS 16.2 to buy a new phone is unrecoverable, while telling an
  /// iPhone 8 owner to update is merely unhelpful — and
  /// [TapToPayUnsupportedReason.osVersion]'s copy names the hardware
  /// requirement too, so even that reader learns the real answer.
  Future<TapToPayUnsupportedReason> unsupportedReason() async {
    bool capable;
    try {
      capable = await SquarePaymentService.instance.isDeviceCapable();
    } on Object {
      capable = false;
    }
    if (capable) {
      return TapToPayUnsupportedReason.none;
    }
    if (!Platform.isIOS) {
      return TapToPayUnsupportedReason.device;
    }
    return isBelowOsFloor(await PlatformBridge.osVersion())
        ? TapToPayUnsupportedReason.osVersion
        : TapToPayUnsupportedReason.device;
  }

  /// The iOS version below which an incapable device is reported as needing an
  /// OS update. Named by Apple in requirement 1.4 — see [unsupportedReason].
  static const List<int> osVersionFloor = [17, 6];

  /// Whether [raw] (a `UIDevice.systemVersion` string like `"17.5.1"`) is below
  /// [osVersionFloor].
  ///
  /// Compares numerically, component by component — never as a `double`, which
  /// silently ranks `"17.10"` below `"17.6"`. An unparseable or empty string is
  /// *not* below the floor: with no evidence the OS is at fault, the honest
  /// answer is the device.
  @visibleForTesting
  static bool isBelowOsFloor(String raw) {
    final parts = raw.split('.');
    final major = int.tryParse(parts.isEmpty ? '' : parts[0]);
    if (major == null) {
      return false;
    }
    if (major != osVersionFloor[0]) {
      return major < osVersionFloor[0];
    }
    final minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return minor < osVersionFloor[1];
  }

  /// Puts this device back to its pre-setup state so Apple's onboarding and
  /// education flows can be recorded again.
  ///
  /// Clears the once-per-install awareness marker, releases the Square
  /// authorization (so the reader has to arm from cold) and drops this
  /// service's own state. The one thing it cannot clear is the **Apple Account
  /// link** — the SDK has no unlink — so the linking step is re-recorded with
  /// `SquarePaymentService.relinkAppleAccount()`, which presents the same
  /// sheet on an already-linked device. That call needs the SDK **authorized**
  /// and this one releases the authorization, so the caller presents the sheet
  /// before calling this, never after — see `_resetForRecording` on the
  /// settings screen.
  ///
  /// The released authorization comes back on the next warm-up (launch,
  /// resume, or a pull-to-refresh on the settings screen), which is the point:
  /// the reader re-arms where the merchant can watch it.
  ///
  /// A *real* unlink does exist, just not through any API: Apple's
  /// `businessconnect.apple.com/taptopay/removeall` removes every Tap to Pay
  /// merchant id from an Apple Account, after which acceptance is genuinely
  /// first-time again. Do that before recording if the relink sheet isn't
  /// convincing enough.
  ///
  /// Best-effort throughout: a step that throws must not strand the rest, or
  /// the reset is only usable on a device that didn't need it.
  Future<List<String>> resetForRecording() async {
    final failures = <String>[];
    Future<void> step(String label, Future<void> Function() run) async {
      try {
        await run();
      } on Object catch (e) {
        failures.add('$label: $e');
      }
    }

    await step('awareness marker', TapToPayAwarenessSheet.clearShown);
    await step('deauthorize', SquarePaymentService.instance.deauthorize);
    reset();
    return failures;
  }

  /// Drops the reader subscription and forgets the warm-up. Called on sign-out,
  /// where the Square authorization is released anyway.
  void reset() {
    _readerCallback?.clear();
    _readerCallback = null;
    _endpointAvailable = true;
    eligibility.value = null;
    status.value = TapToPayReaderStatus.unknown;
    _lastUnavailableReason = null;
  }
}
