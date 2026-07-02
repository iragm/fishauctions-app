/// A club the signed-in user belongs to, as shown in the drawer's "Clubs"
/// menu. Parsed from `GET /api/mobile/clubs/mine/`, which mirrors the web
/// navbar's Clubs dropdown (the `user_clubs` context processor).
class ClubMenuItem {
  const ClubMenuItem({
    required this.name,
    required this.slug,
    required this.url,
    required this.iconUrl,
    required this.isAdmin,
  });

  factory ClubMenuItem.fromJson(Map<String, dynamic> json) => ClubMenuItem(
    name: json['name'] as String? ?? '',
    slug: json['slug'] as String? ?? '',
    url: json['url'] as String? ?? '',
    iconUrl: json['icon_url'] as String?,
    isAdmin: json['is_admin'] as bool? ?? false,
  );

  final String name;
  final String slug;

  /// Site-relative path to the club page (e.g. `/clubs/<slug>/`); the drawer
  /// loads it through the WebView via `EnvironmentConfig.webBaseUrl`.
  final String url;

  /// Absolute URL of the club's square icon, or null when it has none.
  final String? iconUrl;

  /// Whether the user is an admin of this club (has `permission_admin`).
  final bool isAdmin;
}
