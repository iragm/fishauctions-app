import 'dart:math' as math;
import 'dart:ui';

import 'package:fishauctions_application/utils/ar_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const imageSize = Size(1920, 1080);
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

  group('estimateMeasurement', () {
    // A 12 mm QR two meters straight ahead of a level camera subtends
    // focal · 0.012 / 2 pixels; the estimate must invert that exactly.
    test('recovers range from apparent size', () {
      final edgePx = focal * 0.012 / 2.0;
      final m = estimateMeasurement(
        sighting: QrSighting(center: const Offset(960, 540), edgePx: edgePx),
        imageSize: imageSize,
        qrEdgeMm: 12,
        pitchDownRad: 0,
      );
      expect(m.rangeM, closeTo(2.0, 1e-6));
      expect(m.bearingDeg, closeTo(0, 1e-6));
    });

    test('recovers bearing from horizontal offset', () {
      // dx = focal ⇒ 45° to the right.
      final m = estimateMeasurement(
        sighting: QrSighting(center: Offset(960 + focal, 540), edgePx: 100),
        imageSize: imageSize,
        qrEdgeMm: 12,
        pitchDownRad: 0,
      );
      expect(m.bearingDeg, closeTo(45, 1e-6));
    });

    test('projects slant range onto the floor when pitched down', () {
      // Camera pitched 60° down, code at image center: horizontal distance
      // is slant · cos(60°) = half.
      final edgePx = focal * 0.012 / 1.0; // slant 1 m
      final level = estimateMeasurement(
        sighting: QrSighting(center: const Offset(960, 540), edgePx: edgePx),
        imageSize: imageSize,
        qrEdgeMm: 12,
        pitchDownRad: 0,
      );
      final pitched = estimateMeasurement(
        sighting: QrSighting(center: const Offset(960, 540), edgePx: edgePx),
        imageSize: imageSize,
        qrEdgeMm: 12,
        pitchDownRad: math.pi / 3,
      );
      expect(level.rangeM, closeTo(1.0, 1e-6));
      expect(pitched.rangeM, closeTo(0.5, 1e-6));
    });

    test('clamps to sane bounds', () {
      final tiny = estimateMeasurement(
        sighting: const QrSighting(center: Offset(960, 540), edgePx: 2),
        imageSize: imageSize,
        qrEdgeMm: 12,
        pitchDownRad: 0,
      );
      expect(tiny.rangeM, lessThanOrEqualTo(30));
      final huge = estimateMeasurement(
        sighting: const QrSighting(center: Offset(960, 540), edgePx: 5000),
        imageSize: imageSize,
        qrEdgeMm: 12,
        pitchDownRad: 0,
      );
      expect(huge.rangeM, greaterThanOrEqualTo(0.05));
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

  group('solvePose', () {
    /// Builds the fix a camera at ([px], [py]) with azimuth [theta] would
    /// measure for a landmark at ([lx], [ly]).
    LandmarkFix fixFor(
      double px,
      double py,
      double theta,
      double lx,
      double ly,
    ) {
      final dx = lx - px;
      final dy = ly - py;
      return LandmarkFix(
        x: lx,
        y: ly,
        rangeM: math.sqrt(dx * dx + dy * dy),
        bearingRad: -wrapRad(math.atan2(dy, dx) - theta),
      );
    }

    test('recovers the pose from two exact fixes', () {
      const px = 2.0, py = -3.0;
      const theta = math.pi / 2;
      final pose = solvePose([
        fixFor(px, py, theta, 0, 0),
        fixFor(px, py, theta, 4, 0),
      ]);
      expect(pose, isNotNull);
      expect(pose!.x, closeTo(px, 1e-3));
      expect(pose.y, closeTo(py, 1e-3));
      expect(wrapRad(pose.thetaRad - theta).abs(), lessThan(1e-3));
    });

    test('recovers the pose from three noisy fixes', () {
      const px = -1.0, py = 2.5;
      const theta = -0.7;
      final rng = math.Random(42);
      final fixes = [
        for (final (lx, ly) in const [(0.0, 0.0), (3.0, 1.0), (1.0, 4.0)])
          () {
            final f = fixFor(px, py, theta, lx, ly);
            return LandmarkFix(
              x: f.x,
              y: f.y,
              rangeM: f.rangeM * (1 + 0.05 * (rng.nextDouble() - 0.5)),
              bearingRad: f.bearingRad + 0.02 * (rng.nextDouble() - 0.5),
            );
          }(),
      ];
      final pose = solvePose(fixes);
      expect(pose, isNotNull);
      expect(pose!.x, closeTo(px, 0.3));
      expect(pose.y, closeTo(py, 0.3));
      expect(wrapRad(pose.thetaRad - theta).abs(), lessThan(0.15));
    });

    test('aim points from the solved pose to a target', () {
      const px = 2.0, py = -3.0;
      const theta = math.pi / 2; // facing +y
      final pose = solvePose([
        fixFor(px, py, theta, 0, 0),
        fixFor(px, py, theta, 4, 0),
      ]);
      // Target straight ahead at (2, 1): distance 4, dead center.
      final (bearing, distance) = pose!.aim(2, 1);
      expect(distance, closeTo(4, 1e-2));
      expect(bearing.abs(), lessThan(1e-2));
      // Target due east at (5, -3): facing +y that's 90° to the right.
      final (bearingRight, _) = pose.aim(5, -3);
      expect(bearingRight, closeTo(math.pi / 2, 1e-2));
    });

    test('needs two distinct landmarks', () {
      expect(solvePose(const []), isNull);
      expect(
        solvePose(const [
          LandmarkFix(x: 1, y: 1, rangeM: 2, bearingRad: 0),
          LandmarkFix(x: 1, y: 1, rangeM: 2.5, bearingRad: 0.3),
        ]),
        isNull,
      );
    });

    test('rejects fixes no pose can explain', () {
      // Landmarks 10 m apart but each "measured" 0.2 m away — no pose can
      // come close (stale positions / garbage fixes), so: null.
      expect(
        solvePose(const [
          LandmarkFix(x: 0, y: 0, rangeM: 0.2, bearingRad: -1.2),
          LandmarkFix(x: 10, y: 0, rangeM: 0.2, bearingRad: 1.2),
        ]),
        isNull,
      );
    });
  });
}
