import 'dart:math' as math;

import '../models/ar_models.dart';
import '../utils/ar_geometry.dart';

/// What locate mode should show right now.
sealed class LocateState {
  const LocateState();
}

/// The target lot has no solved position on the server (or positions are
/// unavailable) — there is nothing to navigate to yet.
class LocateUnmapped extends LocateState {
  const LocateUnmapped();
}

/// Not oriented yet: the user needs to scan labels of mapped lots.
/// [fixCount] is how many distinct mapped lots have been sighted so far —
/// bearing-only resection needs 3 (with some angular spread between them).
class LocateNeedScans extends LocateState {
  const LocateNeedScans(this.fixCount);

  final int fixCount;

  /// Distinct mapped lots a resection needs.
  static const int required = 3;
}

/// Oriented: point the arrow [bearingRightRad] radians right of straight
/// ahead, target is [distanceM] away.
class LocateAim extends LocateState {
  const LocateAim({required this.bearingRightRad, required this.distanceM});

  final double bearingRightRad;
  final double distanceM;
}

/// Per-mount state for one AR scanning session.
///
/// Sits between the screen (which feeds it detections, gravity, and gyro
/// readings) and `ArApi` (which it batches observation uploads through, via
/// the injected `sender` so tests need no HTTP). Owns:
///
///  * **Observation batching** — one frame per camera callback that carried
///    at least one throttle-passing detection; flushed every
///    [flushInterval] / [maxBufferedFrames]. A lot re-contributes only every
///    [perLotInterval]: the solver wants geometry diversity, not 10 Hz
///    duplicates from someone holding the phone still.
///  * **Locate-mode pose** — a rolling window of sightings of lots with
///    known positions; bearings are rotated into the current device frame
///    with the integrated gyro yaw, and [solvePose] turns ≥2 distinct
///    landmarks into a device pose.
class ArSessionController {
  ArSessionController({
    required this.auctionSlug,
    required Future<void> Function(String sessionId, List<ArFrame> frames)
    sender,
    DateTime Function()? clock,
    math.Random? random,
  }) : _send = sender,
       _clock = clock ?? DateTime.now,
       sessionId = _newSessionId(random ?? math.Random.secure());

  static const Duration perLotInterval = Duration(seconds: 2);
  static const Duration flushInterval = Duration(seconds: 4);
  static const int maxBufferedFrames = 25;
  static const Duration fixWindow = Duration(seconds: 15);

  final String auctionSlug;
  final String sessionId;
  final Future<void> Function(String sessionId, List<ArFrame> frames) _send;
  final DateTime Function() _clock;

  final List<ArFrame> _buffer = [];
  final Map<int, DateTime> _lastRecorded = {};
  int _frameCounter = 0;
  DateTime? _lastFlush;
  bool _sending = false;

  // Locate mode.
  Map<int, ArLotPosition> _positions = const {};
  int? _targetPk;
  double _yawRad = 0; // integrated rotation about gravity, ccw-positive
  double _pitchDownRad = 0;
  final List<_TimedFix> _fixes = [];
  PoseEstimate? _pose;
  double _yawAtSolve = 0;

  /// Camera pitch below horizontal, from the latest gravity update.
  double get pitchDownRad => _pitchDownRad;

  static String _newSessionId(math.Random random) {
    const hex = '0123456789abcdef';
    return List.generate(32, (_) => hex[random.nextInt(16)]).join();
  }

  /// Feed the gravity vector (accelerometer at rest ≈ reaction to gravity,
  /// m/s², Android axis convention — sensors_plus normalizes iOS to match).
  /// Portrait, camera level: y ≈ +9.8. Flat on table: z ≈ +9.8. The camera
  /// looks along −z, so its depression below horizontal is atan2(z, y).
  void updateGravity(double x, double y, double z) {
    _pitchDownRad = math.atan2(z, y);
  }

  /// Integrate a gyroscope reading (rad/s, device axes) over [dtSeconds].
  /// Only the component about the gravity axis matters — that's heading
  /// change regardless of how the phone is held.
  void integrateGyro(
    double wx,
    double wy,
    double wz,
    double dtSeconds, {
    required double gx,
    required double gy,
    required double gz,
  }) {
    final g = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (g < 1e-6) {
      return;
    }
    // Accelerometer reads the reaction force: at rest it points *up* in
    // device coordinates, giving the up-axis directly; ω·û is then
    // counterclockwise-positive heading rate seen from above.
    _yawRad += (wx * gx + wy * gy + wz * gz) / g * dtSeconds;
  }

  /// Record one camera frame's detections. [measurements] holds every parsed
  /// lot QR in the frame with its estimated measurement; lots not in this
  /// auction are the server's to drop. Returns true when a flush was started.
  bool addFrame(Map<int, ArMeasurement> measurements) {
    final now = _clock();
    _lastFlush ??= now;

    final detections = <ArDetection>[];
    for (final entry in measurements.entries) {
      final last = _lastRecorded[entry.key];
      if (last != null && now.difference(last) < perLotInterval) {
        continue;
      }
      detections.add(
        ArDetection(
          lotPk: entry.key,
          bearingDeg: entry.value.bearingDeg,
          depressionDeg: entry.value.depressionDeg,
          quality: entry.value.quality,
        ),
      );
    }
    if (detections.isNotEmpty) {
      for (final d in detections) {
        _lastRecorded[d.lotPk] = now;
      }
      _buffer.add(
        ArFrame(
          frameId: 'f${(_frameCounter++).toString().padLeft(6, '0')}',
          capturedAt: now,
          detections: detections,
        ),
      );
    }

    _updateFixes(measurements, now);

    if (_buffer.length >= maxBufferedFrames ||
        now.difference(_lastFlush!) >= flushInterval) {
      flush();
      return true;
    }
    return false;
  }

