import 'dart:ui';

/// Events from the native AR camera pipeline's pose channel
/// (`com.fishauctions.app/ar_pose` — ArSessionManager.kt / ArCameraPlatformView.swift).
sealed class ArCameraEvent {
  const ArCameraEvent();
}

/// One tracked camera pose. [tracking] false means the pose is unreliable
/// right now (lost tracking, relocalizing) — callers should hold their last
/// known odometry/yaw rather than jump to a stale/garbage value, exactly
/// like a momentarily-missing gyro/magnetometer reading elsewhere in this
/// session already does. [px]/[pz]/[fx]/[fz] feed `arPoseToYawAndOdometry`
/// (ar_geometry.dart) directly — see that function for the coordinate
/// convention.
class ArPoseUpdate extends ArCameraEvent {
  const ArPoseUpdate({
    required this.tracking,
    required this.px,
    required this.pz,
    required this.fx,
    required this.fz,
  });

  final bool tracking;
  final double px;
  final double pz;
  final double fx;
  final double fz;
}

/// The AR session's lifecycle status: `checking` | `unsupported` |
/// `installing` | `ready` | `error`. Drives the screen's camera-vs-explainer
/// state the same way camera-permission status already does.
class ArStatusUpdate extends ArCameraEvent {
  const ArStatusUpdate({required this.status, this.message});

  final String status;
  final String? message;
}

/// One detected QR label from the native AR camera pipeline's detection
/// channel (`com.fishauctions.app/ar_detections`).
class ArDetectedBarcode {
  const ArDetectedBarcode({required this.rawValue, required this.corners});

  final String? rawValue;

  /// Four corner points in image pixel coordinates, top-left origin —
  /// matching mobile_scanner's convention (this pipeline replaces it), so
  /// `QrSighting.fromCorners` needs no changes.
  final List<Offset> corners;
}

/// One detection pass's worth of barcodes, alongside the pixel dimensions
/// they're relative to.
class ArDetectionBatch {
  const ArDetectionBatch({required this.imageSize, required this.barcodes});

  final Size imageSize;
  final List<ArDetectedBarcode> barcodes;
}
