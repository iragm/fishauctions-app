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
}