  /// Number of frames waiting for upload (test hook).
  int get bufferedFrames => _buffer.length;

  /// Flush if the interval elapsed with frames still buffered — the trailing
  /// batch when the user stops pointing at labels. Driven by the screen's
  /// sweep timer; [addFrame] handles the active-scanning case itself.
  void flushIfDue() {
    final last = _lastFlush;
    if (_buffer.isNotEmpty &&
        (last == null || _clock().difference(last) >= flushInterval)) {
      flush();
    }
  }

  /// Upload everything buffered. Safe to call repeatedly; drops the batch on
  /// failure (ArApi already swallows errors — observations are lossy by
  /// design).
  Future<void> flush() async {
    if (_sending || _buffer.isEmpty) {
      _lastFlush = _clock();
      return;
    }
    final batch = List.of(_buffer);
    _buffer.clear();
    _lastFlush = _clock();
    _sending = true;
    try {
      await _send(sessionId, batch);
    } finally {
      _sending = false;
    }
  }

  // ── Locate mode ────────────────────────────────────────────────────────────

  /// Arm locate mode for [targetPk] with the server's solved [positions].
  void setLocateTarget(int targetPk, ArPositions? positions) {
    _targetPk = targetPk;
    _positions = positions?.byLot ?? const {};
    _fixes.clear();
    _pose = null;
  }

  /// Refresh solved positions mid-session (the server re-solves every minute,
  /// and "keep scanning until your lot is mapped" depends on picking that up).
  /// Existing fixes are re-anchored to the new positions; fixes whose lot
  /// dropped off the map (sold, cleared) are discarded.
  void updatePositions(ArPositions? positions) {
    if (_targetPk == null) {
      return;
    }
    _positions = positions?.byLot ?? const {};
    final rebased = <_TimedFix>[
      for (final f in _fixes)
        if (_positions[f.lotPk] case final p?)
          _TimedFix(
            lotPk: f.lotPk,
            at: f.at,
            yawAtSighting: f.yawAtSighting,
            position: p,
            measurement: f.measurement,
          ),
    ];
    _fixes
      ..clear()
      ..addAll(rebased);
    _solve();
  }

  void _updateFixes(Map<int, ArMeasurement> measurements, DateTime now) {
    if (_targetPk == null || _positions.isEmpty) {
      return;
    }
    var changed = false;
    for (final entry in measurements.entries) {
      final position = _positions[entry.key];
      if (position == null) {
        continue;
      }
      // Keep only the freshest fix per landmark — the window exists to span
      // panning between labels, not to average history.
      _fixes
        ..removeWhere((f) => f.lotPk == entry.key)
        ..add(
          _TimedFix(
            lotPk: entry.key,
            at: now,
            yawAtSighting: _yawRad,
            position: position,
            measurement: entry.value,
          ),
        );
      changed = true;
    }
    _fixes.removeWhere((f) => now.difference(f.at) > fixWindow);
    if (changed) {
      _solve();
    }
  }

  void _solve() {
    final fixes = [
      for (final f in _fixes)
        LandmarkFix(
          x: f.position.x,
          y: f.position.y,
          // Rotate the recorded device-frame bearing into the *current*
          // device frame: turning left (ccw, +yaw) moves old landmarks to
          // the right (+bearing).
          bearingRad:
              f.measurement.bearingDeg * math.pi / 180 +
              (_yawRad - f.yawAtSighting),
        ),
    ];
    final pose = solvePose(fixes);
    if (pose != null) {
      _pose = pose;
      _yawAtSolve = _yawRad;
    }
  }

  /// The target lot's solved map position, when known — the ghost-marker
  /// projection needs it (the screen owns the image-side data).
  ArLotPosition? get targetPosition =>
      _targetPk == null ? null : _positions[_targetPk];

  /// Any mapped lot's solved position (ghost-marker anchor lookup).
  ArLotPosition? positionOf(int lotPk) => _positions[lotPk];

  /// Current guidance for locate mode; null when locate mode is off.
  LocateState? get locateState {
    final target = _targetPk;
    if (target == null) {
      return null;
    }
    final position = _positions[target];
    if (position == null) {
      return const LocateUnmapped();
    }
    final pose = _pose;
    if (pose == null) {
      final distinct = <int>{for (final f in _fixes) f.lotPk};
      return LocateNeedScans(distinct.length);
    }
    final (bearing, distance) = pose.aim(position.x, position.y);
    // The solve froze θ in world coordinates; the phone has kept turning
    // since. Yaw is ccw-positive, bearings are right-positive, so subsequent
    // left turns swing the target further right.
    return LocateAim(
      bearingRightRad: wrapRad(bearing + (_yawRad - _yawAtSolve)),
      distanceM: distance,
    );
  }
}

class _TimedFix {
  const _TimedFix({
    required this.lotPk,
    required this.at,
    required this.yawAtSighting,
    required this.position,
    required this.measurement,
  });

  final int lotPk;
  final DateTime at;
  final double yawAtSighting;
  final ArLotPosition position;
  final ArMeasurement measurement;
}
