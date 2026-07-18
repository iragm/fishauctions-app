import 'dart:math' as math;

import 'dart:ui' show Offset, Size;

/// Geometry for AR lot mode — pure functions, no platform dependencies.
///
/// Turns QR corner points from the camera image into **angle-only**
/// measurements for the backend's lot-position solver (BACKEND_SPEC.md
/// Part 3), and localizes on-device for locate mode.
///
/// Deliberately, *nothing* here depends on the printed size of the QR code.
/// People print on arbitrary label sizes, so apparent-size ranging is a trap;
/// the two measurements used instead are size-independent:
///
///  * **bearing** — horizontal angle of the code in the camera frame, from
///    its pixel offset against the focal length. Corner centroids are good to
///    a pixel or two, so bearings are accurate to ~0.1°.
///  * **depression** — how far below horizontal the ray to the code points,
///    from the same offset plus the gravity vector. The server turns this
///    into a weak range prior via a phone-height model; on-device it's
///    unused.
///
/// The focal length comes from the device's reported camera FOV when
/// available (PlatformBridge.cameraHorizontalFovDeg) and falls back to an
/// assumed diagonal FOV. Focal error shifts bearings proportionally — a
/// benign, self-consistent distortion — unlike size-based ranging where it
/// was a direct range error.

/// Assumed diagonal field of view when the device won't say. Real phone main
/// cameras span roughly 65–80°.
const double kAssumedDiagonalFovDeg = 70;

/// A lot QR seen in one camera frame: where in the image, and how big.
class QrSighting {
  const QrSighting({required this.center, required this.edgePx});

  /// Mean of the four corners, in image coordinates.
  final Offset center;

  /// Mean side length of the corner quad, in image pixels. Only used as a
  /// detection-sharpness proxy (quality weight) — never as a range.
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

/// One angle-only measurement: the solver-facing form of a [QrSighting].
class ArMeasurement {
  const ArMeasurement({
    required this.bearingDeg,
    required this.depressionDeg,
    required this.quality,
  });

  /// Horizontal angle in the camera frame, positive to the right, degrees.
  final double bearingDeg;

  /// Angle of the ray below horizontal (gravity-referenced), degrees.
  /// Positive looking down at a label, ~0 looking across the room.
  final double depressionDeg;

