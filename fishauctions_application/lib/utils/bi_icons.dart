import 'package:flutter/material.dart';

/// Maps a Bootstrap Icons class name (`bi-*`) to the closest Material icon.
///
/// The website names its icons in Bootstrap Icons, and both server-driven
/// surfaces in this app carry those names through verbatim: the command
/// palette's result rows and the navigation drawer's menu payload. Neither one
/// gets to invent an icon vocabulary of its own, so the mapping lives here
/// rather than beside either consumer.
///
/// **The map and [biIconFallback] must stay `const`, and every value must be a
/// literal `Icons.` constant.** Flutter's release builds tree-shake the icon
/// font down to the glyphs it can prove are referenced, and it can only prove
/// that for constant [IconData]. An `IconData(codePoint)` built from a runtime
/// string — the obvious way to "support every `bi-*` name" — either fails the
/// build (`--tree-shake-icons` refuses non-constant instantiation) or renders
/// tofu. An unknown name therefore falls back; it never becomes a codepoint.
IconData biIcon(String bi) => _biIcons[bi] ?? biIconFallback;

/// Shown for a `bi-*` name this build has no mapping for. A neutral chevron:
/// a menu row with the wrong picture on it is worse than one with a plain
/// "goes somewhere" marker, and the server is free to name icons this app
/// has never heard of.
const IconData biIconFallback = Icons.arrow_forward_ios;

const Map<String, IconData> _biIcons = <String, IconData>{
  'bi-grid': Icons.grid_view,
  'bi-hammer': Icons.gavel,
  'bi-tag': Icons.sell,
  'bi-tags': Icons.local_offer,
  'bi-people': Icons.group_outlined,
  'bi-people-fill': Icons.group,
  'bi-person': Icons.person_outline,
  'bi-person-badge': Icons.badge_outlined,
  'bi-person-vcard': Icons.contact_page_outlined,
  'bi-person-fill-lock': Icons.lock_person,
  'bi-person-fill': Icons.person,
  'bi-person-plus': Icons.person_add_outlined,
  'bi-bag': Icons.shopping_bag_outlined,
  'bi-bag-heart': Icons.favorite_border,
  'bi-bag-check': Icons.check_circle_outline,
  'bi-bag-heart-fill': Icons.favorite,
  'bi-printer': Icons.print,
  'bi-gear': Icons.settings_outlined,
  'bi-clock-history': Icons.history,
  'bi-calendar': Icons.calendar_today_outlined,
  'bi-calendar-event': Icons.event_outlined,
  'bi-calendar-check': Icons.event_available_outlined,
  'bi-arrow-right-short': Icons.arrow_forward,
  'bi-plus-circle': Icons.add_circle_outline,
  'bi-card-list': Icons.list_alt_outlined,
  'bi-award': Icons.emoji_events_outlined,
  'bi-map': Icons.map_outlined,
  'bi-envelope': Icons.mail_outline,
  'bi-envelope-at': Icons.alternate_email,
  'bi-discord': Icons.chat_bubble_outline,
  'bi-credit-card': Icons.credit_card_outlined,
  'bi-key': Icons.key_outlined,
  'bi-paypal': Icons.payment,
  'bi-sliders': Icons.tune,
  'bi-house': Icons.home_outlined,
  'bi-qr-code-scan': Icons.qr_code_scanner,
  'bi-input-cursor-text': Icons.text_fields,
  'bi-telephone-fill': Icons.phone,
  'bi-google': Icons.language,
  'bi-star': Icons.star_outline,
  'bi-star-fill': Icons.star,
  'bi-heart': Icons.favorite_border,
  // Added for the navigation drawer: everything base.html's navbar and its
  // account/admin/about dropdowns name today.
  'bi-cash-coin': Icons.sell,
  'bi-coin': Icons.monetization_on,
  'bi-info-circle': Icons.info_outline,
  'bi-chat': Icons.chat_bubble_outline,
  'bi-chat-heart': Icons.feedback_outlined,
  'bi-ban': Icons.block,
  'bi-box-arrow-right': Icons.logout,
  'bi-box-arrow-in-right': Icons.login,
  'bi-speedometer2': Icons.speed,
  'bi-shield-lock': Icons.admin_panel_settings_outlined,
  'bi-graph-up': Icons.show_chart,
  'bi-graph-up-arrow': Icons.trending_up,
  'bi-bar-chart': Icons.bar_chart,
  'bi-list-check': Icons.checklist,
  'bi-list': Icons.list,
  'bi-question-circle': Icons.help_outline,
  'bi-file-text': Icons.description_outlined,
  'bi-file-earmark-text': Icons.description_outlined,
  'bi-globe': Icons.public,
  'bi-bug': Icons.bug_report_outlined,
  'bi-search': Icons.search,
  'bi-shop': Icons.storefront_outlined,
  'bi-cloud-slash': Icons.cloud_off,
  'bi-diagram-3': Icons.account_tree_outlined,
  'bi-pin-map': Icons.place_outlined,
  'bi-trophy': Icons.emoji_events,
  'bi-wrench': Icons.build_outlined,
  'bi-link-45deg': Icons.link,
  'bi-three-dots': Icons.more_horiz,
  // The five the superuser Admin section names that nothing else did. An
  // unmapped name is only a chevron, not a break — but every row in a
  // twelve-item collapsed menu looking identical defeats the point of icons.
  'bi-check2-square': Icons.check_box_outlined,
  'bi-exclamation-triangle': Icons.warning_amber_outlined,
  'bi-geo-alt': Icons.location_on_outlined,
  'bi-signpost-split': Icons.alt_route,
  'bi-stars': Icons.auto_awesome_outlined,
};
