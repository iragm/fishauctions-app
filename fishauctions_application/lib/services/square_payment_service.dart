import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';
// The plugin's own deep Map<Object?,Object?> → Map<String,Object?> cast, which
// `Payment.fromJson` needs for its nested Money/CardPaymentDetails maps. Not
// re-exported from the package root, but this is a public path (not `src/`),
// and copying a recursive cast to avoid one import would be the worse trade.
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk_method_channel.dart'
    show castToMap;

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

  /// Whether [PlatformBridge.initializeSquare] has run successfully.
  ///
  /// Every getter below that reaches the Square plugin checks this first,
  /// because on Android an SDK call made before `initialize()` crashes the
  /// process outright and cannot be caught from Dart — the full mechanism is
  /// documented on [PlatformBridge.squareInitialized]. Treat "not initialized"
  /// as "no authorization, no readers, nothing to release", which is exactly
  /// true: an uninitialized SDK holds none of those things.
  ///
  /// The one caller that must *not* guard is [ensureAuthorized], which
  /// initializes first and then proceeds.
  bool get isInitialized => PlatformBridge.squareInitialized;

  /// True when the SDK already holds a valid authorization for a location.
  /// False on a deployment with no Square application id, where the SDK was
  /// never initialized.
  Future<bool> get isAuthorized async =>
      isInitialized &&
      await _sdk.authManager.getAuthorizationState() ==
          AuthorizationState.authorized;

  /// Whether this physical device can take a Tap to Pay payment at all
  /// (Android: NFC + API 31+); otherwise a charge fails as unsupported.
  ///
  /// On Android the answer comes from the platform, not the SDK: the Square
  /// Flutter plugin's `tapToPaySettings.isDeviceCapable()` is iOS-only and
  /// throws `MissingPluginException` on Android. iOS asks the SDK (which
  /// checks the iPhone XS+ / iOS 16.4+ Tap to Pay floor).
  Future<bool> isDeviceCapable() async {
    if (Platform.isAndroid) {
      return PlatformBridge.isTapToPayCapable();
    }
    return isInitialized && await _sdk.tapToPaySettings.isDeviceCapable();
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
      (await authorizedLocation())?.cardProcessingActivated;

  /// The Square location the SDK is currently authorized for, or null when it
  /// holds no authorization.
  Future<Location?> authorizedLocation() async =>
      isInitialized ? await _sdk.authManager.getAuthorizedLocation() : null;

  /// Every reader the SDK currently knows about, the Tap to Pay one included.
  ///
  /// Tap to Pay's "reader" is a software one: it exists once the SDK is
  /// authorized and Square is willing to arm it, and its
  /// `statusInfo.unavailableReason` is the **only** machine-readable account
  /// Square gives of why a tap can't happen. The native "connect hardware to
  /// take card payments" screen carries none of it, throws no
  /// [PaymentError], and looks identical whether the cause is NFC, the
  /// merchant account, Apple's terms or a failed app attestation — so this is
  /// what the checkout pre-flight and the diagnostics screen read instead of
  /// guessing.
  Future<List<ReaderInfo>> readers() async =>
      isInitialized ? await _sdk.readerManager.getReaders() : const [];

  /// iOS only: Tap to Pay on iPhone requires the device to be linked to an
  /// Apple account once (an interactive Apple sheet, Square terms included).
  /// No-op on Android and when already linked. A throw here means the link
  /// was declined/failed — the charge can't proceed.
  ///
  /// Returns true only when this call is what performed the link — i.e. the
  /// merchant accepted Apple's terms just now. Callers need that to honour
  /// requirement 4.2, which puts merchant education immediately *after* an
  /// acceptance and nowhere else; "already linked" must not re-educate someone
  /// on every charge.
  Future<bool> ensureAppleAccountLinked() async {
    if (!Platform.isIOS) {
      return false;
    }
    if (await isAppleAccountLinked()) {
      return false;
    }
    await _sdk.tapToPaySettings.linkAppleAccount();
    return true;
  }

  /// Re-runs Apple's Tap to Pay account sheet on a device that is *already*
  /// linked. iOS-only.
  ///
  /// The SDK offers no unlink, so this is the only way to see the linking step
  /// again — which is what re-recording Apple's onboarding video needs.
  ///
  /// Returns null when the sheet ran (or the merchant dismissed it, which is
  /// the ordinary way out of it) and the SDK's own error name otherwise —
  /// `notAuthorized`, `linkingFailed`, `noNetwork`… A sheet that never
  /// appears looks exactly like one that was dismissed, so the caller has no
  /// other way to tell the difference, and the difference is the whole story
  /// when the reset button appears to do nothing. In particular
  /// **`notAuthorized` means the SDK holds no Square authorization**: Square's
  /// own message is "This device must be authorized with a Square account in
  /// order to use Tap To Pay", so anything that releases the authorization has
  /// to happen *after* this, not before.
  Future<String?> relinkAppleAccount() async {
    if (!Platform.isIOS) {
      return null;
    }
    try {
      await _sdk.tapToPaySettings.relinkAppleAccount();
      return null;
    } on TapToPayError catch (e) {
      return e.code == TapToPayErrorCode.linkingCanceled ? null : e.code.name;
    } on Object catch (e) {
      _log.e('Apple account relink failed: $e');
      return e.toString();
    }
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
    if (!Platform.isIOS || !isInitialized) {
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
  ReaderCallbackReference? onReaderChanged(
    void Function(ReaderChangedEvent event) callback,
  ) => isInitialized
      ? _sdk.readerManager.setReaderChangedCallback(callback)
      : null;

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
    final parameters = PaymentParameters(
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
    );
    final payment = Platform.isIOS
        ? await _startPaymentIOS(parameters)
        : await _sdk.paymentManager.startPayment(
            parameters,
            // Android's `PaymentMapper.getPromptParameters` builds
            // `PromptParameters(mode = DEFAULT)` and never reads the list, so
            // this records intent (Tap to Pay only) and changes nothing. Do
            // not read it as a guarantee that keyed/cash entry is hidden.
            const PromptParameters(
              additionalPaymentMethods: [],
              mode: PromptMode.defaultMode,
            ),
          );
    return SquareChargeResult(paymentId: payment.id);
  }

  /// `startPayment` on iOS, going around the plugin's typed API to put
  /// `tapToPay` in the prompt's method set.
  ///
  /// **This is what made every iOS charge dead-end on Square's "Connect
  /// hardware to take card payments" screen** with a reader reporting `ready`
  /// (measured on an iPhone 12 / iOS 26.6.1, 2026-09-02).
  ///
  /// On iOS, Tap to Pay is not the prompt's implicit primary method — it is a
  /// member of `AdditionalPaymentMethods`, alongside `.keyed` and `.cash`
  /// (confirmed in the shipped SquareMobilePaymentsSDK 2.6.0 binary, which
  /// exports `AdditionalPaymentMethods.tapToPay`). Plugin 2026.8.1's iOS
  /// mapper stopped falling back to `.all` — *"An empty (or missing) list must
  /// result in no additional methods being shown, so we intentionally avoid
  /// falling back to `.all`"* — so the empty list this app passed produced a
  /// prompt with **no payment methods at all**, whose empty state is that
  /// screen. Android is unaffected: its mapper ignores the list entirely,
  /// which is exactly why Android has worked throughout.
  ///
  /// The plugin's Dart `AdditionalPaymentMethodType` enum has only `keyed` and
  /// `cash`, so the typed API cannot express `tapToPay` — but its iOS mapper
  /// accepts the string. Hence the direct channel call: same channel, same
  /// method, same payload the plugin builds, with one value it can't spell.
  /// Revisit when the plugin's enum gains `tapToPay`.
  Future<Payment> _startPaymentIOS(PaymentParameters parameters) async {
    final payload = <String, dynamic>{
      'paymentParameters': {
        ...parameters.toJson(),
        // The plugin re-encodes Money by hand because `toJson` emits the
        // currency as an enum name the native mapper doesn't read; mirrored
        // here so the two payloads stay identical.
        'amountMoney': {
          'amount': parameters.amountMoney.amount,
          'currencyCode': parameters.amountMoney.currencyCode.name,
        },
        'appFeeMoney': null,
        'tipMoney': null,
      },
      'promptParameters': {
        'additionalPaymentMethods': ['tapToPay'],
        'mode': 'defaultMode',
      },
    };
    try {
      final response = await _channel.invokeMethod<Map<Object?, Object?>>(
        'startPayment',
        payload,
      );
      if (response == null) {
        throw PaymentError('unexpected', 'startPayment() returned null');
      }
      return Payment.fromJson(castToMap(response));
    } on PlatformException catch (e) {
      // Re-wrapped so callers keep catching PaymentError and reading
      // `code == PaymentErrorCode.canceled`, exactly as on Android.
      throw PaymentError(e.code, e.message, e.details);
    }
  }

  /// The plugin's own channel. Only [_startPaymentIOS] uses it.
  static const _channel = MethodChannel('square_mobile_payments_sdk');

  /// Releases the current authorization (e.g. on logout).
  /// Releases the SDK's authorization. A no-op before initialization — which
  /// is what sign-out on a Square-less deployment does, and used to be a
  /// process-killing SDK call on Android.
  Future<void> deauthorize() async {
    if (!isInitialized) {
      return;
    }
    await _sdk.authManager.deauthorize();
  }

  /// The environment the SDK was initialized on. Real Tap to Pay (NFC, no
  /// hardware) only works in [Environment.production] — Square's Sandbox
  /// environment has no way to simulate a PCI-certified NFC card read, so
  /// [charge] in sandbox always surfaces the native "connect a reader"
  /// prompt unless the Mock Reader UI ([showMockReaderUI]) is showing to
  /// simulate the tap instead. See the SDK's own docs on `showMockReaderUI`.
  /// Null before the SDK is initialized — see [isInitialized]; on Android
  /// asking anyway would end the process rather than throw.
  Future<Environment?> environment() async =>
      isInitialized ? await _sdk.settingsManager.getEnvironment() : null;

  /// Shows Square's floating Mock Reader overlay (Sandbox only), which lets a
  /// tester simulate a card presentment since Sandbox can't read a real NFC
  /// tap. No-op-ish on failure (e.g. not in sandbox, or already showing) —
  /// callers should treat a throw here as non-fatal and proceed to [charge]
  /// anyway, since the native prompt still explains what's missing.
  Future<void> showMockReaderUI() async {
    if (isInitialized) {
      await _sdk.readerManager.showMockReaderUI();
    }
  }

  /// Dismisses the Mock Reader overlay shown by [showMockReaderUI].
  Future<void> hideMockReaderUI() async {
    if (isInitialized) {
      await _sdk.readerManager.hideMockReaderUI();
    }
  }

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
