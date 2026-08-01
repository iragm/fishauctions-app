import 'dart:async';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

import '../models/tap_to_pay_status.dart';
import '../utils/platform_bridge.dart';
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
      _listenToReader();
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
  void _listenToReader() {
    if (_readerCallback != null) {
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
        status.value = TapToPayReaderStatus.fromSquare(
          reader.statusInfo.status,
          reader.statusInfo.unavailableReason,
        );
      });
    } on Object catch (e) {
      // No reader stream (SDK not initialized, plugin gap) — the indicator just
      // stays "unknown", which the UI renders as a neutral spinner.
      debugPrint('Tap to Pay reader status unavailable: $e');
    }
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
  Future<bool> presentEducation() async =>
      await PlatformBridge.presentTapToPayEducation() == 'presented';

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

  /// Drops the reader subscription and forgets the warm-up. Called on sign-out,
  /// where the Square authorization is released anyway.
  void reset() {
    _readerCallback?.clear();
    _readerCallback = null;
    _endpointAvailable = true;
    eligibility.value = null;
    status.value = TapToPayReaderStatus.unknown;
  }
}
