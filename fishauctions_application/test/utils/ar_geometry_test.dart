import 'dart:math' as math;
import 'dart:ui';

import 'package:fishauctions_application/utils/ar_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const imageSize = Size(2560, 1440);
  final focal = focalPxFor(imageSize);

  group('QrSighting.fromCorners', () {
    test('computes center and mean edge of a square quad', () {
      final s = QrSighting.fromCorners(const [
        Offset(100, 100),
        Offset(200, 100),
        Offset(200, 200),
        Offset(100, 200),
      ]);
      expect(s, isNotNull);
      expect(s!.center, const Offset(150, 150));
      expect(s.edgePx, 100);
    });

    test('rejects degenerate quads', () {
      expect(QrSighting.fromCorners(const [Offset(1, 1)]), isNull);
      expect(
        QrSighting.fromCorners(const [
          Offset(1, 1),
          Offset(1, 1),
          Offset(1, 1),
          Offset(1, 1),
        ]),
        isNull,
      );
    });
  });

  group('focalPxFor', () {
    test('uses the device horizontal FOV against the long image side', () {
      // 60° across 2560 px ⇒ focal = 1280 / tan 30°.
      expect(
        focalPxFor(imageSize, deviceHFovDeg: 60),
        closeTo(1280 / math.tan(math.pi / 6), 1e-6),
      );
      // Portrait-orientation size must give the same focal.
      expect(
        focalPxFor(const Size(1440, 2560), deviceHFovDeg: 60),
        closeTo(focalPxFor(imageSize, deviceHFovDeg: 60), 1e-9),
      );
    });

    test('falls back to the assumed diagonal FOV', () {
      final diag = math.sqrt(2560 * 2560 + 1440 * 1440);
      expect(
        focalPxFor(imageSize),
        closeTo((diag / 2) / math.tan(35 * math.pi / 180), 1e-6),
      );
      // Nonsense device values are ignored, not trusted.
      expect(focalPxFor(imageSize, deviceHFovDeg: 5), focalPxFor(imageSize));
    });
  });

  group('estimateMeasurement', () {
    test('recovers bearing from horizontal offset', () {
      // dx = focal ⇒ 45° to the right.
      final m = estimateMeasurement(
        sighting: QrSighting(center: Offset(1280 + focal, 720), edgePx: 100),
        imageSize: imageSize,
        pitchDownRad: 0,
      );
      expect(m.bearingDeg, closeTo(45, 1e-6));
      expect(m.depressionDeg, closeTo(0, 1e-6));
    });

    test('depression combines camera pitch and pixel offset', () {
      // Level camera, code half a focal length below center ⇒ atan(0.5).
      final byPixel = estimateMeasurement(
        sighting: QrSighting(center: Offset(1280, 720 + focal / 2), edgePx: 80),
        imageSize: imageSize,
        pitchDownRad: 0,
      );
      expect(
        byPixel.depressionDeg,
        closeTo(math.atan(0.5) * 180 / math.pi, 1e-6),
      );
      // Camera pitched 30° down, code at center ⇒ 30°.
      final byPitch = estimateMeasurement(
        sighting: const QrSighting(center: Offset(1280, 720), edgePx: 80),
        imageSize: imageSize,
        pitchDownRad: math.pi / 6,
      );
      expect(byPitch.depressionDeg, closeTo(30, 1e-6));
    });

    test('honors the device FOV for bearings', () {
      final f = focalPxFor(imageSize, deviceHFovDeg: 60);
      final m = estimateMeasurement(
        sighting: QrSighting(center: Offset(1280 + f, 720), edgePx: 100),
        imageSize: imageSize,
        pitchDownRad: 0,
        deviceHFovDeg: 60,
      );
      expect(m.bearingDeg, closeTo(45, 1e-6));
    });

    test('quality scales with apparent sharpness, clamped', () {
      ArMeasurement at(double edgePx) => estimateMeasurement(
        sighting: QrSighting(center: const Offset(1280, 720), edgePx: edgePx),
        imageSize: imageSize,
        pitchDownRad: 0,
      );
      expect(at(6).quality, 0.1);
      expect(at(30).quality, closeTo(0.5, 1e-9));
      expect(at(500).quality, 1.0);
    });
  });

  group('mapImagePointToWidget', () {
    test('maps through BoxFit.cover scaling and cropping', () {
      // 200×100 image covering a 100×100 widget: scale 1, x cropped 50 px
      // each side.
      expect(
        mapImagePointToWidget(
          const Offset(100, 50),
          const Size(200, 100),
          const Size(100, 100),
        ),
        const Offset(50, 50),
      );
      // 100×100 image covering 200×100: scale 2, y overflow cropped.
      expect(
        mapImagePointToWidget(
          const Offset(50, 50),
          const Size(100, 100),
          const Size(200, 100),
        ),
        const Offset(100, 50),
      );
    });
  });

  group('wrapRad', () {
    test('wraps into (−π, π]', () {
      expect(wrapRad(0), 0);
      expect(wrapRad(math.pi), closeTo(math.pi, 1e-9));
      expect(wrapRad(-math.pi), closeTo(math.pi, 1e-9));
      expect(wrapRad(3 * math.pi), closeTo(math.pi, 1e-9));
      expect(wrapRad(math.pi + 0.1), closeTo(-math.pi + 0.1, 1e-9));
      expect(wrapRad(-5 * math.pi / 2), closeTo(-math.pi / 2, 1e-9));
    });
  });

  group('solvePose (bearing-only resection)', () {
    /// The fix a camera at ([px], [py]) with azimuth [theta] would measure
    /// for a landmark at ([lx], [ly]).
    LandmarkFix fixFor(
      double px,
      double py,
      double theta,
      double lx,
      double ly,
    ) => LandmarkFix(
      x: lx,
      y: ly,
      bearingRad: -wrapRad(math.atan2(ly - py, lx - px) - theta),
    );

    test('recovers the pose from three exact fixes', () {
      const px = 2.0, py = -3.0;
      const theta = math.pi / 2;
      final pose = solvePose([
        fixFor(px, py, theta, 0, 0),
        fixFor(px, py, theta, 4, 0),
        fixFor(px, py, theta, 1, 3),
      ]);
      expect(pose, isNotNull);
      expect(pose!.x, closeTo(px, 1e-3));
      expect(pose.y, closeTo(py, 1e-3));
      expect(wrapRad(pose.thetaRad - theta).abs(), lessThan(1e-3));
    });

    test('recovers the pose from noisy fixes', () {
      const px = -1.0, py = 2.5;
      const theta = -0.7;
      final rng = math.Random(42);
      final fixes = [
        for (final (lx, ly) in const [
          (0.0, 0.0),
          (3.0, 1.0),
          (1.0, 4.0),
          (4.0, 4.0),
        ])
          () {
            final f = fixFor(px, py, theta, lx, ly);
            return LandmarkFix(
              x: f.x,
              y: f.y,
              // ±0.5° of bearing noise — about what corner centroids give.
              bearingRad: f.bearingRad + 0.017 * (rng.nextDouble() - 0.5),
            );
          }(),
      ];
      final pose = solvePose(fixes);
      expect(pose, isNotNull);
      expect(pose!.x, closeTo(px, 0.25));
      expect(pose.y, closeTo(py, 0.25));
      expect(wrapRad(pose.thetaRad - theta).abs(), lessThan(0.1));
    });

    test('aim points from the solved pose to a target', () {
      const px = 2.0, py = -3.0;
      const theta = math.pi / 2; // facing +y
      final pose = solvePose([
        fixFor(px, py, theta, 0, 0),
        fixFor(px, py, theta, 4, 0),
        fixFor(px, py, theta, 1, 3),
      ]);
      // Target straight ahead at (2, 1): distance 4, dead center.
      final (bearing, distance) = pose!.aim(2, 1);
      expect(distance, closeTo(4, 1e-2));
      expect(bearing.abs(), lessThan(1e-2));
      // Target due east at (5, -3): facing +y that's 90° to the right.
      final (bearingRight, _) = pose.aim(5, -3);
      expect(bearingRight, closeTo(math.pi / 2, 1e-2));
    });

    test('needs three distinct landmarks', () {
      expect(solvePose(const []), isNull);
      expect(
        solvePose(const [
          LandmarkFix(x: 0, y: 0, bearingRad: -0.4),
          LandmarkFix(x: 4, y: 0, bearingRad: 0.4),
        ]),
        isNull,
      );
      expect(
        solvePose(const [
          LandmarkFix(x: 1, y: 1, bearingRad: 0),
          LandmarkFix(x: 1, y: 1, bearingRad: 0.1),
          LandmarkFix(x: 1, y: 1, bearingRad: 0.2),
        ]),
        isNull,
      );
    });

    test('rejects a narrow angular spread (depth unobservable)', () {
      // All three landmarks nearly dead ahead — bearings within ~6°.
      expect(
        solvePose(const [
          LandmarkFix(x: 100, y: 0, bearingRad: 0),
          LandmarkFix(x: 100, y: 5, bearingRad: -0.05),
          LandmarkFix(x: 100, y: -5, bearingRad: 0.05),
        ]),
        isNull,
      );
    });

    test('rejects bearings no nearby pose can explain', () {
      // A tight triangle of landmarks all "seen" in the same direction —
      // only an absurdly distant camera could do that, which the
      // far-solution guard throws out.
      expect(
        solvePose(const [
          LandmarkFix(x: 0, y: 0, bearingRad: -0.4),
          LandmarkFix(x: 4, y: 0, bearingRad: -0.1),
          LandmarkFix(x: 0, y: 4, bearingRad: 0.4),
        ]),
        isNull,
      );
    });
  });

  group('fitMapToImage', () {
    test('affine from three pairs projects a fourth point exactly', () {
      // Ground truth: rotate 30°, scale 40, translate (300, 200).
      Offset truth(Offset m) {
        const c = 0.8660254037844387; // cos 30°
        const s = 0.5;
        return Offset(
          40 * (c * m.dx - s * m.dy) + 300,
          40 * (s * m.dx + c * m.dy) + 200,
        );
      }

      const points = [Offset.zero, Offset(4, 0), Offset(1, 3)];
      final t = fitMapToImage([for (final p in points) (p, truth(p))]);
      expect(t, isNotNull);
      const probe = Offset(2.5, 1.5);
      final projected = t!.project(probe);
      expect(projected, isNotNull);
      expect((projected! - truth(probe)).distance, lessThan(1e-6));
    });

    test('homography from four pairs reproduces perspective', () {
      // Mild perspective, like a table viewed from standing height.
      const h = [1.0, 0.1, 50.0, 0.05, 1.2, 30.0, 0.02, 0.01, 1.0];
      Offset truth(Offset m) {
        final w = h[6] * m.dx + h[7] * m.dy + h[8];
        return Offset(
          (h[0] * m.dx + h[1] * m.dy + h[2]) / w,
          (h[3] * m.dx + h[4] * m.dy + h[5]) / w,
        );
      }

      const points = [
        Offset.zero,
        Offset(6, 0),
        Offset(0, 5),
        Offset(6, 5),
        Offset(3, 2),
      ];
      final t = fitMapToImage([for (final p in points) (p, truth(p))]);
      expect(t, isNotNull);
      const probe = Offset(4.5, 3.5);
      final projected = t!.project(probe);
      expect(projected, isNotNull);
      expect((projected! - truth(probe)).distance, lessThan(1e-3));
    });

    test('rejects too few or collinear anchors', () {
      expect(
        fitMapToImage(const [
          (Offset.zero, Offset(10, 10)),
          (Offset(1, 0), Offset(50, 10)),
        ]),
        isNull,
      );
      expect(
        fitMapToImage(const [
          (Offset.zero, Offset(10, 10)),
          (Offset(1, 0), Offset(50, 10)),
          (Offset(2, 0), Offset(90, 10)),
        ]),
        isNull,
      );
    });

    test('rejects anchors that contradict each other', () {
      // Four consistent pairs plus one wildly wrong one: the LS fit can't
      // reproduce its own anchors, so it must refuse rather than pin a
      // ghost marker somewhere confident and wrong.
      Offset truth(Offset m) => Offset(40 * m.dx + 100, 40 * m.dy + 100);
      const good = [Offset.zero, Offset(5, 0), Offset(0, 5), Offset(5, 5)];
      final pairs = [
        for (final p in good) (p, truth(p)),
        (const Offset(2, 2), const Offset(1500, -900)),
      ];
      expect(fitMapToImage(pairs), isNull);
    });
  });
}
