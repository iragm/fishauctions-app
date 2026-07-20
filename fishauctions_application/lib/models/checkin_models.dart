/// Data classes for proximity check-in (`/api/mobile/checkin/*`,
/// BACKEND_SPEC.md Part 6).
///
/// Parsed defensively like the AR models: the endpoints may not exist on a
/// deployment yet, and a newer backend may ship action types this app version
/// doesn't know — unknown types must be skippable, and every field tolerates
/// absence.
library;

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

  /// Skips unknown/malformed entries rather than failing the batch.
  static CheckinAction? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final type = switch (raw['type']) {
      'join_offer' => CheckinActionType.joinOffer,
      'checked_in' => CheckinActionType.checkedIn,
      'set_location_offer' => CheckinActionType.setLocationOffer,
      _ => null, // a newer backend's action type — ignore, don't break
    };
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

  /// Once-per-process dedupe key — the server also dedupes persistently, but
  /// a re-ping must never re-open a sheet the user already dismissed.
  String get key => '${type.name}:$auctionSlug';
}

/// Result of `POST checkin/join/`.
class CheckinJoinResult {
  const CheckinJoinResult({
    required this.joined,
    required this.checkedIn,
    this.rulesUrl,
  });

  factory CheckinJoinResult.fromJson(Map<String, dynamic> json) =>
      CheckinJoinResult(
        joined: json['joined'] == true,
        checkedIn: json['checked_in'] == true,
        rulesUrl: json['rules_url'] as String?,
      );

  final bool joined;

  /// True when the server also checked the user in (check-in-mode auctions —
  /// they are physically at the venue).
  final bool checkedIn;
  final String? rulesUrl;
}
