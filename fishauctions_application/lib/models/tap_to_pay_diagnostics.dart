/// A point-in-time snapshot of everything that decides whether a tap can
/// happen, in one block a cashier can read off the screen or copy into a bug
/// report.
///
/// **Why this exists.** When Square won't arm the reader it shows a native
/// "connect hardware to take card payments" screen: no payment error, no
/// code, no text, and identical whether the cause is NFC, the merchant
/// account, Apple's terms, developer mode, or a failed app attestation. Every
/// hypothesis therefore used to cost a full build-sign-sideload cycle, which
/// is how one bug ate several sessions. The SDK does expose *one*
/// machine-readable account of the failure — the Tap to Pay reader's
/// `unavailableReason` — and the app used to discard it. This carries it, plus
/// the surrounding state that decides how to read it, to a screen.
///
/// Deliberately primitives-only: no Square SDK types cross this boundary, so
/// the mapping below is unit-testable without a device or a plugin.
library;

/// One reader the SDK knows about. Tap to Pay's is a software reader — its
/// absence from the list is itself a finding, and is reported as such.
class TapToPayReaderLine {
  const TapToPayReaderLine({
    required this.model,
    required this.status,
    this.id,
    this.name,
    this.unavailableReason,
  });

  final String model;
  final String status;
  final String? id;
  final String? name;
  final String? unavailableReason;

  bool get isTapToPay => model == 'tapToPay';

  @override
  String toString() {
    final parts = <String>[
      model,
      status,
      if (unavailableReason != null) 'reason=$unavailableReason',
      if (name != null && name!.isNotEmpty) 'name=$name',
      if (id != null && id!.isNotEmpty) 'id=$id',
    ];
    return parts.join(' · ');
  }
}

class TapToPayDiagnostics {
  const TapToPayDiagnostics({
    required this.capturedAt,
    required this.platform,
    required this.osVersion,
    required this.readers,
    required this.errors,
    this.applicationId,
    this.environment,
    this.deviceCapable,
    this.appleAccountLinked,
    this.authorized,
    this.locationId,
    this.locationName,
    this.merchantId,
    this.cardProcessingActivated,
    this.eligible,
    this.canCharge,
    this.sellerName,
    this.eligibilityMessage,
    this.readerStatus,
    this.lastUnavailableReason,
  });

  final DateTime capturedAt;
  final String platform;
  final String osVersion;

  /// Every reader `getReaders()` returned. Empty is meaningful: it means the
  /// SDK has no Tap to Pay reader at all, which is a different failure from
  /// having one that reports a reason.
  final List<TapToPayReaderLine> readers;

  /// Anything that threw while collecting this, so a probe that half-failed
  /// still produces a report rather than nothing.
  final List<String> errors;

  final String? applicationId;
  final String? environment;
  final bool? deviceCapable;
  final bool? appleAccountLinked;
  final bool? authorized;
  final String? locationId;
  final String? locationName;
  final String? merchantId;
  final bool? cardProcessingActivated;
  final bool? eligible;
  final bool? canCharge;
  final String? sellerName;
  final String? eligibilityMessage;

  /// The app's own normalized reader status at capture time.
  final String? readerStatus;

  /// The last `unavailableReason` the reader callback reported, which may be
  /// set even when [readers] is empty — the callback fires on state changes
  /// the list no longer reflects.
  final String? lastUnavailableReason;

  /// The Tap to Pay reader, if the SDK has one.
  TapToPayReaderLine? get tapToPayReader {
    for (final r in readers) {
      if (r.isTapToPay) {
        return r;
      }
    }
    return null;
  }

  /// The reason to act on: the live reader's, else the last one the callback
  /// reported. Null when nothing is complaining.
  String? get effectiveReason =>
      tapToPayReader?.unavailableReason ?? lastUnavailableReason;

  /// One sentence naming what's wrong, or null when the reader looks fine.
  ///
  /// Order matters: an absent reader outranks a stale reason, because "Square
  /// never created a Tap to Pay reader" and "the reader it created says X" are
  /// different problems and only the first explains an empty list.
  String? get headline {
    final reason = effectiveReason;
    if (reason != null) {
      return describeUnavailableReason(reason);
    }
    if (readers.isEmpty) {
      return 'Square has not created a Tap to Pay reader on this device. That '
          'usually means the SDK is not authorized yet, or Square declined to '
          'arm it without saying why.';
    }
    if (tapToPayReader == null) {
      return 'Square knows about a reader, but not a Tap to Pay one.';
    }
    return null;
  }

