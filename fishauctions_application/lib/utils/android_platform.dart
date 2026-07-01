import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Thin bridge to a few `android.os.Build` values that Flutter doesn't expose.
/// Backed by the MethodChannel registered in `MainActivity.kt`.
class AndroidPlatform {
  const AndroidPlatform._();

  static const _channel = MethodChannel('com.fishauctions.app/platform');

  /// `Build.VERSION.SDK_INT`, or 0 on non-Android platforms / on error.
  ///
  /// Used to decide whether classic-Bluetooth discovery needs the runtime
  /// location permission (Android 11 / API ≤ 30) or only `BLUETOOTH_SCAN`
  /// (Android 12 / API 31+).
  static Future<int> sdkInt() async {
    if (!Platform.isAndroid) {
      return 0;
    }
    try {
      return await _channel.invokeMethod<int>('getSdkInt') ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Whether this device can take a Square Tap to Pay charge — NFC hardware +
  /// API 31+. Answered natively because the Square Flutter plugin's own
  /// `isDeviceCapable()` is iOS-only (on Android it hits `notImplemented()` and
  /// throws `MissingPluginException`). Returns false on non-Android platforms
  /// and on any channel error, so a missing gate never blocks the app — it just
  /// reports "not capable".
  static Future<bool> isTapToPayCapable() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isTapToPayCapable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Initializes the Square Mobile Payments SDK with [applicationId] (the
  /// deployment's Square Application ID, from `/api/mobile/config/`). Must run
  /// once before any authorize()/charge() call — the Square Flutter plugin
  /// doesn't expose initialize(), so it goes through our channel.
  ///
  /// Idempotent for the same id; throws [PlatformException] if the device was
  /// already initialized for a *different* id (switch deployments → restart) or
  /// if the SDK rejects the id. No-op on non-Android platforms.
  static Future<void> initializeSquare(String applicationId) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('initializeSquare', {
      'applicationId': applicationId,
    });
  }
}
