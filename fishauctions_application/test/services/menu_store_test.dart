import 'dart:convert';
import 'dart:io';

import 'package:fishauctions_application/models/drawer_menu.dart';
import 'package:fishauctions_application/services/menu_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The drawer menu's three tiers: **server payload > last-good persisted
/// payload > bundled skeleton.**
///
/// The middle tier is the point of the class. `ConfigService` caches for the
/// process only, so without a file on disk every cold start with no
/// connectivity — routine at an auction hall — would drop a long-time user
/// back to the bundled six links.
void main() {
  late Directory dir;
  late MenuStore store;

  Map<String, dynamic> payload(String title, String path) => {
    'sections': [
      {
        'id': 'main',
        'items': [
          {'title': title, 'path': path, 'icon': 'bi-grid'},
        ],
      },
    ],
  };

  List<String> titlesOf(DrawerMenu menu) => [
    for (final section in menu.sections)
      for (final item in section.items) item.title,
  ];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('menu_store_test');
    store = MenuStore.forDirectory(dir);
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  test('with nothing anywhere, the bundled skeleton renders', () async {
    await store.ensureLoaded();
    expect(store.source, MenuSource.bundled);
    expect(store.menu, same(bundledDrawerMenu));
  });

  test('a server payload wins and is persisted verbatim', () async {
    await store.ensureLoaded();
    await store.adopt(payload('Auctions', '/auctions/'));

    expect(store.source, MenuSource.server);
    expect(titlesOf(store.menu), ['Auctions']);

    final file = File('${dir.path}/${MenuStore.fileName}');
    expect(file.existsSync(), isTrue);
    // Verbatim, not re-serialized from the model: a key this build can't read
    // yet has to survive on disk.
    expect(
      jsonDecode(file.readAsStringSync()),
      payload('Auctions', '/auctions/'),
    );
  });

  test('the persisted payload is used on the next cold start', () async {
    await store.ensureLoaded();
    await store.adopt(payload('Watched lots', '/lots/watched/'));

    // A new process, same documents directory, and no network at all.
    final restarted = MenuStore.forDirectory(dir);
    await restarted.ensureLoaded();
    expect(restarted.source, MenuSource.persisted);
    expect(titlesOf(restarted.menu), ['Watched lots']);
  });

  test('a server payload outranks the persisted one', () async {
    await store.ensureLoaded();
    await store.adopt(payload('Old', '/old/'));

    final restarted = MenuStore.forDirectory(dir);
    await restarted.ensureLoaded();
    expect(titlesOf(restarted.menu), ['Old']);
    await restarted.adopt(payload('New', '/new/'));
    expect(restarted.source, MenuSource.server);
    expect(titlesOf(restarted.menu), ['New']);
  });

  test('an unparseable payload is ignored, never adopted', () async {
    await store.ensureLoaded();
    await store.adopt(payload('Auctions', '/auctions/'));

    // Every one of these is a payload with nothing renderable in it.
    for (final bad in <Object?>[
      null,
      'nope',
      const <String, dynamic>{},
      {'sections': <Object>[]},
      {
        'sections': [
          {
            'id': 'main',
            'items': [
              {'title': 'Evil', 'path': 'https://evil.example/'},
            ],
          },
        ],
      },
    ]) {
      await store.adopt(bad);
      expect(store.source, MenuSource.server);
      expect(titlesOf(store.menu), ['Auctions'], reason: 'rejected: $bad');
    }

    // And the good copy on disk is left alone, so a deployment that ships a
    // broken menu degrades to yesterday's working one rather than to nothing.
    final restarted = MenuStore.forDirectory(dir);
    await restarted.ensureLoaded();
    expect(titlesOf(restarted.menu), ['Auctions']);
  });

  test('a corrupt file on disk falls through to the bundled menu', () async {
    File(
      '${dir.path}/${MenuStore.fileName}',
    ).writeAsStringSync('{ this is not json');
    await store.ensureLoaded();
    expect(store.source, MenuSource.bundled);
    expect(store.menu, same(bundledDrawerMenu));
  });

  test('a file holding a valid-JSON-but-junk menu falls through', () async {
    File(
      '${dir.path}/${MenuStore.fileName}',
    ).writeAsStringSync(jsonEncode({'sections': 'nope'}));
    await store.ensureLoaded();
    expect(store.source, MenuSource.bundled);
  });

  test('sign-out wipes it: the next account gets its own menu', () async {
    await store.ensureLoaded();
    await store.adopt(payload('Admin', '/admin/'));
    await store.clear();

    expect(store.source, MenuSource.bundled);
    expect(File('${dir.path}/${MenuStore.fileName}').existsSync(), isFalse);

    final restarted = MenuStore.forDirectory(dir);
    await restarted.ensureLoaded();
    expect(restarted.source, MenuSource.bundled);
  });

  test('notifies so an open drawer picks the menu up in place', () async {
    var notifications = 0;
    store.addListener(() => notifications++);

    await store.ensureLoaded();
    expect(notifications, 1, reason: 'the disk read is a rebuild');

    await store.adopt(payload('Auctions', '/auctions/'));
    expect(notifications, 2);

    // A rejected payload changes nothing, so it must not churn the drawer.
    await store.adopt('nope');
    expect(notifications, 2);

    await store.clear();
    expect(notifications, 3);
  });

  test('ensureLoaded is idempotent and never re-reads', () async {
    await store.ensureLoaded();
    await store.adopt(payload('Auctions', '/auctions/'));
    // A second call must not clobber the live payload with the disk copy.
    await store.ensureLoaded();
    expect(store.source, MenuSource.server);
    expect(titlesOf(store.menu), ['Auctions']);
  });
}
