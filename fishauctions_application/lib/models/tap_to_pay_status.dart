import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

/// How ready the Tap to Pay reader is, normalized from Square's reader status.
///
/// Apple requires a configuration-progress indicator (requirement 3.9.1) and an
/// "initializing" screen when a cashier presses the button before the reader is
/// ready (5.7). Square's SDK exposes the underlying state through its reader
/// callback; this collapses it to the three things the UI actually renders, so
/// no screen has to reason about Square's platform-specific reason codes.
enum TapToPayReaderStatus {
  /// Nothing has reported yet — no authorization, or the SDK hasn't emitted a
  /// reader event. Renders as a neutral spinner, never as a failure: at app
  /// launch this is simply the normal starting state.
  unknown,

  /// Being configured (connecting to the device or to Square). This is the
  /// state the progress indicator exists for.
  preparing,

  /// Ready to take a tap.
  ready,

  /// Can't be used right now — the reason is deliberately not carried here,
  /// because the charge path produces far better diagnostics than a reader
  /// status code (NFC off, developer mode, location not activated, terms not
  /// accepted). The settings screen just says "not ready" and points at setup.
  unavailable;

  bool get isReady => this == TapToPayReaderStatus.ready;

  /// Whether to show a progress indicator. [unknown] counts: before the first
  /// event we genuinely don't know, and a spinner is the honest rendering.
  bool get isBusy =>
      this == TapToPayReaderStatus.preparing ||
      this == TapToPayReaderStatus.unknown;

  /// What to tell the user while the reader gets ready. Kept short — this sits
  /// under a progress bar, not in a paragraph.
  String get message => switch (this) {
    TapToPayReaderStatus.ready => 'Ready to take a payment',
    TapToPayReaderStatus.preparing => 'Getting Tap to Pay ready…',
    TapToPayReaderStatus.unknown => 'Checking Tap to Pay…',
    TapToPayReaderStatus.unavailable => 'Tap to Pay isn\'t ready',
  };

  static TapToPayReaderStatus fromSquare(
    ReaderStatusInfoStatus? status,
    ReaderStatusInfoUnavailableReason? reason,
  ) => switch (status) {
    ReaderStatusInfoStatus.ready => TapToPayReaderStatus.ready,
    // Both "connecting" states are the configuration progress Apple's 3.9.1
    // wants surfaced.
    ReaderStatusInfoStatus.connectingToDevice ||
    ReaderStatusInfoStatus.connectingToSquare => TapToPayReaderStatus.preparing,
    ReaderStatusInfoStatus.readerUnavailable ||
    ReaderStatusInfoStatus.faulty => TapToPayReaderStatus.unavailable,
    null => TapToPayReaderStatus.unknown,
  };
}

/// Why this device can't do Tap to Pay, when it can't.
///
/// Exists for Apple's requirement 1.4: below the Tap to Pay iOS floor the app
/// must tell the user to **update iOS**, which is a different message (and a
/// different outcome for the user) than an iPhone that will never support it.
enum TapToPayUnsupportedReason {
  /// Supported — Tap to Pay can run here.
  none,

  /// The hardware can't: below iPhone XS on iOS, or no NFC / pre-API-31 on
  /// Android. Nothing the user can do but use another device.
  device,

  /// The hardware can, but the OS is too old. Fixable by updating.
  osVersion;

  bool get isSupported => this == TapToPayUnsupportedReason.none;
}

/// This operator's Tap to Pay standing, from `GET /api/mobile/payments/
/// authorization/` (BACKEND_SPEC.md Part TTP).
///
/// Two jobs, both driven by Apple's checklist:
///
/// - **Who may accept the terms.** Requirement 3.8 restricts acceptance to an
///   administrator or otherwise authorized party, and 3.8.1 says everyone else
///   must be told to contact an admin. Only the backend knows whether this user
///   administers an auction with a linked Square account, so it decides and the
///   app renders.
/// - **Warming the reader.** Requirement 1.5 wants Tap to Pay prepared at
///   launch/foreground, which means authorizing the SDK before any invoice
///   exists — so the same response carries the seller credentials that
///   `/payments/create/` returns per invoice.
class TapToPayEligibility {
  const TapToPayEligibility({
    required this.eligible,
    required this.canAcceptTerms,
    this.accessToken,
    this.locationId,
    this.sellerName,
    this.message,
  });

  factory TapToPayEligibility.fromJson(Map<String, dynamic> json) =>
      TapToPayEligibility(
        eligible: json['eligible'] == true,
        canAcceptTerms: json['can_accept_terms'] == true,
        accessToken: _nonEmpty(json['access_token']),
        locationId: _nonEmpty(json['location_id']),
        sellerName: _nonEmpty(json['seller_name']),
        message: _nonEmpty(json['message']),
      );

  /// Whether this user can take Tap to Pay payments at all — an admin of at
  /// least one auction/club whose Square account is linked.
  final bool eligible;

  /// Whether this user is the party allowed to accept Apple's terms
  /// (requirement 3.8). Usually equal to [eligible], but a deployment can
  /// separate them — e.g. a volunteer cashier who may charge on a device an
  /// owner already set up, but may not accept terms themselves.
  final bool canAcceptTerms;

  /// Per-seller Square credentials for pre-authorization, present only when the
  /// backend is willing to issue them. Absent → no warm-up, and the charge path
  /// authorizes per invoice exactly as before.
  final String? accessToken;
  final String? locationId;

  /// The Square seller/club this operator would charge as, shown on the
  /// settings screen so a multi-club admin knows which account is active.
  final String? sellerName;

  /// Server-authored explanation for an ineligible user — rendered verbatim,
  /// like the check-in nudges, so the reason (Square not linked, account
  /// disabled, not an admin) can change without an app release. Null → the app
  /// falls back to its own generic copy.
  final String? message;

  /// Whether there are credentials to warm the reader with.
  bool get canCharge =>
      eligible &&
      (accessToken?.isNotEmpty ?? false) &&
      (locationId?.isNotEmpty ?? false);

  static String? _nonEmpty(Object? v) {
    final s = v?.toString() ?? '';
    return s.isEmpty ? null : s;
  }
}
