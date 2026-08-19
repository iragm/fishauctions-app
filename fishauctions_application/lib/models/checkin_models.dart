/// Data classes for proximity check-in (`/api/mobile/checkin/*`,
/// BACKEND_SPEC.md Part 6).
///
/// Parsed defensively like the AR models: the endpoints may not exist on a
/// deployment yet, and a newer backend may ship action types this app version
/// doesn't know — unknown types must be skippable, and every field tolerates
/// absence.
library;

import 'dart:convert';

/// What kind of proximity nudge the server wants surfaced. The server owns
/// all the deciding (geofence, time window, join/check-in state, admin-ness)
/// and the wording; the app only picks the UI shape per type.
enum CheckinActionType {
  /// User is at the venue and hasn't joined: offer Join / Read rules.
  joinOffer,

  /// Server already checked the user in on this ping — confirm it.
  checkedIn,

  /// Admin at (roughly) the venue of an auction with no exact location:
  /// offer to pin the auction's location to this phone's position.
  setLocationOffer,
}

/// One server-issued nudge from `POST checkin/ping/`.
class CheckinAction {
  const CheckinAction({
    required this.type,
    required this.auctionSlug,
    required this.title,
    required this.message,
    this.rulesUrl,
  });

  final CheckinActionType type;
  final String auctionSlug;

  /// Auction display title.
  final String title;

  /// Server-composed user-facing text (product copy lives server-side).
  final String message;

  /// Site-relative rules-page path (join offers).
  final String? rulesUrl;

  /// The server's wire names for [CheckinActionType]. Kept as one map (rather
  /// than a switch in each direction) because the app now has to write this
  /// shape as well as read it: a nudge is round-tripped through a
  /// notification payload, so a name that parsed but didn't serialize would
  /// come back as an unknown type and be silently dropped on tap.
  static const Map<String, CheckinActionType> _types = {
    'join_offer': CheckinActionType.joinOffer,
    'checked_in': CheckinActionType.checkedIn,
    'set_location_offer': CheckinActionType.setLocationOffer,
  };

  /// Skips unknown/malformed entries rather than failing the batch.
  static CheckinAction? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    // A newer backend's action type reads as null — ignore it, don't break.
    final type = _types[raw['type']];
    final slug = raw['auction'];
    if (type == null || slug is! String || slug.isEmpty) {
      return null;
    }
    return CheckinAction(
      type: type,
      auctionSlug: slug,
      title: (raw['title'] as String?) ?? '',
      message: (raw['message'] as String?) ?? '',
      rulesUrl: raw['rules_url'] as String?,
    );
  }

  /// The server shape, so a nudge survives a round trip through a
  /// notification payload and comes back out of [tryParse] unchanged.
  Map<String, dynamic> toJson() => {
    'type': _types.entries.firstWhere((e) => e.value == type).key,
    'auction': auctionSlug,
    'title': title,
    'message': message,
    if (rulesUrl != null) 'rules_url': rulesUrl,
  };

  /// Everything the shell needs to act on a tap, carried by the notification
  /// itself rather than held in memory: the OS may deliver the tap after the
  /// process that posted it has been killed (Android does this routinely), and
  /// a nudge that can't be reconstructed is a notification that does nothing.
  String get notificationPayload => jsonEncode(toJson());

  /// Inverse of [notificationPayload]. Null for anything this build can't
  /// act on — junk, or an action type added after it shipped.
  static CheckinAction? fromNotificationPayload(String payload) {
    try {
      return tryParse(jsonDecode(payload));
    } on FormatException {
      return null;
    }
  }

  /// Stable per (type, auction) so a re-ping replaces its own notification
  /// instead of stacking a second copy. Masked positive because Android
  /// notification ids are Java ints and the plugin rejects the negative half.
  int get notificationId => key.hashCode & 0x7fffffff;

  /// Once-per-process dedupe key — the server also dedupes persistently, but
  /// a re-ping must never re-open a sheet the user already dismissed.
  String get key => '${type.name}:$auctionSlug';
}

/// Result of `POST checkin/join/`.
class CheckinJoinResult {
  const CheckinJoinResult({
    required this.joined,
    required this.checkedIn,
    this.bidderNumber,
    this.rulesUrl,
  });

  factory CheckinJoinResult.fromJson(Map<String, dynamic> json) {
    final bidder = json['bidder_number']?.toString().trim();
    return CheckinJoinResult(
      joined: json['joined'] == true,
      checkedIn: json['checked_in'] == true,
      bidderNumber: (bidder == null || bidder.isEmpty) ? null : bidder,
      rulesUrl: json['rules_url'] as String?,
    );
  }

  final bool joined;

  /// The bidder number check-in assigned, when the auction assigned one.
  ///
  /// This is the single fact the user needs off this whole flow — it is what
  /// they call out when they win a lot — and the app has nowhere else to get
  /// it: the rules page they land on doesn't render it, and neither does
  /// anything else a bidder who has just walked in can reach. Read as a string
  /// because `AuctionTOS.bidder_number` is a `CharField` and is routinely
  /// text (`BOB`, `NM-4`).
  final String? bidderNumber;

  /// True when the server also checked the user in (check-in-mode auctions —
  /// they are physically at the venue).
  final bool checkedIn;
  final String? rulesUrl;
}
