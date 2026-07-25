import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/secure_storage.dart';

/// Remembers the web page the shell was last showing, so a task switch that
/// costs the app its process (Android reclaiming memory behind the camera,
/// AR mode, or another heavy app) comes back to where the user was instead
/// of the site root.
///
/// Scoped to the account that was signed in when it was saved and expired
/// after [maxAge]: a restored page is only ever the same user's recent
/// browsing, never the previous owner of a shared phone's, and never a lot
/// page from last week.
class LastPageService {
  LastPageService._();

  static final LastPageService instance = LastPageService._();

  /// Beyond this, "where I was" isn't a useful answer any more — the user is
  /// starting a new session, so the home page is.
  static const Duration maxAge = Duration(hours: 24);

  static const String _key = 'last_web_page';

  /// Paths that must never come back as a landing page: the login bounce
  /// (the shell repairs sessions itself), the session handoff (its token is
  /// single-use), and logout.
  static bool _isRestorable(String path) =>
      path.startsWith('/') &&
      !path.startsWith('/login/') &&
      !path.startsWith('/logout/') &&
      !path.startsWith('/api/');

  /// Records [path] (site-relative, query included) as where [userId] is.
  /// Best-effort — a failed write just means no restore next launch.
  Future<void> remember(String path, {required int userId}) async {
    if (!_isRestorable(path)) {
      return;
    }
    try {
      await secureStorage.write(
        key: _key,
        value: jsonEncode({
          'path': path,
          'user': userId,
          'at': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } on Object catch (e) {
      debugPrint('Could not save the current page: $e');
    }
  }

  /// The page to land on for [userId], or null when there's nothing recent
  /// saved for them.
  Future<String?> restore({required int userId}) async {
    try {
      final raw = await secureStorage.read(key: _key);
      if (raw == null) {
        return null;
      }
      final data = jsonDecode(raw);
      if (data is! Map || data['user'] != userId) {
        return null;
      }
      final at = data['at'];
      final path = data['path'];
      if (at is! int || path is! String || !_isRestorable(path)) {
        return null;
      }
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(at),
      );
      return (age.isNegative || age > maxAge) ? null : path;
    } on Object catch (e) {
      debugPrint('Could not restore the last page: $e');
      return null;
    }
  }

  Future<void> clear() async {
    try {
      await secureStorage.delete(key: _key);
    } on Object catch (e) {
      debugPrint('Could not clear the last page: $e');
    }
  }
}
