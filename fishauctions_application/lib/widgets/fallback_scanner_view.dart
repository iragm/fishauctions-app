import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/ar_camera_event.dart';

/// Lot scanning's camera on a phone that can't run AR: a plain camera with
/// the platform's QR reader (CameraX + ML Kit on Android), producing the same
/// [ArDetectionBatch]es the AR camera does so the screen treats both alike.
///
/// It exists because ARCore certifies phones model by model and current
/// budget phones miss out — the Galaxy A15 and A16 can't install Google Play
/// Services for AR at all — and lot scanning used to be a dead end there,
/// though reading a label needs no tracking. What these phones go without is
/// motion tracking only: chips, the lot card and watching all work, and
/// "Find this lot" works while three mapped labels are on screen.
///
/// Mounted only once the AR session has reported `unsupported`, so the two
/// never contend for the camera.
class FallbackScannerView extends StatefulWidget {
  const FallbackScannerView({required this.onDetections, super.key});

  final void Function(ArDetectionBatch batch) onDetections;

  @override
  State<FallbackScannerView> createState() => _FallbackScannerViewState();
}

class _FallbackScannerViewState extends State<FallbackScannerView> {
  // ~10 reads a second, the AR camera's rate. 1280x720 rather than the
  // plugin's default analysis size so a label reads from as far away as it
  // does through ARCore (see ArSessionManager.selectCpuImageCameraConfig).
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionTimeoutMs: 100,
    cameraResolution: const Size(1280, 720),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => MobileScanner(
      controller: _controller,
      onDetect: (capture) =>
          widget.onDetections(toDetectionBatch(capture, constraints.biggest)),
      errorBuilder: (context, error) => _CameraError(error: error),
    ),
  );
}

/// [capture] as the AR camera would have reported it.
///
/// The plugin reports the frame's size as portrait however the phone is held
/// (it decides from the sensor's fixed mounting angle), while ML Kit's corners
/// are in the upright frame. The screen's own shape says which way up that
/// is, so the size is turned to match it — otherwise every chip lands
/// transposed in landscape.
@visibleForTesting
ArDetectionBatch toDetectionBatch(BarcodeCapture capture, Size widgetSize) {
  final reported = capture.size;
  final portraitUi = widgetSize.height >= widgetSize.width;
  final portraitImage = reported.height >= reported.width;
  final imageSize = portraitUi == portraitImage
      ? reported
      : Size(reported.height, reported.width);
  return ArDetectionBatch(
    imageSize: imageSize,
    barcodes: [
      for (final barcode in capture.barcodes)
        if (barcode.corners.length == 4)
          ArDetectedBarcode(
            rawValue: barcode.rawValue,
            corners: barcode.corners,
          ),
    ],
  );
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          error.errorCode == MobileScannerErrorCode.permissionDenied
              ? 'Camera access is turned off for this app. Enable it in '
                    'system settings to scan lots.'
              : 'Lot scanning couldn\'t start the camera. Go back and try '
                    'again.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    ),
  );
}
