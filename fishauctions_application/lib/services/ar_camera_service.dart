import 'package:flutter/services.dart';

import '../models/ar_camera_event.dart';

/// Streams from the native AR camera pipeline (`ar/ArSessionManager.kt` +
/// `ar/ArCameraPlatformView.kt` on Android, `Ar/ArCameraPlatformView.swift`
/// on iOS) that backs the `ArCameraView` platform view: ARCore/ARKit owns
/// the camera for visual-inertial pose tracking and feeds ML Kit/Vision for
/// QR detection, replacing the mobile_scanner/pedometer pipeline this screen
/// used to use.
class ArCameraService {
  ArCameraService._();
  static final ArCameraService instance = ArCameraService._();

  static const _poseChannel = EventChannel('com.fishauctions.app/ar_pose');
  static const _detectionChannel = EventChannel(
    'com.fishauctions.app/ar_detections',
  );

  /// Pose updates and session status changes, interleaved on one stream (the
  /// native side emits both through the same channel, discriminated by a
  /// `type` field) in the order they occurred.
  Stream<ArCameraEvent> poseEvents() =>
      _poseChannel.receiveBroadcastStream().map(_parsePoseEvent);

  Stream<ArDetectionBatch> detectionEvents() =>
      _detectionChannel.receiveBroadcastStream().map(_parseDetectionBatch);

  static ArCameraEvent _parsePoseEvent(dynamic raw) {
    final map = Map<Object?, Object?>.from(raw as Map);
    if (map['type'] == 'status') {
      return ArStatusUpdate(
        status: map['status'] as String? ?? 'error',
        message: map['message'] as String?,
      );
    }
    return ArPoseUpdate(
      tracking: map['tracking'] as bool? ?? false,
      px: (map['px'] as num?)?.toDouble() ?? 0,
      pz: (map['pz'] as num?)?.toDouble() ?? 0,
      fx: (map['fx'] as num?)?.toDouble() ?? 0,
      fz: (map['fz'] as num?)?.toDouble() ?? 0,
    );
  }

  static ArDetectionBatch _parseDetectionBatch(dynamic raw) {
    final map = Map<Object?, Object?>.from(raw as Map);
    final width = (map['imageWidth'] as num?)?.toDouble() ?? 0;
    final height = (map['imageHeight'] as num?)?.toDouble() ?? 0;
    final rawBarcodes = map['barcodes'] as List<Object?>? ?? const [];
    final barcodes = <ArDetectedBarcode>[
      for (final entry in rawBarcodes) ?_parseBarcode(entry),
    ];
    return ArDetectionBatch(imageSize: Size(width, height), barcodes: barcodes);
  }

  static ArDetectedBarcode? _parseBarcode(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final rawValue = raw['rawValue'] as String?;
    final rawCorners = raw['corners'] as List<Object?>?;
    if (rawCorners == null || rawCorners.length != 4) {
      return null;
    }
    final corners = <Offset>[];
    for (final c in rawCorners) {
      if (c is! List || c.length != 2) {
        return null;
      }
      corners.add(Offset((c[0] as num).toDouble(), (c[1] as num).toDouble()));
    }
    return ArDetectedBarcode(rawValue: rawValue, corners: corners);
  }
}
