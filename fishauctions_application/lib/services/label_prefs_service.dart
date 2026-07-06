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
/// app-side at print/download time, so [fetch] is called per action (cheap,
/// and always up to date with a dropdown change the user just saved) with the
/// last good response cached as the offline fallback.
class LabelPrefsService {
  LabelPrefsService._();
  static final LabelPrefsService instance = LabelPrefsService._();

  final _storage = secureStorage;

  /// The user's current prefs — live when reachable, cached otherwise, null
  /// when neither is available (callers default to [PrintMethod.pdf]).
  Future<LabelPrefs?> fetch() async {
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'labels/prefs/',
      );
      final data = res.data;
      if (data == null) {
        return _cached();
      }
      await _storage.write(key: _keyPrefsCache, value: jsonEncode(data));
      return LabelPrefs.fromJson(data);
    } on DioException catch (e) {
      _log.w('Label prefs fetch failed (using cache): ${e.message}');
      return _cached();
    }
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
      await _storage.write(key: _keyPrefsCache, value: jsonEncode(data));
      return LabelPrefs.fromJson(data);
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
}
