import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Embeds the native AR camera passthrough — ARCore (Android) or ARKit
/// (iOS), see `ar/ArCameraPlatformView.kt` / `Ar/ArCameraPlatformView.swift`
/// — as a normal widget. Pose and QR-detection data arrive separately over
/// `ArCameraService`'s EventChannels; this widget is just the live camera
/// picture. Hybrid Composition (`AndroidView`/`UiKitView`), the same
/// embedding mechanism flutter_inappwebview already uses in this app.
class ArCameraView extends StatelessWidget {
  const ArCameraView({super.key});

  static const _viewType = 'com.fishauctions.app/ar_camera';

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return const AndroidView(
        viewType: _viewType,
        creationParamsCodec: StandardMessageCodec(),
      );
    }
    if (Platform.isIOS) {
      return const UiKitView(
        viewType: _viewType,
        creationParamsCodec: StandardMessageCodec(),
      );
    }
    return const ColoredBox(color: Colors.black);
  }
}
