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
/// Sits between the screen (which feeds it detections, gravity, and tracked
/// AR poses) and `ArApi` (which it batches observation uploads through, via
/// the injected `sender` so tests need no HTTP). Owns:
///
///  * **Observation batching** — one frame per camera callback that carried
///    at least one throttle-passing detection; flushed every
///    [flushInterval] / [maxBufferedFrames]. A lot re-contributes only every
///    [perLotInterval]: the solver wants geometry diversity, not 10 Hz
///    duplicates from someone holding the phone still.
///  * **Interaction events** — scan/zoom/card-opened, de-duped to one per
///    (lot, type) per session and flushed on the same schedule.
///  * **Pose** — a rolling window of sightings of lots with known positions;
///    bearings are rotated into the current device frame with the AR-tracked
///    yaw, and [solvePose] turns ≥3 distinct landmarks into a device pose.
///    Locate mode aims its arrow with it; with no locate target it still
///    runs, so [lotsWithin] can answer "which mapped lots am I standing next
///    to" for the watched/recommended beacons.
class ArSessionController {
  ArSessionController({
    required this.auctionSlug,
    required Future<void> Function(String sessionId, List<ArFrame> frames)
    sender,
    Future<void> Function(List<ArEvent> events)? eventSender,
    DateTime Function()? clock,
    math.Random? random,
  }) : _send = sender,
       _sendEvents = eventSender,
       _clock = clock ?? DateTime.now,
       sessionId = _newSessionId(random ?? math.Random.secure());

  static const Duration perLotInterval = Duration(seconds: 2);
  static const Duration flushInterval = Duration(seconds: 4);
  static const int maxBufferedFrames = 25;
  static const Duration fixWindow = Duration(seconds: 15);

  final String auctionSlug;
  final String sessionId;
  final Future<void> Function(String sessionId, List<ArFrame> frames) _send;
  final Future<void> Function(List<ArEvent> events)? _sendEvents;
  final DateTime Function() _clock;

  final List<ArFrame> _buffer = [];
  final List<ArEvent> _pendingEvents = [];

  /// `<lotPk>:<event>` pairs already queued this session — the server de-dupes
  /// too, but re-sending a scan every frame would be absurd traffic.
  final Set<String> _recordedEvents = {};
  final Map<int, DateTime> _lastRecorded = {};
  int _frameCounter = 0;
  DateTime? _lastFlush;
  bool _sending = false;

  // Locate mode.
  Map<int, ArLotPosition> _positions = const {};
  int? _targetPk;
  double _yawRad = 0; // rotation about gravity, ccw-positive, from AR pose
  bool _yawLive = false; // any real yaw reading received yet?
  double _pitchDownRad = 0;

  // Freshest absolute compass heading, stamped onto each frame. Null until a
  // real value arrives (a heading is never faked — absence means "unknown").
  double? _headingDeg;

  // Odometry (BACKEND_SPEC.md Part 5): cumulative planar displacement since
  // session start, in the same frame as yaw — +x forward at yaw 0 (session
  // start), +y 90° ccw (left). Null until the first tracked AR pose arrives
  // ("unknown", never "didn't move"); ARCore/ARKit's world origin is fixed
  // for the whole session, so unlike the pedometer this replaced there is no
  // rebase/reset case to guard against here.
  double? _odoX;
  double? _odoY;

  final List<_TimedFix> _fixes = [];
  PoseEstimate? _pose;
  double _yawAtSolve = 0;

  /// Solver island the current [_pose] was resected in — the frame its
  /// coordinates (and anything compared against them) live in. Only
  /// meaningful with no locate target; with one, the target's component is
  /// the frame by definition.
  int? _poseComponent;

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

  /// Feed the freshest absolute compass heading (deg cw from magnetic north),
  /// or null to clear it. Stamped onto subsequent frames. Out-of-range values
  /// are rejected (cleared) so a bad sensor reading is never sent as a heading.
  void updateHeading(double? headingDeg) {
    _headingDeg = (headingDeg != null && headingDeg >= 0 && headingDeg < 360)
        ? headingDeg
        : null;
  }