  /// 0..1 detection confidence, from apparent sharpness.
  final double quality;
}

/// Focal length in pixels for an image of [imageSize].
///
/// With [deviceHFovDeg] (the camera's reported horizontal FOV, which spans
/// the sensor's long axis) the focal is essentially exact; without it, an
/// assumed diagonal FOV gets within ~±15%, which only scales bearings
/// self-consistently.
double focalPxFor(
  Size imageSize, {
  double? deviceHFovDeg,
  double assumedDiagonalFovDeg = kAssumedDiagonalFovDeg,
}) {
  if (deviceHFovDeg != null && deviceHFovDeg > 10 && deviceHFovDeg < 160) {
    final longSide = math.max(imageSize.width, imageSize.height);
    return (longSide / 2) / math.tan(deviceHFovDeg * math.pi / 360);
  }
  final diag = math.sqrt(
    imageSize.width * imageSize.width + imageSize.height * imageSize.height,
  );
  return (diag / 2) / math.tan(assumedDiagonalFovDeg * math.pi / 360);
}

/// Estimates bearing and depression to a sighted QR. [pitchDownRad] is how
/// far the camera axis points below horizontal (from the gravity vector).
ArMeasurement estimateMeasurement({
  required QrSighting sighting,
  required Size imageSize,
  required double pitchDownRad,
  double? deviceHFovDeg,
}) {
  final focal = focalPxFor(imageSize, deviceHFovDeg: deviceHFovDeg);
  final bearingRad = math.atan2(
    sighting.center.dx - imageSize.width / 2,
    focal,
  );
  // Ray depression below the camera axis (image y grows downward), plus the
  // camera's own pitch.
  final depressionRad =
      (pitchDownRad +
              math.atan2(sighting.center.dy - imageSize.height / 2, focal))
          .clamp(-math.pi / 2, math.pi / 2);
  // Bigger on-screen codes localize better; ~60 px is a comfortably sharp
  // detection at typical resolutions.
  final quality = (sighting.edgePx / 60).clamp(0.1, 1.0);
  return ArMeasurement(
    bearingDeg: bearingRad * 180 / math.pi,
    depressionDeg: depressionRad * 180 / math.pi,
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

/// A bearing fix on a landmark whose world position is known: input to the
/// locate-mode resection. [bearingRad] is in the *current* device frame,
/// positive to the right (older sightings are rotated forward by the
/// integrated gyro yaw before being passed here). No range — see the library
/// doc.
class LandmarkFix {
  const LandmarkFix({
    required this.x,
    required this.y,
    required this.bearingRad,
  });

  final double x;
  final double y;
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

  /// Root-mean-square bearing residual (radians) of the accepted solution.
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

/// Solves the device's 2D pose (x, y, θ) by **bearing-only resection** from
/// fixes on known landmarks. Needs ≥3 distinct landmarks with reasonable
/// angular spread — with bearings alone, two landmarks leave a
/// one-parameter family of poses, and a narrow spread leaves depth
/// ill-conditioned. Returns null when under-determined, unconverged, or the
/// best solution explains the bearings poorly (stale positions, garbage
/// fixes).
///
/// Tiny Gauss–Newton with multi-start around the landmark cluster: 3
/// unknowns, a handful of measurements — brute force is cheap and dodges
/// local minima.
PoseEstimate? solvePose(List<LandmarkFix> fixes) {
  final distinct = <String>{
    for (final f in fixes)
      '${f.x.toStringAsFixed(2)},${f.y.toStringAsFixed(2)}',
  };
  if (fixes.length < 3 || distinct.length < 3) {
    return null;
  }
  // Angular-spread guard: all bearings within ~15° of each other means the
  // camera-to-cluster distance is nearly unobservable.
  var spread = 0.0;
  for (final a in fixes) {
    for (final b in fixes) {
      spread = math.max(spread, wrapRad(a.bearingRad - b.bearingRad).abs());
    }
  }
  if (spread < 0.26) {
    return null;
  }

  // Landmark centroid + extent scale the multi-start candidate ring.
  var cx = 0.0;
  var cy = 0.0;
  for (final f in fixes) {
    cx += f.x;
    cy += f.y;
  }
  cx /= fixes.length;
  cy /= fixes.length;
  var extent = 0.0;
  for (final f in fixes) {
    extent = math.max(
      extent,
      math.sqrt((f.x - cx) * (f.x - cx) + (f.y - cy) * (f.y - cy)),
    );
  }
  final s = math.max<double>(1, extent);

  PoseEstimate? best;
  final anchor = fixes.first;
  for (final radius in [0.7 * s, 1.5 * s, 3 * s, 6 * s]) {
    for (var k = 0; k < 8; k++) {
      final a = k * math.pi / 4;
      var px = cx + radius * math.cos(a);
      var py = cy + radius * math.sin(a);
      // Heading that puts the first landmark at its measured bearing
      // (measurement is positive-right, world angles counterclockwise).
      var theta = wrapRad(
        math.atan2(anchor.y - py, anchor.x - px) + anchor.bearingRad,
      );

      var converged = false;
      for (var iter = 0; iter < 25; iter++) {
        // Normal equations J^T J Δ = −J^T r for the bearing residuals
        //   r = wrap(predictedBearing_ccw − measuredBearing_ccw)  [radians]
        var h00 = 0.0, h01 = 0.0, h02 = 0.0;
        var h11 = 0.0, h12 = 0.0, h22 = 0.0;
        var g0 = 0.0, g1 = 0.0, g2 = 0.0;
        for (final f in fixes) {
          final dx = f.x - px;
          final dy = f.y - py;
          final r2 = math.max(1e-6, dx * dx + dy * dy);
          final rb = wrapRad(math.atan2(dy, dx) - theta + f.bearingRad);
          final b0 = dy / r2;
          final b1 = -dx / r2;
          const b2 = -1.0;
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
        // Levenberg damping keeps the 3×3 solvable near degeneracy (poses
        // close to the circle through the landmarks).
        const lm = 1e-9;
        h00 += lm;
        h11 += lm;
        h22 += lm;
        final det =
            h00 * (h11 * h22 - h12 * h12) -
            h01 * (h01 * h22 - h12 * h02) +
            h02 * (h01 * h12 - h11 * h02);
        if (det.abs() < 1e-15) {
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
        if (d0.abs() + d1.abs() + d2.abs() < 1e-5) {
          converged = true;
          break;
        }
      }
      if (!converged) {
        continue;
      }
      var sq = 0.0;
      for (final f in fixes) {
        final rb = wrapRad(
          math.atan2(f.y - py, f.x - px) - theta + f.bearingRad,
        );
        sq += rb * rb;
      }
      final rms = math.sqrt(sq / fixes.length);
      if (best == null || rms < best.rmsResidual) {
        best = PoseEstimate(x: px, y: py, thetaRad: theta, rmsResidual: rms);
      }
    }
  }
  if (best == null) {
    return null;
  }
  // Sanity: the bearings must actually be explained (~2° RMS), and a "fit"
  // parked absurdly far from the cluster is the ill-conditioned tail, not a
  // pose.
  final far = math.sqrt(
    (best.x - cx) * (best.x - cx) + (best.y - cy) * (best.y - cy),
  );
  if (best.rmsResidual > 0.035 || far > 12 * s) {
    return null;
  }
  return best;
}

/// A fitted map→screen transform for the locate-mode ghost marker: given
/// where mapped lots appear on screen right now, projects any other map
/// point into screen coordinates — the target lot gets pinned relative to
/// its visible neighbors with no pose solve and no ranges at all.
class MapImageTransform {
  const MapImageTransform._(this._h);

  /// Row-major 3×3 homography (affine fits leave the bottom row 0 0 1).
  final List<double> _h;

  /// Projects a map point to screen coordinates; null when it lands behind
  /// the camera (degenerate homography side).
  Offset? project(Offset map) {
    final w = _h[6] * map.dx + _h[7] * map.dy + _h[8];
    if (w.abs() < 1e-9 || w <= 0) {
      return null;
    }
    return Offset(
      (_h[0] * map.dx + _h[1] * map.dy + _h[2]) / w,
      (_h[3] * map.dx + _h[4] * map.dy + _h[5]) / w,
    );
  }
}

/// Fits the map→screen transform from (map position, screen position) pairs
/// of currently visible mapped lots.
///
///  * ≥4 pairs — full homography (labels sit near one plane, so this is the
///    exact camera model), via normalized DLT.
///  * exactly 3 — affine (no perspective, fine for compact clusters).
///  * fewer, near-collinear layouts, or a poor fit — null; with 2 points a
///    reflection ambiguity (which side of the table?) makes any answer a
///    coin flip, so the caller falls back to the compass arrow.
MapImageTransform? fitMapToImage(List<(Offset, Offset)> pairs) {
  if (pairs.length < 3) {
    return null;
  }
  // Collinearity guard on the map side: max triangle area among point
  // triples must be meaningful relative to the spread.
  var spread = 0.0;
  var maxArea = 0.0;
  for (var i = 0; i < pairs.length; i++) {
    for (var j = i + 1; j < pairs.length; j++) {
      spread = math.max(spread, (pairs[i].$1 - pairs[j].$1).distance);
      for (var k = j + 1; k < pairs.length; k++) {
        final a = pairs[i].$1;
        final b = pairs[j].$1;
        final c = pairs[k].$1;
        maxArea = math.max(
          maxArea,
          ((b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx))
                  .abs() /
              2,
        );
      }
    }
  }
  if (spread < 1e-6 || maxArea < 0.05 * spread * spread) {
    return null;
  }

  final h = pairs.length >= 4 ? _fitHomography(pairs) : null;
  final result = h ?? _fitAffine(pairs);
  if (result == null) {
    return null;
  }
  final transform = MapImageTransform._(result);
  // Accept only if it reproduces the anchor points it was built from.
  var worstScreenGap = 0.0;
  var screenSpread = 1e-6;
  for (var i = 0; i < pairs.length; i++) {
    final p = transform.project(pairs[i].$1);
    if (p == null) {
      return null;
    }
    worstScreenGap = math.max(worstScreenGap, (p - pairs[i].$2).distance);
    for (var j = i + 1; j < pairs.length; j++) {
      screenSpread = math.max(
        screenSpread,
        (pairs[i].$2 - pairs[j].$2).distance,
      );
    }
  }
  if (worstScreenGap > 0.25 * screenSpread + 2) {
    return null;
  }
  return transform;
}

/// Least-squares affine fit (6 unknowns, exact for 3 pairs). Returns the
/// row-major 3×3 with bottom row 0 0 1, or null when singular.
List<double>? _fitAffine(List<(Offset, Offset)> pairs) {
  // Two independent 3-unknown LS problems sharing the same normal matrix:
  // u = a·X + b·Y + c and v = d·X + e·Y + f.
  var sxx = 0.0, sxy = 0.0, sx = 0.0, syy = 0.0, sy = 0.0;
  final n = pairs.length.toDouble();
  var bu0 = 0.0, bu1 = 0.0, bu2 = 0.0;
  var bv0 = 0.0, bv1 = 0.0, bv2 = 0.0;
  for (final (m, s) in pairs) {
    sxx += m.dx * m.dx;
    sxy += m.dx * m.dy;
    sx += m.dx;
    syy += m.dy * m.dy;
    sy += m.dy;
    bu0 += m.dx * s.dx;
    bu1 += m.dy * s.dx;
    bu2 += s.dx;
    bv0 += m.dx * s.dy;
    bv1 += m.dy * s.dy;
    bv2 += s.dy;
  }
  final det =
      sxx * (syy * n - sy * sy) -
      sxy * (sxy * n - sy * sx) +
      sx * (sxy * sy - syy * sx);
  if (det.abs() < 1e-9) {
    return null;
  }
  List<double> solve(double r0, double r1, double r2) => [
    (r0 * (syy * n - sy * sy) -
            sxy * (r1 * n - r2 * sy) +
            sx * (r1 * sy - r2 * syy)) /
        det,
    (sxx * (r1 * n - r2 * sy) -
            r0 * (sxy * n - sy * sx) +
            sx * (sxy * r2 - r1 * sx)) /
        det,
    (sxx * (syy * r2 - sy * r1) -
            sxy * (sxy * r2 - r1 * sx) +
            r0 * (sxy * sy - syy * sx)) /
        det,
  ];
  final u = solve(bu0, bu1, bu2);
  final v = solve(bv0, bv1, bv2);
  return [u[0], u[1], u[2], v[0], v[1], v[2], 0, 0, 1];
}

/// Normalized-DLT homography for ≥4 pairs, solved via the 8×8 normal
/// equations. Returns null when the system is too ill-conditioned.
List<double>? _fitHomography(List<(Offset, Offset)> pairs) {
  (double cx, double cy, double scale) normalizer(Iterable<Offset> points) {
    var cx = 0.0, cy = 0.0;
    var n = 0;
    for (final p in points) {
      cx += p.dx;
      cy += p.dy;
      n++;
    }
    cx /= n;
    cy /= n;
    var dist = 0.0;
    for (final p in points) {
      dist += (p - Offset(cx, cy)).distance;
    }
    dist /= n;
    return (cx, cy, dist < 1e-9 ? 1 : math.sqrt2 / dist);
  }

  final (mcx, mcy, ms) = normalizer(pairs.map((p) => p.$1));
  final (scx, scy, ss) = normalizer(pairs.map((p) => p.$2));

  // Accumulate A^T A (8×8) and A^T b for rows
  //   [X Y 1 0 0 0 −uX −uY | u]   [0 0 0 X Y 1 −vX −vY | v]
  final ata = List<double>.filled(64, 0);
  final atb = List<double>.filled(8, 0);
  void addRow(List<double> row, double rhs) {
    for (var i = 0; i < 8; i++) {
      atb[i] += row[i] * rhs;
      for (var j = 0; j < 8; j++) {
        ata[i * 8 + j] += row[i] * row[j];
      }
    }
  }

  for (final (m, s) in pairs) {
    final x = (m.dx - mcx) * ms;
    final y = (m.dy - mcy) * ms;
    final u = (s.dx - scx) * ss;
    final v = (s.dy - scy) * ss;
    addRow([x, y, 1, 0, 0, 0, -u * x, -u * y], u);
    addRow([0, 0, 0, x, y, 1, -v * x, -v * y], v);
  }

  final h8 = _solveDense(ata, atb, 8);
  if (h8 == null) {
    return null;
  }
  // Denormalize: H = Tscreen⁻¹ · Ĥ · Tmap.
  final hn = [...h8, 1.0];
  final tMap = <double>[ms, 0, -ms * mcx, 0, ms, -ms * mcy, 0, 0, 1];
  final tScreenInv = <double>[1 / ss, 0, scx, 0, 1 / ss, scy, 0, 0, 1];
  return _mat3Mul(_mat3Mul(tScreenInv, hn), tMap);
}

List<double> _mat3Mul(List<double> a, List<double> b) => [
  for (var i = 0; i < 3; i++)
    for (var j = 0; j < 3; j++)
      a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j],
];

/// Gaussian elimination with partial pivoting on an n×n system (row-major
/// [a], right-hand side [b]). Returns null when a pivot vanishes.
List<double>? _solveDense(List<double> a, List<double> b, int n) {
  final m = List<double>.of(a);
  final rhs = List<double>.of(b);
  for (var col = 0; col < n; col++) {
    var pivot = col;
    for (var row = col + 1; row < n; row++) {
      if (m[row * n + col].abs() > m[pivot * n + col].abs()) {
        pivot = row;
      }
    }
    if (m[pivot * n + col].abs() < 1e-12) {
      return null;
    }
    if (pivot != col) {
      for (var j = 0; j < n; j++) {
        final t = m[col * n + j];
        m[col * n + j] = m[pivot * n + j];
        m[pivot * n + j] = t;
      }
      final t = rhs[col];
      rhs[col] = rhs[pivot];
      rhs[pivot] = t;
    }
    for (var row = col + 1; row < n; row++) {
      final factor = m[row * n + col] / m[col * n + col];
      if (factor == 0) {
        continue;
      }
      for (var j = col; j < n; j++) {
        m[row * n + j] -= factor * m[col * n + j];
      }
      rhs[row] -= factor * rhs[col];
    }
  }
  final x = List<double>.filled(n, 0);
  for (var row = n - 1; row >= 0; row--) {
    var sum = rhs[row];
    for (var j = row + 1; j < n; j++) {
      sum -= m[row * n + j] * x[j];
    }
    x[row] = sum / m[row * n + row];
  }
  return x;
}
