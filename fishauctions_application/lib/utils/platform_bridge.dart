import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Thin bridge to the `com.fishauctions.app/platform` MethodChannel — the
/// small set of native calls the plugins don't cover. Implemented by
/// `MainActivity.kt` on Android and `AppDelegate.swift` on iOS; the two
/// platforms deliberately expose different methods (documented per call).
class PlatformBridge {
  const PlatformBridge._();

  static const _channel = MethodChannel('com.fishauctions.app/platform');

  /// `Build.VERSION.SDK_INT`, or 0 on non-Android platforms / on error.
  ///
  /// Android-only by nature. Used to decide whether classic-Bluetooth
  /// discovery needs the runtime location permission (Android 11 / API ≤ 30)
  /// or only `BLUETOOTH_SCAN` (Android 12 / API 31+).
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
  /// API 31+. Android-only: the Square Flutter plugin's own
  /// `isDeviceCapable()` is iOS-only (on Android it hits `notImplemented()`
  /// and throws), so the Android capability gate is answered natively here,
  /// while iOS asks the plugin (see `SquarePaymentService.isDeviceCapable`).
  /// Returns false on non-Android platforms and on any channel error, so a
  /// missing gate never blocks the app — it just reports "not capable".
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

  /// Whether NFC is currently turned ON, as opposed to [isTapToPayCapable]
  /// which only checks the device *has* NFC hardware. Android-only (returns
  /// true on other platforms — iOS Tap to Pay has no separate "NFC toggle"
  /// the user must enable). Returns true on any channel error so a missing
  /// gate never wrongly blocks a charge that would otherwise work.
  static Future<bool> isNfcEnabled() async {
    if (!Platform.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('isNfcEnabled') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Whether Android's Developer options are switched on
  /// (`Settings.Global.DEVELOPMENT_SETTINGS_ENABLED`). Square's Tap to Pay
  /// refuses to take a card on a device with developer mode enabled — a
  /// device-integrity requirement of its contactless kernel — and reports it
  /// the same opaque way as every other missing reader prerequisite (no tap
  /// option, no catchable error). Android-only; false elsewhere and on any
  /// channel error, so a missing check only ever means "no warning shown".
  static Future<bool> isDeveloperModeEnabled() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isDeveloperModeEnabled') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the system NFC settings screen (Android only) so the user can turn
  /// NFC on. No-op on other platforms.
  static Future<void> openNfcSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openNfcSettings');
    } on PlatformException {
      // Best-effort — nothing more we can do if the settings screen itself
      // won't open.
    } on MissingPluginException {
      // Older app build without this channel method; ignore.
    }
  }

  /// The back camera's horizontal field of view in degrees, or null when the
  /// platform can't say (no camera, channel error, other platforms).
  ///
  /// Both platforms implement it: Android derives it from
  /// `CameraCharacteristics` (focal length + physical sensor size), iOS reads
  /// `AVCaptureDevice.videoFieldOfView`. AR lot mode uses it to turn QR pixel
  /// offsets into accurate bearings instead of assuming a generic FOV; when
  /// null, the assumed-FOV fallback still works, just ~±15% coarser.
  static Future<double?> cameraHorizontalFovDeg() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return null;
    }
    try {
      final fov = await _channel.invokeMethod<double>('getCameraFov');
      // Reject nonsense so a platform bug degrades to the fallback rather
      // than poisoning every bearing.
      return (fov != null && fov > 10 && fov < 160) ? fov : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The back camera's Brown-Conrady lens distortion coefficients
  /// `[k0, k1, k2, k3, k4]` (Android `CameraCharacteristics.LENS_DISTORTION`),
  /// or null when unavailable — no camera characteristic, API < 28, or a
  /// non-Android platform (iOS has no public equivalent for a live capture
  /// session; AR lot mode falls back to the undistorted pinhole model, same
  /// as it already does when [cameraHorizontalFovDeg] is null). A malformed
  /// response (wrong element count) is also treated as null so a bad reading
  /// degrades to "no correction" rather than distorting every bearing.
  static Future<List<double>?> cameraLensDistortion() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'getLensDistortion',
      );
      if (raw == null || raw.length != 5) {
        return null;
      }
      final coeffs = [for (final v in raw) (v as num?)?.toDouble()];
      return coeffs.any((v) => v == null) ? null : coeffs.cast<double>();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Hands a downloaded `.pkpass` to Apple's own "Add to Apple Wallet" sheet
  /// (`PKAddPassesViewController`). iOS only.
  ///
  /// Returns what happened, so the caller can either say something useful or
  /// fall back to opening the file with the OS:
  ///
  ///   `presented`   the Wallet sheet is up; the user finishes there
  ///   `already`     the pass is already in their Wallet
  ///   `unsupported` this device can't add passes — includes every non-iOS
  ///                 platform and an older build without the channel method
  ///   `invalid`     the bytes aren't a pass Wallet accepts
  ///
  /// Anything else should be treated as `unsupported`; the method never throws.
  static Future<String> addPassToWallet(Uint8List bytes) async {
    if (!Platform.isIOS) {
      return 'unsupported';
    }
    try {
      final result = await _channel.invokeMethod<String>('addPassToWallet', {
        'bytes': bytes,
      });
      return result ?? 'unsupported';
    } on PlatformException {
      return 'unsupported';
    } on MissingPluginException {
      return 'unsupported';
    }
  }

  /// Initializes the Square Mobile Payments SDK with [applicationId] (the
  /// deployment's Square Application ID, from `/api/mobile/config/`). Must run
  /// once before any authorize()/charge() call — the Square Flutter plugin
  /// doesn't expose initialize() on either platform, so it goes through our
  /// channel on both. iOS additionally caches the id natively so later
  /// launches can initialize inside didFinishLaunching, where Square wants it.
  ///
  /// Idempotent for the same id; throws [PlatformException] if the device was
  /// already initialized for a *different* id (switch deployments → restart)
  /// or if the SDK rejects the id. No-op on other platforms.
  static Future<void> initializeSquare(String applicationId) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    await _channel.invokeMethod<void>('initializeSquare', {
      'applicationId': applicationId,
    });
  }
}
