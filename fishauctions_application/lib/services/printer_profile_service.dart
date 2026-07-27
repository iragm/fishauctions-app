import 'dart:async';

import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

import '../models/printer_device_info.dart';
import '../models/printer_profile.dart';
import '../utils/secure_storage.dart';
import 'api_service.dart';
import 'bundled_printer_profiles.dart';

final _log = Logger();

const _keyProfilesCache = 'printer_profiles_cache';

/// Loads the printer profiles the app can drive, cache-first so printing
/// works offline at an auction hall:
///
/// 1. last `GET /api/mobile/printers/profiles/` response cached on-device
///    (refreshed opportunistically in the background on each use),
/// 2. a live fetch when there's no cache yet (first run),
/// 3. the bundled seed profiles when both are unavailable.
///
/// Profiles whose `schema_version` is newer than this build understands are
/// dropped at parse time.
class PrinterProfileService {
  PrinterProfileService._();
  static final PrinterProfileService instance = PrinterProfileService._();

  final _storage = secureStorage;
  List<PrinterProfile>? _memory;

  Future<List<PrinterProfile>> getProfiles() async {
    final memory = _memory;
    if (memory != null) {
      return memory;
    }
    final cached = await _readCache();
    if (cached != null && cached.isNotEmpty) {
      _memory = cached;
      // Serve the cache now; pick up new/edited admin rows for next time.
      unawaited(refresh());
      return cached;
    }
    final fresh = await refresh();
    if (fresh != null && fresh.isNotEmpty) {
      return fresh;
    }
    // Deliberately not memoized: the next call retries the network rather
    // than pinning this install to the bundle until an app restart.
    return bundledPrinterProfiles();
  }

  /// Fetches and caches the live profile list. Returns null on any failure —
  /// callers fall back to cache/bundle.
  Future<List<PrinterProfile>?> refresh() async {
    try {
      final res = await ApiService.instance.dio.get<String>(
        'printers/profiles/',
        options: Options(responseType: ResponseType.plain),
      );
      final body = res.data;
      if (body == null || body.isEmpty) {
        return null;
      }
      final profiles = parsePrinterProfiles(body);
      if (profiles.isEmpty) {
        return null;
      }
      await _storage.write(key: _keyProfilesCache, value: body);
      return _memory = profiles;
    } on Object catch (e) {
      _log.w('Printer profile refresh failed (using cache/bundle): $e');
      return null;
    }
  }

  Future<List<PrinterProfile>?> _readCache() async {
    final raw = await _storage.read(key: _keyProfilesCache);
    if (raw == null) {
      return null;
    }
    try {
      return parsePrinterProfiles(raw);
    } on Object {
      await _storage.delete(key: _keyProfilesCache);
      return null;
    }
  }

  /// The profile to auto-select for a scanned device, by advertised name —
  /// priority order, first match wins. Null when nothing matches (the connect
  /// UI then asks the printer itself, and only then the user).
  Future<PrinterProfile?> matchByName(String bleName) async {
    if (bleName.isEmpty) {
      return null;
    }
    for (final profile in await candidates()) {
      if (profile.matchesName(bleName)) {
        return profile;
      }
    }
    return null;
  }

  /// The profile for a printer whose advertised name matched nothing, decided
  /// from what the printer reports over GATT (see [matchProfileForDeviceInfo]
  /// for the confidence ladder). Null still means "ask the user".
  Future<(PrinterProfile, ProfileMatch)?> matchByDeviceInfo(
    PrinterDeviceInfo info,
  ) async => matchProfileForDeviceInfo(await candidates(), info);

  /// The profile for a printer that answered a `PrinterProbe` query in
  /// [language] — but only when exactly one profile speaks it.
  ///
  /// The uniqueness rule is the whole safety argument. Knowing a printer
  /// speaks TSPL doesn't tell you its printhead width or its GATT ids, so
  /// picking one of several TSPL profiles at random would drive it wrong. One
  /// candidate means there is nothing to get wrong; more than one is a real
  /// question, and those are the only ones worth putting to the user.
  ///
  /// Generic fallback rows are excluded, and that exclusion is what keeps the
  /// rule honest — see [matchProfileForLanguage], which owns the rule.
  Future<PrinterProfile?> matchByLanguage(String? language) async =>
      matchProfileForLanguage(await candidates(), language);

  /// Every profile this build can offer, in preference order: the server's
  /// list (live or cached) first, then any bundled seed it doesn't include —
  /// the server list may be reachable but missing the seeds, and the bundle is
  /// the last line that keeps a D11s working.
  Future<List<PrinterProfile>> candidates() async {
    final profiles = await getProfiles();
    final slugs = {for (final p in profiles) p.slug};
    return [
      ...profiles,
      for (final p in bundledPrinterProfiles())
        if (!slugs.contains(p.slug)) p,
    ];
  }

  /// Resolves a saved printer's profile by slug. A null/unknown [slug] (a
  /// printer saved by a pre-profile app build) falls back to the D11s profile
  /// that build hardcoded, so existing pairings keep printing.
  Future<PrinterProfile?> bySlug(String? slug) async {
    final profiles = await getProfiles();
    const legacyDefault = 'd11s-aiyin';
    final wanted = (slug == null || slug.isEmpty) ? legacyDefault : slug;
    for (final profile in profiles) {
      if (profile.slug == wanted) {
        return profile;
      }
    }
    for (final profile in bundledPrinterProfiles()) {
      if (profile.slug == wanted) {
        return profile;
      }
    }
    return null;
  }
}
