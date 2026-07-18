import 'dart:math' as math;

import 'dart:ui' show Offset, Size;

/// Geometry for AR lot mode — pure functions, no platform dependencies.
///
/// Turns QR corner points from the camera image into approximate
/// `(range, bearing)` measurements for the backend's lot-position solver
/// (BACKEND_SPEC.md Part 3), and solves the phone's own 2D pose from lots
/// whose positions the solver already knows (locate mode).
///
/// Accuracy expectations, by design: the camera's focal length is estimated
/// from an assumed diagonal field of view and the printed QR edge is a nominal
/// server-tuned constant, so ranges carry a uniform scale error of ±20% or so.
/// The server's map is relative — a consistent scale error distorts nothing —
/// and locate mode only needs "about four meters, that way".

/// Assumed diagonal field of view of a phone's main camera. Real phones span
/// roughly 65–80°; the error this absorbs is a pure scale factor.
const double kAssumedDiagonalFovDeg = 70;

/// A lot QR seen in one camera frame: where in the image, and how big.
class QrSighting {
  const QrSighting({required this.center, required this.edgePx});

  /// Mean of the four corners, in image coordinates.
  final Offset center;

  /// Mean side length of the corner quad, in image pixels.
  final double edgePx;

  /// Builds a sighting from a detector's corner quad (any winding order).
  /// Returns null for degenerate quads (fewer than 4 points, or zero size).
  static QrSighting? fromCorners(List<Offset> corners) {
    if (corners.length < 4) {
      return null;
    }
    var cx = 0.0;
    var cy = 0.0;
    var edgeSum = 0.0;
    for (var i = 0; i < 4; i++) {
      cx += corners[i].dx;
      cy += corners[i].dy;
      edgeSum += (corners[(i + 1) % 4] - corners[i]).distance;
    }
    final edge = edgeSum / 4;
    if (edge <= 1) {
      return null;
    }
    return QrSighting(center: Offset(cx / 4, cy / 4), edgePx: edge);
  }
}

/// One estimated measurement: the solver-facing form of a [QrSighting].
class ArMeasurement {
  const ArMeasurement({
    required this.rangeM,
    required this.bearingDeg,
    required this.quality,
  });

  /// Horizontal (floor-plane) camera→label distance, meters.
  final double rangeM;

  /// Horizontal angle in the camera frame, positive to the right, degrees.
  final double bearingDeg;

  /// 0..1 detection confidence, from apparent size.
  final double quality;
}

/// Focal length in pixels for an image of [imageSize], from the assumed
/// diagonal FOV (orientation-independent, unlike a horizontal-FOV guess).
double focalPxFor(
  Size imageSize, {
  double diagonalFovDeg = kAssumedDiagonalFovDeg,
}) {
  final diag = math.sqrt(
    imageSize.width * imageSize.width + imageSize.height * imageSize.height,
  );
  return (diag / 2) / math.tan(diagonalFovDeg * math.pi / 360);
}

/// Estimates range and bearing to a sighted QR.
///
/// Pinhole model: the QR's apparent edge gives the slant range
/// (`focal · edge_m / edge_px`), its horizontal offset from the image center
/// gives the bearing. [pitchDownRad] is how far the camera axis points below
/// horizontal (from the gravity vector); together with the QR's vertical
/// offset it projects the slant range onto the floor plane, so looking down
/// at a nearby table label doesn't read as a longer horizontal distance.
ArMeasurement estimateMeasurement({
  required QrSighting sighting,
  required Size imageSize,
  required double qrEdgeMm,
  required double pitchDownRad,
  double diagonalFovDeg = kAssumedDiagonalFovDeg,
}) {
  final focal = focalPxFor(imageSize, diagonalFovDeg: diagonalFovDeg);
  final slantM = focal * (qrEdgeMm / 1000) / sighting.edgePx;
  final bearingRad = math.atan2(
    sighting.center.dx - imageSize.width / 2,
    focal,
  );
  // Ray depression below the camera axis (image y grows downward), plus the
  // camera's own pitch. cos() projects to the floor; clamped so a straight-down
  // or overshot pitch never yields a negative range.
  final rayDownRad =
      pitchDownRad +
      math.atan2(sighting.center.dy - imageSize.height / 2, focal);
  final horizontalM = (slantM * math.cos(rayDownRad).abs()).clamp(0.05, 30.0);
  // Bigger on-screen codes localize better; ~60 px is a comfortably sharp
  // detection at typical resolutions.
  final quality = (sighting.edgePx / 60).clamp(0.1, 1.0);
  return ArMeasurement(
    rangeM: horizontalM.toDouble(),
    bearingDeg: bearingRad * 180 / math.pi,
    quality: quality.toDouble(),
  );
}

