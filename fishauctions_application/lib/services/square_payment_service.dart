import 'dart:io' show Platform;

import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

import '../utils/platform_bridge.dart';

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
  ///
  /// On Android the answer comes from the platform, not the SDK: the Square
  /// Flutter plugin's `tapToPaySettings.isDeviceCapable()` is iOS-only and
  /// throws `MissingPluginException` on Android. iOS asks the SDK (which
  /// checks the iPhone XS+ / iOS 16.4+ Tap to Pay floor).
  Future<bool> isDeviceCapable() {
    if (Platform.isAndroid) {
      return PlatformBridge.isTapToPayCapable();
    }
    return _sdk.tapToPaySettings.isDeviceCapable();
  }

  /// Whether NFC is currently turned on. Distinct from [isDeviceCapable],
  /// which only checks the device *has* NFC hardware — a device can be
  /// capable with NFC toggled off in system settings, which Square's SDK
  /// surfaces as an opaque "connect hardware to take card payments" prompt
  /// with no card-tap option and no catchable [PaymentError] (from Square's
  /// side there's simply no reader present). Android-only; always true on
  /// iOS (Tap to Pay there has no separate user-facing NFC toggle).
  Future<bool> isNfcEnabled() => PlatformBridge.isNfcEnabled();

  /// Opens the system NFC settings screen so the user can turn NFC on.
  /// Android only; no-op on iOS.
  Future<void> openNfcSettings() => PlatformBridge.openNfcSettings();

  /// Whether Android's Developer options are switched on, which blocks a Tap
  /// to Pay card read: Square's contactless kernel treats developer mode as a
  /// device-integrity failure (same family as its root detection) and the
  /// charge dead-ends in the opaque "connect hardware to take card payments"
  /// prompt with no catchable [PaymentError] — indistinguishable, from the
  /// app's side, from NFC being off. The app can't turn it off for the user,
  /// so this drives a non-blocking warning in the payment sheet rather than a
  /// gate: a device that has it on today may still be mid-approval, and
  /// blocking on a heuristic would be worse than a charge that fails loudly.
  /// Android-only; false on iOS.
  Future<bool> isDeveloperModeEnabled() =>
      PlatformBridge.isDeveloperModeEnabled();

  /// Whether the currently authorized Square location is activated for card
  /// processing, or null when unknown (no authorized location yet, or the
  /// SDK didn't report the flag). `false` explains a charge that never
  /// prompts for a tap: the account/location hasn't finished Square's
  /// card-processing activation, a prerequisite separate from having a
  /// production application id — `authorize()` may also throw
  /// `AuthorizationErrorCode.locationNotActivatedForCardProcessing` for the
  /// same underlying reason.
  Future<bool?> get cardProcessingActivated async =>
      (await _sdk.authManager.getAuthorizedLocation())?.cardProcessingActivated;

  /// iOS only: Tap to Pay on iPhone requires the device to be linked to an
  /// Apple account once (an interactive Apple sheet, Square terms included).
  /// No-op on Android and when already linked. A throw here means the link
  /// was declined/failed — the charge can't proceed.
  Future<void> ensureAppleAccountLinked() async {
    if (!Platform.isIOS) {
      return;
    }
    if (await isAppleAccountLinked()) {
      return;
    }
    await _sdk.tapToPaySettings.linkAppleAccount();
  }

  /// Whether this device is linked to an Apple account for Tap to Pay — i.e.
  /// whether the merchant has accepted Apple's Tap to Pay Terms and Conditions.
  ///
  /// Always asked of the SDK (and through it, Apple). Apple's app-review
  /// requirement 1.6 forbids holding this in a local variable: the merchant can
  /// unlink their Apple Account at any time from iOS Settings, and a stale
  /// `true` sends the app into a charge that can only fail. iOS-only; false on
  /// Android, which has no Apple-account step.
  Future<bool> isAppleAccountLinked() async {
    if (!Platform.isIOS) {
      return false;
    }
    return _sdk.tapToPaySettings.isAppleAccountLinked();
  }

  /// Subscribes to Square's reader-changed events, returning the handle that
  /// cancels the subscription.
  ///
  /// Drives the Tap to Pay configuration-progress indicator Apple requires
  /// (requirements 3.9.1 and 5.7) — the SDK reports the reader moving through
  /// connecting-to-device / connecting-to-Square / ready as it prepares, which
  /// is the PSP equivalent of `PaymentCardReader.Event.updateProgress`.
  ReaderCallbackReference onReaderChanged(
    void Function(ReaderChangedEvent event) callback,
  ) => _sdk.readerManager.setReaderChangedCallback(callback);

  /// Ensures the runtime location permission that Square Tap to Pay requires
  /// on both platforms. Without it, [charge] fails with
  /// [PaymentErrorCode.locationPermissionNeeded] (the native
  /// `payment_no_permission_location`) — location is a card-present fraud
  /// signal for the reader, unrelated to our distance-cookie use of location.
  ///
  /// The permission is declared in the manifest/Info.plist but must be granted
  /// at runtime. The only other place that prompts for it (`LocationService`)
  /// fires solely on the auctions/lots web pages, so a cashier who goes
  /// straight to checkout would never have granted it — hence we request it
  /// here before the tap.
  ///
  /// Returns whether it's granted. Prompts once if the user hasn't decided; a
  /// permanent denial returns false without a prompt (see
  /// [isLocationPermanentlyDenied]).
  Future<bool> ensureLocationPermission() async {
    final status = await Permission.locationWhenInUse.request();
    return status.isGranted;
  }

  /// True once location permission is permanently denied ("Don't ask again"):
  /// [ensureLocationPermission] can no longer prompt, so the only fix is the OS
  /// settings screen ([openSettings]).
  Future<bool> isLocationPermanentlyDenied() =>
      Permission.locationWhenInUse.isPermanentlyDenied;

  /// Opens this app's OS settings so the cashier can grant a permission they
  /// previously denied permanently.
  Future<void> openSettings() => openAppSettings();

  /// Authorizes the SDK for [locationId] using the per-invoice [accessToken].
  ///
  /// [applicationId] is the deployment's Square Application ID (from
  /// `/api/mobile/config/`, warmed at startup); the SDK is initialized with it
  /// first, since authorize() can't run on an uninitialized SDK. Init is
  /// once-per-process and idempotent (see [PlatformBridge.initializeSquare]),
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
    await PlatformBridge.initializeSquare(applicationId);
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
  /// [paymentAttemptId] must be **unique per attempt**. Square rejects a reused
  /// one outright with `payment_attempt_id_reused` — it does not de-duplicate,
  /// which is what the Payments API's server-side `idempotency_key` does, and
  /// conflating the two is what made every retry after a declined card fail
  /// inside Square's own UI. See `PaymentSheet._freshAttemptId`.
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
      // NOTE: `additionalPaymentMethods` is currently a no-op — the Flutter
      // plugin (2026.7.2) drops it on both platforms: Android's
      // `PaymentMapper.getPromptParameters` builds `PromptParameters(mode =
      // DEFAULT)` and never reads the list (whose Kotlin default is
      // `AdditionalPaymentMethod.Companion.allPaymentMethods`), and iOS
      // hardcodes `additionalMethods: .all`. So the prompt always offers the
      // full set of *extra* methods regardless of what's passed here. Keep
      // the empty list to record intent (Tap to Pay only), but don't read it
      // as a guarantee that keyed/cash entry is hidden.
      //
      // Contactless is NOT something to add to this list: its element type is
      // `AdditionalPaymentMethod.Type`, whose only values are KEYED and CASH.
      // Contactless (tap) is the prompt's *primary* method — the separate
      // `CardEntryMethod.CONTACTLESS` enum lives in the SDK's `cardreader`
      // package and is read-only output
      // (`ReaderInfo.supportedCardEntryMethods`,
      // `CardPaymentDetails.entryMethod`), never a prompt input. A missing tap
      // option means NFC off / location unactivated / no Tap to Pay access —
      // see the pre-flight checks in `payment_sheet.dart`.
      const PromptParameters(
        additionalPaymentMethods: [],
        mode: PromptMode.defaultMode,
      ),
    );
    return SquareChargeResult(paymentId: payment.id);
  }

  /// Releases the current authorization (e.g. on logout).
  Future<void> deauthorize() => _sdk.authManager.deauthorize();

  /// The environment the SDK was initialized on. Real Tap to Pay (NFC, no
  /// hardware) only works in [Environment.production] — Square's Sandbox
  /// environment has no way to simulate a PCI-certified NFC card read, so
  /// [charge] in sandbox always surfaces the native "connect a reader"
  /// prompt unless the Mock Reader UI ([showMockReaderUI]) is showing to
  /// simulate the tap instead. See the SDK's own docs on `showMockReaderUI`.
  Future<Environment> environment() => _sdk.settingsManager.getEnvironment();

  /// Shows Square's floating Mock Reader overlay (Sandbox only), which lets a
  /// tester simulate a card presentment since Sandbox can't read a real NFC
  /// tap. No-op-ish on failure (e.g. not in sandbox, or already showing) —
  /// callers should treat a throw here as non-fatal and proceed to [charge]
  /// anyway, since the native prompt still explains what's missing.
  Future<void> showMockReaderUI() => _sdk.readerManager.showMockReaderUI();

  /// Dismisses the Mock Reader overlay shown by [showMockReaderUI].
  Future<void> hideMockReaderUI() => _sdk.readerManager.hideMockReaderUI();

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
