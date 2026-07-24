/// The user's last-used auction, from `GET /api/mobile/auctions/last-used/`
/// (BACKEND_SPEC.md "AR Command Palette Entry — Last-Used-Auction Lookup").
///
/// All fields are null together when the user has no last-used auction, or it
/// points at a deleted one — the server always returns `200` for that empty
/// state; a `404` means this backend build predates the endpoint entirely
/// (handled by the fetching service, not this class).
class LastUsedAuction {
  const LastUsedAuction({
    required this.slug,
    required this.title,
    required this.isOnline,
    required this.prettyMuchOver,
    required this.latitude,
    required this.longitude,
  });

  factory LastUsedAuction.fromJson(Map<String, dynamic> json) =>
      LastUsedAuction(
        slug: json['slug'] as String?,
        title: json['title'] as String?,
        isOnline: json['is_online'] as bool?,
        prettyMuchOver: json['pretty_much_over'] as bool?,
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
      );

  final String? slug;
  final String? title;
  final bool? isOnline;
  final bool? prettyMuchOver;

  /// The auction's single physical pickup location, when it has one with
  /// coordinates set. Null doesn't imply online — an in-person auction with an
  /// ambiguous or unset location also reports null here.
  final double? latitude;
  final double? longitude;

  /// Whether there's an actual last-used auction to act on.
  bool get hasAuction => slug != null && slug!.isNotEmpty;

  /// Worth offering an in-person, auction-specific shortcut for right now —
  /// has an auction, it's not online, and it hasn't wound down.
  bool get isActiveInPerson =>
      hasAuction && isOnline == false && prettyMuchOver == false;
}
