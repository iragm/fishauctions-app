import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

import '../models/label_prefs.dart';
import '../utils/secure_storage.dart';
import 'api_service.dart';

final _log = Logger();

const _keyPrefsCache = 'label_prefs_cache';

/// Client for `GET/PATCH /api/mobile/labels/prefs/` (the user's
/// `UserLabelPrefs` row — print method, label size preset, warnings).
///
/// The print method is configured on the `/printing/` web page and consulted
/// app-side before every print and PDF download, so this sits in front of the
/// user's tap and has to answer quickly.
///
/// **It used to ask the network every time and wait for the answer** — a
/// fraction of a second normally, but the API client allows 15 s to connect
/// and 15 s to receive, and an auction hall's wifi is routinely the kind
/// that's up without passing traffic. Then a print tap did nothing visible
/// until the timeout, every time. Now:
///
///  * a copy fetched in the last [_freshFor] answers at once, and is
///    refreshed in the background so the next tap has the newest;
///  * otherwise the network gets [_networkWait], after which the last good
///    copy (memory, then disk) answers while the request carries on and
///    updates it when it lands;
///  * [markStale] — called by the shell around the `/printing/` page, the
///    only place the method changes in-app — forces the next call to the
///    network, so a dropdown change just saved is never answered from memory.
class LabelPrefsService {
  LabelPrefsService._();
  static final LabelPrefsService instance = LabelPrefsService._();

  final _storage = secureStorage;

  /// How long a fetched copy is trusted without asking again. Long enough to
  /// cover a printing session; short enough that a change made on another
  /// device (the website on a computer) is picked up within a few prints.
  static const _freshFor = Duration(minutes: 10);

  /// A memory copy older than this is still answered with, but refreshed
  /// behind the answer.
  static const _refreshAfter = Duration(minutes: 1);

  /// How long a caller waits on the network when there's no fresh copy.
  static const _networkWait = Duration(seconds: 3);

  LabelPrefs? _memo;
  DateTime? _memoAt;
  bool _stale = true;
  Future<LabelPrefs?>? _inFlight;

  /// The user's current prefs — see the class doc for where they come from.
  /// Null only when nothing has ever been fetched (callers default to
  /// [PrintMethod.pdf]).
  Future<LabelPrefs?> fetch() async {
    final memo = _memo;
    final age = _memoAt == null ? null : DateTime.now().difference(_memoAt!);
    if (memo != null && !_stale && age != null && age < _freshFor) {
      if (age > _refreshAfter) {
        unawaited(_refresh());
      }
      return memo;
    }
    try {
      final live = await _refresh().timeout(_networkWait);
      if (live != null) {
        return live;
      }
    } on TimeoutException {
      _log.w('Label prefs slow to answer; using the last good copy');
    }
    return _memo ?? await _cached();
  }

  /// Fetches in the background so the next [fetch] answers from memory —
  /// the shell calls this at startup and on resume. Never throws.
  void warm() => unawaited(_refresh());

  /// The next [fetch] must ask the server: the user may have just changed
  /// their print method on `/printing/`.
  void markStale() => _stale = true;

  /// One request at a time; a [fetch] that gave up waiting still lets this
  /// finish, and its answer becomes the memory copy.
  Future<LabelPrefs?> _refresh() => _inFlight ??= _get().whenComplete(() {
    _inFlight = null;
  });

  Future<LabelPrefs?> _get() async {
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'labels/prefs/',
      );
      final data = res.data;
      if (data == null) {
        return null;
      }
      final prefs = LabelPrefs.fromJson(data);
      _remember(prefs);
      await _storage.write(key: _keyPrefsCache, value: jsonEncode(data));
      return prefs;
    } on DioException catch (e) {
      _log.w('Label prefs fetch failed (using cache): ${e.message}');
      return null;
    } on Object catch (e) {
      _log.w('Label prefs unreadable (using cache): $e');
      return null;
    }
  }

  void _remember(LabelPrefs prefs) {
    _memo = prefs;
    _memoAt = DateTime.now();
    _stale = false;
  }

  /// PATCHes a subset of the prefs — e.g. adopting a printer-reported label
  /// size (`{"preset": "custom", "unit": "cm", "label_width": …}`). Returns
  /// the updated prefs, or null on failure.
  Future<LabelPrefs?> update(Map<String, dynamic> patch) async {
    try {
      final res = await ApiService.instance.dio.patch<Map<String, dynamic>>(
        'labels/prefs/',
        data: patch,
      );
      final data = res.data;
      if (data == null) {
        return null;
      }
      final prefs = LabelPrefs.fromJson(data);
      _remember(prefs);
      await _storage.write(key: _keyPrefsCache, value: jsonEncode(data));
      return prefs;
    } on DioException catch (e) {
      _log.w('Label prefs update failed: ${e.message}');
      return null;
    }
  }

  Future<LabelPrefs?> _cached() async {
    final raw = await _storage.read(key: _keyPrefsCache);
    if (raw == null) {
      return null;
    }
    try {
      return LabelPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// Forgets this account's prefs, in memory and on disk — sign-out. They
  /// used to survive it on disk, so the next account's first offline print
  /// could follow the previous one's print method.
  Future<void> clear() async {
    _memo = null;
    _memoAt = null;
    _stale = true;
    _inFlight = null;
    try {
      await _storage.delete(key: _keyPrefsCache);
    } on Object catch (e) {
      _log.w('Label prefs cache clear failed: $e');
    }
  }
}