/// Maps a point in camera-image coordinates onto the widget the preview is
/// drawn in, assuming the preview uses `BoxFit.cover` (crops overflow).
Offset mapImagePointToWidget(Offset p, Size imageSize, Size widgetSize) {
  if (imageSize.isEmpty || widgetSize.isEmpty) {
    return Offset.zero;
  }
  final scale = math.max(
    widgetSize.width / imageSize.width,
    widgetSize.height / imageSize.height,
  );
  final dx = (widgetSize.width - imageSize.width * scale) / 2;
  final dy = (widgetSize.height - imageSize.height * scale) / 2;
  return Offset(p.dx * scale + dx, p.dy * scale + dy);
}

/// Wraps an angle to (−π, π].
double wrapRad(double a) {
  var r = a % (2 * math.pi);
  if (r > math.pi) {
    r -= 2 * math.pi;
  } else if (r <= -math.pi) {
    r += 2 * math.pi;
  }
  return r;
}

/// A range-bearing fix on a landmark whose world position is known: input to
/// the locate-mode pose solve. [bearingRad] is in the *current* device frame,
/// positive to the right (older sightings are rotated forward by the
/// integrated gyro yaw before being passed here).
class LandmarkFix {
  const LandmarkFix({
    required this.x,
    required this.y,
    required this.rangeM,
    required this.bearingRad,
  });

  final double x;
  final double y;
  final double rangeM;
  final double bearingRad;
}

/// A solved device pose in the auction's map frame. [thetaRad] is the camera
/// azimuth in world coordinates (math convention, counterclockwise positive):
/// a landmark straight ahead lies at world angle θ from the device.
class PoseEstimate {
  const PoseEstimate({
    required this.x,
    required this.y,
    required this.thetaRad,
    required this.rmsResidual,
  });

  final double x;
  final double y;
  final double thetaRad;

  /// Root-mean-square residual (meters-equivalent) of the accepted solution.
  final double rmsResidual;

  /// Device-frame bearing (radians, positive right) and distance to a world
  /// point — what the guidance arrow renders.
  (double bearingRightRad, double distanceM) aim(double tx, double ty) {
    final dx = tx - x;
    final dy = ty - y;
    final worldAngle = math.atan2(dy, dx);
    // World angle relative to camera azimuth is counterclockwise-positive;
    // the UI convention (and our measurements) are positive-right.
    return (-wrapRad(worldAngle - thetaRad), math.sqrt(dx * dx + dy * dy));
  }
}

