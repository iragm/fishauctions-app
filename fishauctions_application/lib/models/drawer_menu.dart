import '../utils/site_path.dart';

/// The navigation drawer's contents, as served by the `menu` block of
/// `GET /api/mobile/config/` (BACKEND_SPEC.md Part MENU).
///
/// The drawer used to be a hand-written mirror of the website's navbar. The
/// navbar changed fifteen times in a year, each change reached the app only
/// through an app-store release, and the copy was lossy besides: the site's
/// superuser "Admin" menu and its "About site" link never made it, because who
/// may see them is a question only the server can answer. So the menu is now
/// data, built server-side from the same structure that renders base.html.
///
/// Everything here is **web links only**. The rows the app owns — sign out,
/// offline mode, Tap to Pay, clubs — cannot be expressed as a URL, so the
/// server neither sends nor positions them; [DrawerMenu.withNativeRows] merges
/// them in at anchors the app chooses.
class DrawerMenu {
  const DrawerMenu({required this.sections});

  /// Parses a `menu` block, or returns null when there is nothing renderable
  /// in it.
  ///
  /// **Null is the whole error-handling story.** A malformed payload must
  /// never be able to empty the drawer, so every failure — wrong types, a
  /// missing `sections`, entries that all got dropped, an outright throw —
  /// comes back as null and the caller falls through to the next tier (the
  /// last-good payload on disk, then [bundledDrawerMenu]). A drawer showing
  /// slightly stale links is a non-event; a drawer showing nothing is a user
  /// with no way to navigate.
  static DrawerMenu? tryParse(Object? raw) {
    try {
      if (raw is! Map) {
        return null;
      }
      final rawSections = raw['sections'];
      if (rawSections is! List) {
        return null;
      }
      final sections = <DrawerMenuSection>[];
      for (final rawSection in rawSections) {
        final section = DrawerMenuSection.tryParse(rawSection);
        // A section whose items were all dropped is dropped with them: a
        // header with nothing under it reads as a broken app.
        if (section != null) {
          sections.add(section);
        }
      }
      if (sections.isEmpty) {
        return null;
      }
      return DrawerMenu(sections: sections);
    } on Object {
      return null;
    }
  }

  final List<DrawerMenuSection> sections;

  /// The sections to render, with the app's own rows merged in.
  ///
  /// Native rows attach to a section by **id** ([nativeAnchors]) and always
  /// land at the end of it, so the server decides what the menu contains and
  /// the app decides where its own controls sit. A row whose anchor section
  /// isn't in the payload is not lost — it goes into a trailing unnamed
  /// section — because the alternative is a phone that can't reach offline
  /// mode because someone renamed a section in Django.
  List<DrawerSectionView> withNativeRows() {
    final placed = <DrawerNativeRow>{};
    final views = <DrawerSectionView>[];
    for (final section in sections) {
      // A collapsed section is a dropdown, which is the wrong place for a row
      // that gates itself and rebuilds live — and hiding Sign out behind a tap
      // is not the server's call. Such a section is skipped as an anchor
      // entirely, so its rows fall through to the trailing section below
      // rather than vanishing.
      final natives = section.collapsed
          ? const <DrawerNativeRow>[]
          : nativeAnchors[section.id] ?? const <DrawerNativeRow>[];
      placed.addAll(natives);
      views.add(
        DrawerSectionView(
          title: section.title,
          icon: section.icon,
          collapsed: section.collapsed,
          entries: [
            for (final item in section.items) DrawerLinkEntry(item),
            for (final row in natives) DrawerNativeEntry(row),
          ],
        ),
      );
    }
    final orphans = [
      for (final rows in nativeAnchors.values)
        for (final row in rows)
          if (!placed.contains(row)) row,
    ];
    if (orphans.isNotEmpty) {
      views.add(
        DrawerSectionView(
          entries: [for (final row in orphans) DrawerNativeEntry(row)],
        ),
      );
    }
    // Sign out is never anchored: it is the last thing in the drawer in every
    // payload, the way it is in every version of the website's navbar.
    views.add(
      const DrawerSectionView(
        entries: [DrawerNativeEntry(DrawerNativeRow.signOut)],
      ),
    );
    return views;
  }

  /// Which app-owned rows attach to which server section id.
  ///
  /// Ids the payload doesn't use cost nothing (their rows fall through to the
  /// trailing section), and ids the app doesn't know about cost nothing either
  /// (they render as plain sections) — so the two sides can be changed
  /// independently, which is the point of the whole exercise.
  static const Map<String, List<DrawerNativeRow>> nativeAnchors = {
    'main': [DrawerNativeRow.offlineMode, DrawerNativeRow.clubs],
    'account': [DrawerNativeRow.tapToPay],
  };
}

/// One group of drawer rows. [id] is the merge anchor, not something the user
/// sees. An empty [title] renders no header (the top group); [collapsed] makes
/// the group an expandable tile instead, mirroring the navbar's dropdowns —
/// which is what keeps a twelve-item superuser Admin menu from burying
/// everything else.
class DrawerMenuSection {
  const DrawerMenuSection({
    required this.id,
    required this.items,
    this.title = '',
    this.icon = '',
    this.collapsed = false,
  });

