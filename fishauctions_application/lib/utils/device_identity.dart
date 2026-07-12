import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../constants/app_constants.dart';
import 'secure_storage.dart';

/// Stable per-install identity for `POST /api/mobile/devices/register/`.
/// The UUID is generated once and persisted so the backend upsert keys on the
/// same device across launches.
class DeviceIdentity {
  const DeviceIdentity._();

  static const _storage = secureStorage;
  static const _key = 'device_uuid';

  static Future<String> uuid() async {
    final existing = await _storage.read(key: _key);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final id = _generateV4();
    await _storage.write(key: _key, value: id);
    return id;
  }

  /// Backend expects 'ios' | 'android'.
  static String get platformTag =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// The installed build's version ("1.0.0"), read from the platform so it can
  /// never drift from pubspec.yaml. Falls back to '0.0.0' if the platform
  /// lookup fails (e.g. in unit tests with no host).
  static Future<String> appVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } on Object {
      return '0.0.0';
    }
  }

  static String get deviceName => '${AppConstants.appName} ($platformTag)';

  static String _generateV4() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final g1 = hex.substring(0, 8);
    final g2 = hex.substring(8, 12);
    final g3 = hex.substring(12, 16);
    final g4 = hex.substring(16, 20);
    final g5 = hex.substring(20);
    return '$g1-$g2-$g3-$g4-$g5';
  }
}