  /// The copyable block. Every field is printed even when null — an absent
  /// value is evidence, and a report that silently omits it reads as though
  /// the question was never asked.
  String toReport() {
    String v(Object? x) => x == null ? '—' : x.toString();
    final lines = <String>[
      'Tap to Pay diagnostics',
      'captured: ${capturedAt.toIso8601String()}',
      'platform: $platform $osVersion',
      '',
      'square app id: ${v(applicationId)}',
      'environment: ${v(environment)}',
      'authorized: ${v(authorized)}',
      'location: ${v(locationId)} (${v(locationName)})',
      'merchant: ${v(merchantId)}',
      'card processing activated: ${v(cardProcessingActivated)}',
      '',
      'device capable: ${v(deviceCapable)}',
      'apple account linked: ${v(appleAccountLinked)}',
      '',
      'backend eligible: ${v(eligible)}',
      'backend can charge: ${v(canCharge)}',
      'seller: ${v(sellerName)}',
      if (eligibilityMessage != null) 'backend message: $eligibilityMessage',
      '',
      'reader status (app): ${v(readerStatus)}',
      'last unavailable reason: ${v(lastUnavailableReason)}',
      'readers (${readers.length}):',
      if (readers.isEmpty) '  (none)' else ...readers.map((r) => '  $r'),
    ];
    if (errors.isNotEmpty) {
      lines
        ..add('')
        ..add('errors while collecting:')
        ..addAll(errors.map((e) => '  $e'));
    }
    return lines.join('\n');
  }
}

/// Turns Square's `ReaderStatusInfoUnavailableReason` name into a sentence.
///
/// The raw name is always kept by the caller — this is the explanation, not a
/// replacement for the evidence. An unrecognized name still produces a usable
/// sentence rather than an empty one, because the enum gains cases faster than
/// this app ships.
String describeUnavailableReason(String reason) => switch (reason) {
  // ── iOS ───────────────────────────────────────────────────────────────
  'tapToPayIsNotLinked' =>
    'This iPhone is not linked to an Apple Account for Tap to Pay. Finish '
        'setup on the Tap to Pay screen, then try again.',
  'tapToPayError' =>
    "Apple's Tap to Pay reader reported an error on this iPhone.",
  'notConnectedToInternet' =>
    'No internet connection. Tap to Pay needs one to arm the reader.',
  'secureConnectionToSquareFailure' =>
    'Could not establish a secure connection to Square. This is the failure '
        'Square reports when it will not vouch for the app — a rejected app '
        'attestation or an unregistered application signature lands here.',
  'secureConnectionNetworkFailure' =>
    'The network dropped while connecting to Square.',
  'revokedByDevice' => 'The device revoked the reader session.',
  'readerTimeout' => 'The reader timed out while getting ready.',
  'maxReadersConnected' => 'Too many readers are connected.',
  'blockingUpdate' => 'A required update is installing.',
  'internalError' =>
    'Square reported an internal error. On iOS this is also what a failed '
        'App Attest attestation surfaces as — check the device log for '
        'DCAppAttest / devicecheckd errors around the same moment.',
  'bluetoothDisabled' => 'Bluetooth is off.',
  'bluetoothFailure' => 'Bluetooth failed.',
  // ── Android ───────────────────────────────────────────────────────────
  'merchantNotActivated' =>
    "This Square account has not finished Square's card-processing "
        'activation.',
  'merchantIneligible' =>
    'This Square account is not eligible to take Tap to Pay payments.',
  'merchantSuspended' => 'This Square account is suspended.',
  'deviceNotSupported' => 'This device cannot take Tap to Pay payments.',
  'deviceDeveloperMode' =>
    "Developer options are on, which Square's contactless kernel treats as a "
        'device-integrity failure. Turn them off and try again.',
  'deviceRooted' => 'This device appears to be rooted.',
  'hostIdMismatch' =>
    "Square did not recognize this app's registered signature for this "
        'device.',
  'disabled' => 'The reader is disabled.',
  'readerUpdateFailed' => 'A reader update failed.',
  'readerFirmwareUpdateRequired' => 'The reader needs a firmware update.',
  'readerNotSupported' => 'This reader is not supported.',
  'offlineSessionExpired' => 'The offline session expired.',
  'readerUnavailableOffline' => 'The reader is unavailable while offline.',
  'offlineModeDisabled' => 'Offline mode is disabled.',
  _ => 'Square reported "$reason".',
};
