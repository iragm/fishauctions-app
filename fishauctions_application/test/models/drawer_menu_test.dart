import 'package:fishauctions_application/config/environment.dart';
import 'package:fishauctions_application/models/drawer_menu.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `menu` block of `/api/mobile/config/` — the drawer's contents.
///
/// Two things are being defended here. One: a bad payload must never be able
/// to empty the drawer, so every validation rule *drops the bad row* and a
/// wholesale failure returns null so the caller can fall through to the last
/// good payload. Two: the rows the app owns (sign out, offline mode, Tap to
/// Pay, clubs) are not in the payload and must survive whatever the server
/// sends — including a payload that has never heard of them.
void main() {
  final host = Uri.parse(EnvironmentConfig.webBaseUrl).host;

  Map<String, dynamic> item(String title, String path, {String? icon}) => {
    'title': title,
    'path': path,
    'icon': ?icon,
  };

  group('DrawerMenu.tryParse', () {
    test('parses a well-formed payload', () {
      final menu = DrawerMenu.tryParse({
        'version': 1,
        'sections': [
          {
            'id': 'main',
            'items': [
              item('Auctions', '/auctions/', icon: 'bi-hammer'),
              item('Lots', '/lots/all/', icon: 'bi-grid'),
            ],
          },
          {
            'id': 'admin',
            'title': 'Admin',
            'icon': 'bi-shield-lock',
            'collapsed': true,
            'items': [item('Traffic', '/admin/traffic/?days=30')],
          },
        ],
      });

      expect(menu, isNotNull);
      expect(menu!.sections, hasLength(2));

      final main = menu.sections.first;
      expect(main.id, 'main');
      expect(main.title, isEmpty);
      expect(main.collapsed, isFalse);
      expect(main.items.map((i) => i.title), ['Auctions', 'Lots']);
      expect(main.items.first.path, '/auctions/');
      expect(main.items.first.icon, 'bi-hammer');

      final admin = menu.sections.last;
      expect(admin.title, 'Admin');
      expect(admin.icon, 'bi-shield-lock');
      expect(admin.collapsed, isTrue);
      // The admin links carry query strings and mean them.
      expect(admin.items.single.path, '/admin/traffic/?days=30');
    });

    test('an absolute URL on our own host is reduced to its path', () {
      final menu = DrawerMenu.tryParse({
        'sections': [
          {
            'id': 'main',
            'items': [item('Traffic', 'https://$host/admin/traffic/?days=30')],
          },
        ],
      });
      expect(
        menu!.sections.single.items.single.path,
        '/admin/traffic/?days=30',
      );
    });

    test('drops entries with no title and entries with no path', () {
      final menu = DrawerMenu.tryParse({
        'sections': [
          {
            'id': 'main',
            'items': [
              {'path': '/auctions/'},
              {'title': '   ', 'path': '/lots/'},
              {'title': 'Selling'},
              {'title': 'Invoices', 'path': ''},
              item('Lots', '/lots/all/'),
            ],
          },
        ],
      });
      expect(menu!.sections.single.items.map((i) => i.title), ['Lots']);
    });

    test('drops off-host links rather than following them', () {
      // These load in the shell's own WebView; an arbitrary host in the app's
      // chrome is not a broken link, it is a doorway.
      final menu = DrawerMenu.tryParse({
        'sections': [
          {
            'id': 'main',
            'items': [
              item('Evil', 'https://evil.example/x/'),
              item('Protocol relative', '//evil.example/x/'),
              item('Junk', 'not a url'),
              item('Lots', '/lots/all/'),
            ],
          },
        ],
      });
      expect(menu!.sections.single.items.map((i) => i.title), ['Lots']);
    });

    test('drops a section whose items were all dropped', () {
      final menu = DrawerMenu.tryParse({
        'sections': [
          {
            'id': 'main',
            'items': [item('Lots', '/lots/all/')],
          },
          {
            'id': 'empty',
            'title': 'Nothing',
            'items': [item('Evil', 'https://evil.example/')],
          },
          {'id': 'alsoEmpty', 'title': 'Nothing', 'items': <Object>[]},
        ],
      });
      expect(menu!.sections.map((s) => s.id), ['main']);
    });

    test('a section with a bad shape is skipped, not fatal', () {
      final menu = DrawerMenu.tryParse({
        'sections': [
          'not a section',
          42,
          {
            'id': 'main',
            'items': ['not an item', null, item('Lots', '/lots/all/')],
          },
        ],
      });
      expect(menu!.sections.single.items.map((i) => i.title), ['Lots']);
    });

    test('unknown keys are ignored, not fatal', () {
      final menu = DrawerMenu.tryParse({
        'version': 7,
        'generated_at': '2026-09-02T00:00:00Z',
        'sections': [
          {
            'id': 'main',
            'badge': 'new_auctions',
            'items': [
              {'title': 'Lots', 'path': '/lots/all/', 'target': '_blank'},
            ],
          },
        ],
      });
      expect(menu!.sections.single.items.single.title, 'Lots');
    });

    test('null when nothing is renderable', () {
      // Every one of these must fall through to the next tier rather than
      // render an empty drawer.
      expect(DrawerMenu.tryParse(null), isNull);
      expect(DrawerMenu.tryParse('sections'), isNull);
      expect(DrawerMenu.tryParse(const <String, dynamic>{}), isNull);
      expect(DrawerMenu.tryParse({'sections': 'nope'}), isNull);
      expect(DrawerMenu.tryParse({'sections': <Object>[]}), isNull);
      expect(
        DrawerMenu.tryParse({
          'sections': [
            {
              'id': 'main',
              'items': [item('Evil', 'https://evil.example/')],
            },
          ],
        }),
        isNull,
      );
    });
  });

  group('withNativeRows', () {
    List<DrawerNativeRow> nativesOf(List<DrawerSectionView> views) => [
      for (final view in views)
        for (final entry in view.entries)
          if (entry is DrawerNativeEntry) entry.row,
    ];

    test('merges the app rows at their anchors', () {
      final menu = DrawerMenu.tryParse({
        'sections': [
          {
            'id': 'main',
            'items': [item('Auctions', '/auctions/')],
          },
          {
            'id': 'account',
            'title': 'Account',
            'items': [item('Invoices', '/invoices/')],
          },
        ],
      })!;
      final views = menu.withNativeRows();

      // main: link, then offline mode, then clubs.
      expect(views[0].entries, hasLength(3));
      expect((views[0].entries[0] as DrawerLinkEntry).item.title, 'Auctions');
      expect(
        (views[0].entries[1] as DrawerNativeEntry).row,
        DrawerNativeRow.offlineMode,
      );
      expect(
        (views[0].entries[2] as DrawerNativeEntry).row,
        DrawerNativeRow.clubs,
      );

      // account: link, then Tap to Pay.
      expect(
        (views[1].entries.last as DrawerNativeEntry).row,
        DrawerNativeRow.tapToPay,
      );

      // Sign out is always last, in its own trailing section.
      expect(views.last.entries, hasLength(1));
      expect(
        (views.last.entries.single as DrawerNativeEntry).row,
        DrawerNativeRow.signOut,
      );
    });

    test('native rows survive a payload that never mentions them', () {
      // The server owns *what the menu contains*; it does not own whether the
      // user can sign out. A payload with no anchor ids at all must still
      // produce all four app rows.
      final menu = DrawerMenu.tryParse({
        'sections': [
          {
            'id': 'something-the-app-has-never-heard-of',
            'title': 'Whatever',
            'items': [item('Lots', '/lots/all/')],
          },
        ],
      })!;
      expect(
        nativesOf(menu.withNativeRows()),
        containsAll(DrawerNativeRow.values),
      );
    });

    test('the bundled skeleton carries every native row too', () {
      expect(
        nativesOf(bundledDrawerMenu.withNativeRows()),
        containsAll(DrawerNativeRow.values),
      );
    });

    test('each native row appears exactly once', () {
      final rows = nativesOf(
        DrawerMenu.tryParse({
          'sections': [
            {
              'id': 'main',
              'items': [item('Auctions', '/auctions/')],
            },
          ],
        })!.withNativeRows(),
      );
      expect(rows.toSet(), DrawerNativeRow.values.toSet());
      expect(rows, hasLength(DrawerNativeRow.values.length));
    });

    test('a collapsed section never absorbs an app row', () {
      // A dropdown is the wrong place for Sign out or Offline mode: the rows
      // gate themselves and rebuild live, and hiding them behind a tap is not
      // the server's call to make.
      final menu = DrawerMenu.tryParse({
        'sections': [
          {
            'id': 'main',
            'collapsed': true,
            'title': 'Everything',
            'items': [item('Auctions', '/auctions/')],
          },
        ],
      })!;
      final views = menu.withNativeRows();
      expect(views.first.collapsed, isTrue);
      expect(views.first.entries.whereType<DrawerNativeEntry>(), isEmpty);
      expect(nativesOf(views), containsAll(DrawerNativeRow.values));
    });
  });

  group('bundledDrawerMenu', () {
    test('is a skeleton, not a second copy of the navbar', () {
      // If this ever needs raising, the payload is what should have changed.
      final links = [
        for (final section in bundledDrawerMenu.sections) ...section.items,
      ];
      expect(links.length, lessThanOrEqualTo(8));
      expect(links.map((i) => i.title), contains('Auctions'));
      for (final link in links) {
        expect(link.path, startsWith('/'));
        expect(link.title, isNotEmpty);
      }
    });

    test('anchors every section the app merges into', () {
      // Otherwise the offline cold start puts the app rows in the trailing
      // catch-all section instead of where they belong.
      final ids = bundledDrawerMenu.sections.map((s) => s.id).toSet();
      expect(ids, containsAll(DrawerMenu.nativeAnchors.keys));
    });
  });
}