  /// Feed one tracked AR pose (ArCameraService's pose stream, already
  /// converted via `arPoseToYawAndOdometry` in ar_geometry.dart — no trig
  /// happens here, this just stores the result). Callers should only invoke
  /// this while the native side reports the pose as actively tracking;
  /// there is deliberately no "invalidate" path — unlike the pedometer this
  /// odometry replaced, ARCore/ARKit's world origin is fixed for the whole
  /// session (never rebased), so a value simply not arriving (tracking
  /// lost) already leaves yaw/odometry at their last known value, exactly
  /// like a momentarily-missing magnetometer reading elsewhere in this
  /// session.
  ///
  /// [yawRad] null (the camera was pointing too near-vertical for a
  /// horizontal heading to mean anything) leaves yaw untouched; odometry
  /// always updates, since a momentarily-unusable heading doesn't make the
  /// position wrong.
  void updateOdometryFromPose({
    required double? yawRad,
    required double odoX,
    required double odoY,
  }) {
    if (yawRad != null) {
      _yawRad = yawRad;
      _yawLive = true;
    }
    _odoX = odoX;
    _odoY = odoY;
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
          // Session-cumulative heading so the solver can chain frames that
          // saw only one label each; omitted (not zero) without gyro data.
          yawDeg: _yawLive ? _yawRad * 180 / math.pi : null,
          // Freshest absolute heading, when the device reported one.
          headingDeg: _headingDeg,
          // Tracked odometry, when a pedometer/tracker reading has started
          // the channel — (0, 0) is a legitimate value, so this is gated on
          // null, not truthiness.
          odoXM: _odoX,
          odoYM: _odoY,
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

  /// Number of interaction events waiting for upload (test hook).
  int get bufferedEvents => _pendingEvents.length;

  /// Queue one interaction with a lot — see [ArEventType]. Repeats within the
  /// session are dropped, so callers can fire these from per-frame code.
  void recordEvent(int lotPk, ArEventType type) {
    if (_recordedEvents.add('$lotPk:${type.wire}')) {
      // Start the flush clock the same way addFrame does, so a burst of
      // events at the start of a session leaves as one batch rather than a
      // POST each.
      _lastFlush ??= _clock();
      _pendingEvents.add(ArEvent(lotPk: lotPk, type: type));
    }
  }

  /// Flush if the interval elapsed with something still buffered — the
  /// trailing batch when the user stops pointing at labels. Driven by the
  /// screen's sweep timer; [addFrame] handles the active-scanning case itself.
  void flushIfDue() {
    final last = _lastFlush;
    if ((_buffer.isNotEmpty || _pendingEvents.isNotEmpty) &&
        (last == null || _clock().difference(last) >= flushInterval)) {
      flush();
    }
  }

  /// Upload everything buffered. Safe to call repeatedly; drops the batch on
  /// failure (ArApi already swallows errors — observations and interaction
  /// events are lossy by design).
  Future<void> flush() async {
    if (_sending) {
      return;
    }
    final frames = List.of(_buffer);
    final events = List.of(_pendingEvents);
    _buffer.clear();
    _pendingEvents.clear();
    _lastFlush = _clock();
    if (frames.isEmpty && events.isEmpty) {
      return;
    }
    _sending = true;
    try {
      if (frames.isNotEmpty) {
        await _send(sessionId, frames);
      }
      if (events.isNotEmpty) {
        await _sendEvents?.call(events);
      }
    } finally {
      _sending = false;
    }
  }

  // ── Locate mode ────────────────────────────────────────────────────────────

  /// Arm locate mode for [targetPk]. Positions arrive (and refresh) through
  /// [updatePositions].
  void setLocateTarget(int targetPk) {
    _targetPk = targetPk;
    _fixes.clear();
    _pose = null;
  }

  /// Refresh solved positions mid-session (the server re-solves every minute,
  /// and "keep scanning until your lot is mapped" depends on picking that up).
  /// Existing fixes are re-anchored to the new positions; fixes whose lot
  /// dropped off the map (sold, cleared) are discarded.
  void updatePositions(ArPositions? positions) {
    _positions = positions?.byLot ?? const {};
    final rebased = <_TimedFix>[
      for (final f in _fixes)
        if (_positions[f.lotPk] case final p? when _acceptableFix(p))
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

  /// The solver island whose coordinates this session is currently working
  /// in: the locate target's, or — with no target — whichever island the
  /// pose was resected in. Null when neither is known, which means "no frame
  /// established yet" and everything passes.
  ({int? component})? get _activeFrame {
    final target = _targetPk == null ? null : _positions[_targetPk];
    if (target != null) {
      return (component: target.component);
    }
    return _pose == null ? null : (component: _poseComponent);
  }

  /// Whether [p] is in the session's active frame. Positions from different
  /// connectivity components share no observations, so their coordinates are
  /// unrelated — mixing them would aim confidently at the wrong place.
  bool _inActiveFrame(ArLotPosition p) {
    final frame = _activeFrame;
    return frame == null || p.component == frame.component;
  }

  /// Whether a sighting of a lot at [p] may join the fix window. In locate
  /// mode the target's island is fixed, so cross-island sightings are
  /// rejected outright; with no target every sighting is welcome and
  /// [_solve]'s dominant-island grouping decides — which is what lets the
  /// pose follow the user when they walk from one scanned island to another.
  bool _acceptableFix(ArLotPosition p) =>
      _targetPk == null || p.component == _positions[_targetPk]?.component;

  void _updateFixes(Map<int, ArMeasurement> measurements, DateTime now) {
    if (_positions.isEmpty) {
      return;
    }
    var changed = false;
    for (final entry in measurements.entries) {
      final position = _positions[entry.key];
      if (position == null || !_acceptableFix(position)) {
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
    final usable = _targetPk == null ? _dominantIslandFixes() : _fixes;
    final fixes = [
      for (final f in usable)
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
      _poseComponent = usable.isEmpty ? null : usable.first.position.component;
    }
  }

  /// The fixes belonging to whichever island most of them are in — a pose
  /// resected across two unconnected islands would be nonsense, and the
  /// biggest group is the one the user is standing in.
  List<_TimedFix> _dominantIslandFixes() {
    final counts = <int?, int>{};
    for (final f in _fixes) {
      counts[f.position.component] = (counts[f.position.component] ?? 0) + 1;
    }
    if (counts.length < 2) {
      return _fixes;
    }
    var best = counts.entries.first;
    for (final entry in counts.entries) {
      if (entry.value > best.value) {
        best = entry;
      }
    }
    return [
      for (final f in _fixes)
        if (f.position.component == best.key) f,
    ];
  }

  /// The target lot's solved map position, when known — the ghost-marker
  /// projection needs it (the screen owns the image-side data).
  ArLotPosition? get targetPosition =>
      _targetPk == null ? null : _positions[_targetPk];

  /// Any mapped lot's solved position (beacon + ghost-anchor lookup). Lots
  /// mapped in a different island than the session's active frame read as
  /// unmapped — their coordinates would anchor the marker in the wrong frame.
  ArLotPosition? positionOf(int lotPk) {
    final p = _positions[lotPk];
    return p != null && _inActiveFrame(p) ? p : null;
  }

  /// Whether the device has resected its own position on the map — i.e.
  /// whether [aimTo] and [lotsWithin] can answer anything at all.
  bool get hasPose => _pose != null;

  /// Device-frame bearing (positive right) and distance to a point in the
  /// map frame, from the last pose solve rotated forward to the current yaw.
  /// Null until a pose has been resected.
  ({double bearingRightRad, double distanceM})? aimTo(double x, double y) {
    final pose = _pose;
    if (pose == null) {
      return null;
    }
    final (bearing, distance) = pose.aim(x, y);
    // The solve froze θ in world coordinates; the phone has kept turning
    // since. Yaw is ccw-positive, bearings are right-positive, so subsequent
    // left turns swing the target further right.
    return (
      bearingRightRad: wrapRad(bearing + (_yawRad - _yawAtSolve)),
      distanceM: distance,
    );
  }

  /// Mapped lots within [radiusM] of the solved device position, nearest
  /// first — what the watched/recommended beacons key off. Empty until a pose
  /// exists; only the active island's lots can be compared against it.
  List<({int lotPk, ArLotPosition position, double distanceM})> lotsWithin(
    double radiusM,
  ) {
    final pose = _pose;
    if (pose == null) {
      return const [];
    }
    final found = <({int lotPk, ArLotPosition position, double distanceM})>[];
    for (final entry in _positions.entries) {
      final p = entry.value;
      if (!_inActiveFrame(p)) {
        continue;
      }
      final dx = p.x - pose.x;
      final dy = p.y - pose.y;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance <= radiusM) {
        found.add((lotPk: entry.key, position: p, distanceM: distance));
      }
    }
    found.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return found;
  }

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
    final aim = aimTo(position.x, position.y);
    if (aim == null) {
      final distinct = <int>{for (final f in _fixes) f.lotPk};
      return LocateNeedScans(distinct.length);
    }
    return LocateAim(
      bearingRightRad: aim.bearingRightRad,
      distanceM: aim.distanceM,
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