/// Solves the device's 2D pose (x, y, θ) from range-bearing fixes on known
/// landmarks. Needs fixes on at least two distinct landmarks; returns null
/// when there are too few, the solve doesn't converge, or the best solution
/// explains the measurements poorly (bad fixes, moved lots).
///
/// Tiny Gauss–Newton with multi-start: the problem is 3 unknowns and a
/// handful of measurements, so brute-forcing 8 initial headings around the
/// first landmark and keeping the best converged solution is cheap and avoids
/// the local minima a single seed can fall into.
PoseEstimate? solvePose(List<LandmarkFix> fixes) {
  final distinct = <String>{
    for (final f in fixes)
      '${f.x.toStringAsFixed(2)},${f.y.toStringAsFixed(2)}',
  };
  if (fixes.length < 2 || distinct.length < 2) {
    return null;
  }

  PoseEstimate? best;
  final anchor = fixes.first;
  for (var k = 0; k < 8; k++) {
    final a = k * math.pi / 4;
    // Candidate camera position: on the circle of the first fix's range.
    var px = anchor.x + anchor.rangeM * math.cos(a);
    var py = anchor.y + anchor.rangeM * math.sin(a);
    // Heading that makes the first landmark appear at its measured bearing
    // (measurement is positive-right, world angles counterclockwise).
    var theta = wrapRad(
      math.atan2(anchor.y - py, anchor.x - px) + anchor.bearingRad,
    );

    var converged = false;
    for (var iter = 0; iter < 20; iter++) {
      // Normal equations J^T J Δ = −J^T r for residuals
      //   r1 = predictedRange − measuredRange
      //   r2 = wrap(predictedBearing − measuredBearing) · measuredRange
      var h00 = 0.0, h01 = 0.0, h02 = 0.0;
      var h11 = 0.0, h12 = 0.0, h22 = 0.0;
      var g0 = 0.0, g1 = 0.0, g2 = 0.0;
      for (final f in fixes) {
        final dx = f.x - px;
        final dy = f.y - py;
        final r = math.sqrt(dx * dx + dy * dy).clamp(1e-3, double.infinity);
        // Range residual and its gradient wrt (px, py, θ).
        final rr = r - f.rangeM;
        final j0 = -dx / r, j1 = -dy / r;
        h00 += j0 * j0;
        h01 += j0 * j1;
        h11 += j1 * j1;
        g0 += j0 * rr;
        g1 += j1 * rr;
        // Bearing residual, scaled by range so both rows are ~meters. The
        // measured bearing is positive-right; negate into ccw convention.
        final rb =
            wrapRad(math.atan2(dy, dx) - theta + f.bearingRad) * f.rangeM;
        final b0 = (dy / (r * r)) * f.rangeM;
        final b1 = (-dx / (r * r)) * f.rangeM;
        final b2 = -f.rangeM;
        h00 += b0 * b0;
        h01 += b0 * b1;
        h02 += b0 * b2;
        h11 += b1 * b1;
        h12 += b1 * b2;
        h22 += b2 * b2;
        g0 += b0 * rb;
        g1 += b1 * rb;
        g2 += b2 * rb;
      }
      // Levenberg damping keeps the 3×3 solvable when fixes are nearly
      // collinear (all labels on one table edge).
      const lm = 1e-6;
      h00 += lm;
      h11 += lm;
      h22 += lm;
      final det =
          h00 * (h11 * h22 - h12 * h12) -
          h01 * (h01 * h22 - h12 * h02) +
          h02 * (h01 * h12 - h11 * h02);
      if (det.abs() < 1e-12) {
        break;
      }
      final d0 =
          (-g0 * (h11 * h22 - h12 * h12) -
              h01 * (-g1 * h22 - h12 * -g2) +
              h02 * (-g1 * h12 - h11 * -g2)) /
          det;
      final d1 =
          (h00 * (-g1 * h22 - h12 * -g2) -
              -g0 * (h01 * h22 - h12 * h02) +
              h02 * (h01 * -g2 - -g1 * h02)) /
          det;
      final d2 =
          (h00 * (h11 * -g2 - -g1 * h12) -
              h01 * (h01 * -g2 - -g1 * h02) +
              -g0 * (h01 * h12 - h11 * h02)) /
          det;
      px += d0;
      py += d1;
      theta = wrapRad(theta + d2);
      if (d0.abs() + d1.abs() + d2.abs() < 1e-4) {
        converged = true;
        break;
      }
    }
    if (!converged) {
      continue;
    }
    // Score the converged candidate by RMS residual.
    var sq = 0.0;
    for (final f in fixes) {
      final dx = f.x - px;
      final dy = f.y - py;
      final r = math.sqrt(dx * dx + dy * dy);
      final rb = wrapRad(math.atan2(dy, dx) - theta + f.bearingRad) * f.rangeM;
      sq += (r - f.rangeM) * (r - f.rangeM) + rb * rb;
    }
    final rms = math.sqrt(sq / (fixes.length * 2));
    if (best == null || rms < best.rmsResidual) {
      best = PoseEstimate(x: px, y: py, thetaRad: theta, rmsResidual: rms);
    }
  }
  if (best == null) {
    return null;
  }
  // Reject fits that don't actually explain the measurements — stale
  // positions (the lot moved) or garbage fixes. Threshold loose on purpose:
  // ranges are ±20% by construction.
  final meanRange =
      fixes.fold<double>(0, (s, f) => s + f.rangeM) / fixes.length;
  return best.rmsResidual <= math.max(0.75, 0.35 * meanRange) ? best : null;
}
