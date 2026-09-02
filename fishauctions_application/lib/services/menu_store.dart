import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/drawer_menu.dart';

/// Which tier the drawer is currently being built from.
enum MenuSource {
  /// The `menu` block from this process's `/api/mobile/config/` fetch.
  server,

  /// The last payload that parsed, read back off disk.
  persisted,

  /// [bundledDrawerMenu] — this build has never seen a server menu.
  bundled,
}

/// Holds the navigation drawer's menu and remembers the last good one across
/// launches (BACKEND_SPEC.md Part MENU).
///
/// Three tiers, in this order: **server payload > last-good persisted payload
/// > bundled skeleton.** The middle one is the reason this class exists at
/// all. `ConfigService` caches for the process only, so without it every cold
/// start with no connectivity — routine at an auction hall — would drop a user
/// who has been running this app for months back to six bundled links. One
/// JSON file in the app documents directory, the same shape as the offline
/// store's two, fixes that: the drawer a user saw yesterday is the one they get
/// today, whatever the network is doing.
///
/// The payload is stored **verbatim**, not re-serialized from the parsed
/// model, so a field this build doesn't understand yet survives on disk and
/// starts working the day the app learns to read it.
///
/// A [ChangeNotifier] because the menu routinely lands *after* the drawer has
/// been built — config is fetched off the startup critical path — and the
/// drawer is expected to pick it up in place, exactly as it already does for
/// clubs and offline mode.
class MenuStore extends ChangeNotifier {
  MenuStore._();

  /// Test hook: a fresh store with file IO redirected to a temp dir.
  @visibleForTesting
  MenuStore.forDirectory(Directory dir) : _dirOverride = dir;

  static final MenuStore instance = MenuStore._();

  static const String fileName = 'drawer_menu.json';

  Directory? _dirOverride;
  bool _loaded = false;
  DrawerMenu? _server;
  DrawerMenu? _persisted;

  /// The best menu available right now. Never null: worst case it is the
  /// bundled skeleton.
  DrawerMenu get menu => _server ?? _persisted ?? bundledDrawerMenu;

  /// Which tier [menu] came from.
  MenuSource get source {
    if (_server != null) {
      return MenuSource.server;
    }
    return _persisted == null ? MenuSource.bundled : MenuSource.persisted;
  }

  /// Read the last-good payload off disk. Idempotent; every entry point awaits
  /// it. An unreadable or unparseable file is treated as absent — this is a
  /// cache with a working fallback behind it, never worth crashing over.
  Future<void> ensureLoaded() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final file = await _file();
      if (file.existsSync()) {
        _persisted = DrawerMenu.tryParse(jsonDecode(await file.readAsString()));
      }
    } on Object catch (e) {
      debugPrint('Drawer menu load failed (using the bundled menu): $e');
      _persisted = null;
    }
    // The drawer may already have been built against the bundled skeleton by
    // the time this lands.
    notifyListeners();
  }

  /// Take the `menu` block from a fresh config fetch.
  ///
  /// A payload that doesn't parse is **ignored**, not adopted: the previous
  /// tier keeps rendering and the file on disk is left alone. A deployment
  /// that ships a broken menu therefore degrades to yesterday's working one
  /// rather than to nothing, and fixing it is a Django edit with no app
  /// involvement.
  Future<void> adopt(Object? raw) async {
    final parsed = DrawerMenu.tryParse(raw);
    if (parsed == null) {
      if (raw != null) {
        debugPrint('Drawer menu payload rejected; keeping the previous menu');
      }
      return;
    }
    _server = parsed;
    notifyListeners();
    try {
      await (await _file()).writeAsString(jsonEncode(raw));
    } on Object catch (e) {
      // The menu still works this session; it just won't survive a restart.
      debugPrint('Drawer menu persist failed: $e');
    }
  }

  /// Sign-out: the menu is built for one user (staff get the admin section),
  /// so the next account must not inherit it.
  Future<void> clear() async {
    _server = null;
    _persisted = null;
    _loaded = true;
    try {
      final file = await _file();
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object catch (e) {
      debugPrint('Drawer menu clear failed: $e');
    }
    notifyListeners();
  }

  Future<File> _file() async {
    final dir = _dirOverride ?? await getApplicationDocumentsDirectory();
    return File('${dir.path}/$fileName');
  }
}
