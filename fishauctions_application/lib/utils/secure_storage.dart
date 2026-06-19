import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Single shared [FlutterSecureStorage] instance for the whole app.
///
/// On Android it uses Jetpack Security's EncryptedSharedPreferences
/// (`encryptedSharedPreferences: true`) rather than the legacy KeyStore-only
/// backend. Every place that persists secrets (JWTs, the device UUID, the saved
/// printer) must use this so they share one consistent, hardened backend.
///
/// Requires Android API 23+, which the app's minSdk (28) satisfies. Pair this
/// with `android:allowBackup="false"` in the manifest so the encrypted blob is
/// never captured by Auto Backup (its key lives in the KeyStore and is not
/// backed up, so a restored blob would be unreadable anyway).
const secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);