  /// Null when the section has no usable items left after validation.
  static DrawerMenuSection? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final rawItems = raw['items'];
    final items = <DrawerMenuItem>[];
    if (rawItems is List) {
      for (final rawItem in rawItems) {
        final item = DrawerMenuItem.tryParse(rawItem);
        if (item != null) {
          items.add(item);
        }
      }
    }
    if (items.isEmpty) {
      return null;
    }
    return DrawerMenuSection(
      id: _str(raw['id']).trim(),
      title: _str(raw['title']).trim(),
      icon: _str(raw['icon']).trim(),
      collapsed: raw['collapsed'] == true,
      items: items,
    );
  }

  final String id;
  final String title;
  final String icon;
  final bool collapsed;
  final List<DrawerMenuItem> items;
}

/// One web link in the drawer. [path] is always site-relative by the time it
/// gets here — see [sitePathOrNull].
class DrawerMenuItem {
  const DrawerMenuItem({
    required this.title,
    required this.path,
    this.icon = '',
  });

  /// Null when the entry has no title, no usable path, or a path pointing off
  /// this deployment's host. These rows load in the shell's WebView, so an
  /// off-host link is not a broken link — it is a way to put an arbitrary site
  /// inside the app's own chrome, and it is refused for the same reason
  /// `terms_url` is (`AppConfig`).
  static DrawerMenuItem? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final title = _str(raw['title']).trim();
    if (title.isEmpty) {
      return null;
    }
    final path = sitePathOrNull(_str(raw['path']).trim());
    if (path == null) {
      return null;
    }
    return DrawerMenuItem(
      title: title,
      path: path,
      icon: _str(raw['icon']).trim(),
    );
  }

  final String title;
  final String path;

  /// A Bootstrap Icons name (`bi-star-fill`), exactly as the website writes
  /// it, or empty for no icon. Unknown names fall back to a neutral glyph
  /// rather than failing — see `biIcon`.
  final String icon;
}

/// A row the app owns. These exist because they cannot be a URL: signing out
/// clears the JWT, the cookie jar and the Square authorization; offline mode
/// and Tap to Pay are native screens; clubs is a live list from
/// `myClubsProvider`. The server never sends them and never positions them.
enum DrawerNativeRow { offlineMode, clubs, tapToPay, signOut }

/// A merged section, ready to render.
class DrawerSectionView {
  const DrawerSectionView({
    required this.entries,
    this.title = '',
    this.icon = '',
    this.collapsed = false,
  });

  final String title;
  final String icon;
  final bool collapsed;
  final List<DrawerEntry> entries;
}

/// One merged row: a link from the server, or one of the app's own.
sealed class DrawerEntry {
  const DrawerEntry();
}

/// A web link from the payload.
class DrawerLinkEntry extends DrawerEntry {
  const DrawerLinkEntry(this.item);

  final DrawerMenuItem item;
}

/// A placeholder for an app-owned row; the widget layer decides whether it is
/// visible (offline data exists, the user is a merchant, …).
class DrawerNativeEntry extends DrawerEntry {
  const DrawerNativeEntry(this.row);

  final DrawerNativeRow row;
}

/// **Cold-start / offline skeleton. Not the menu — do not grow it.**
///
/// The real drawer is the server's, built from the same structure that renders
/// base.html's navbar, so it follows the website per user and per deployment
/// with no app release. This list exists for exactly two moments: the first
/// launch on a phone that has never reached the server, and a cold start with
/// no connectivity before the last-good payload has been read off disk.
///
/// Every link added here becomes a third copy of the navbar to keep in sync by
/// hand — web template, mobile JSON, app fallback — and it will rot silently,
/// which is the exact failure this whole feature exists to end. Six links that
/// get a stranded user somewhere is the entire job. If something is missing
/// from the drawer, fix the server payload.
const DrawerMenu bundledDrawerMenu = DrawerMenu(
  sections: [
    DrawerMenuSection(
      id: 'main',
      items: [
        DrawerMenuItem(
          title: 'Auctions',
          path: '/auctions/',
          icon: 'bi-hammer',
        ),
        DrawerMenuItem(title: 'Lots', path: '/lots/all/', icon: 'bi-grid'),
      ],
    ),
    DrawerMenuSection(
      id: 'lots',
      title: 'My lots',
      items: [
        DrawerMenuItem(
          title: 'Selling',
          path: '/selling/',
          icon: 'bi-cash-coin',
        ),
        DrawerMenuItem(
          title: 'Watched lots',
          path: '/lots/watched/',
          icon: 'bi-star-fill',
        ),
      ],
    ),
    DrawerMenuSection(
      id: 'account',
      title: 'Account',
      items: [
        DrawerMenuItem(
          title: 'Account information',
          path: '/account/',
          icon: 'bi-info-circle',
        ),
        DrawerMenuItem(title: 'Invoices', path: '/invoices/', icon: 'bi-bag'),
      ],
    ),
  ],
);

String _str(Object? v) => v == null ? '' : v.toString();
