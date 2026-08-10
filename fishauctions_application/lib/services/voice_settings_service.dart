import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../models/voice_settings.dart';
import '../utils/secure_storage.dart';

final _log = Logger();

/// Reads and writes the operator's [VoiceSettings] for this device.
///
/// Kept in the same store as everything else device-local (see
/// `PrinterSetupPrompt`, `LastPageService`) rather than adding a preferences
/// package for three fields. Nothing here is a secret; it's simply the one
/// storage this app already has.
///
/// **Cached in memory and loaded once**, because [current] is read on the path
/// that starts a session — and, more importantly, on the path that *parses an
/// utterance*, where a storage round trip per phrase would be absurd. The
/// cache is only ever written through [save], so it can't drift.
class VoiceSettingsService {
  VoiceSettingsService._();

  static final VoiceSettingsService instance = VoiceSettingsService._();

  static const _key = 'voice_settings';

  VoiceSettings _current = VoiceSettings.none;
  bool _loaded = false;

  /// What's in force right now. [VoiceSettings.none] until [load] has run,
  /// which is the honest answer — and the safe one, since it means "use the
  /// deployment's grammar".
  VoiceSettings get current => _current;

  Future<VoiceSettings> load() async {
    if (_loaded) {
      return _current;
    }
    try {
      final raw = await secureStorage.read(key: _key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _current = VoiceSettings.fromJson(decoded);
        }
      }
    } on Object catch (e) {
      // A settings read is never worth failing a session over: the deployment's
      // own grammar is a perfectly good answer and is what null means anyway.
      _log.w('Voice settings read failed: $e');
    }
    _loaded = true;
    return _current;
  }

  /// Apply [changes] on top of what's already stored, and persist.
  ///
  /// Merged rather than replaced so the page can send one field. A panel that
  /// had to send all three would silently reset the other two every time an
  /// older build's HTML met a newer app, or the reverse.
  Future<VoiceSettings> save(VoiceSettings changes) async {
    await load();
    _current = _current.merge(changes);
    try {
      await secureStorage.write(
        key: _key,
        value: jsonEncode(_current.toJson()),
      );
    } on Object catch (e) {
      // Reported nowhere: the setting is already live in memory for this
      // session, which is the thing the operator asked for. Losing it on the
      // next launch is a smaller failure than an error toast mid-auction.
      _log.w('Voice settings write failed: $e');
    }
    return _current;
  }

  /// Back to the deployment's defaults, every field.
  Future<void> clear() async {
    _current = VoiceSettings.none;
    _loaded = true;
    try {
      await secureStorage.delete(key: _key);
    } on Object catch (e) {
      _log.w('Voice settings delete failed: $e');
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _current = VoiceSettings.none;
    _loaded = false;
  }
}
