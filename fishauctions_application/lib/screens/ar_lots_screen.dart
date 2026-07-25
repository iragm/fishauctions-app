import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../config/theme.dart';
import '../models/ar_camera_event.dart';
import '../models/ar_models.dart';
import '../services/ar_api.dart';
import '../services/ar_camera_service.dart';
import '../services/ar_session.dart';
import '../utils/ar_geometry.dart';
import '../utils/lot_qr.dart';
import '../utils/platform_bridge.dart';
import '../widgets/ar_camera_view.dart';

/// AR lot mode: a live camera view that recognizes lot-label QR codes and
/// overlays what they are. Reached from the web's app-only buttons —
/// `fishauctions://ar/<auction_slug>` on the auction rules page, plus
/// `?locate=<lot_pk>` from a lot page's "Locate with AR".
///
///  * Few labels in frame → name chips at each code (with the lot photo when
///    only one or two are up); many → dots. A watched lot's marker is a star,
///    a recommended one is green. QR codes that aren't lot labels get a grey
///    "invalid" dot so it's clear they were seen and rejected.
///  * One label centered and close → a card with the lot photo, the custom
///    fields its auction prints on labels, and an "open lot page" button
///    (pops back to the WebView with `?src=ar`, which records the scan).
///  * Every sighting is measured — angles only (bearing + gravity-referenced
///    depression from the QR's corner quad; printed label size is deliberately
///    irrelevant) — and batched to the backend, which triangulates everyone's
///    scans into the per-auction lot map (BACKEND_SPEC.md Part 3).
///  * Locate mode: until the phone has resected its own pose (≥3 mapped
///    labels sighted) it asks for scans; from then on the target gets a
///    beacon pinned in the camera view — projected off its visible mapped
///    neighbors when there are enough, otherwise off the solved pose — which
///    becomes an edge arrow while it's off screen.
///  * The watched/recommended checkboxes do the same for any mapped lot the
///    user is standing within six feet of, in the warning/success colors.
///
/// Degrades gracefully against a backend without Part 3: chips fall back to
/// `Lot <pk>` stubs, observation uploads switch off, locate mode reports the
/// lot as unmapped.
class ArLotsScreen extends StatefulWidget {
  const ArLotsScreen({required this.auctionSlug, this.locateLotPk, super.key});

  final String auctionSlug;
  final int? locateLotPk;

  @override
  State<ArLotsScreen> createState() => _ArLotsScreenState();
}

/// A lot currently in frame. Kept briefly after its last sighting so chips
/// don't flicker at detection rate.
class _VisibleLot {
  const _VisibleLot({
    required this.center,
    required this.imageSize,
    required this.measurement,
    required this.lastSeen,
    required this.centeredAndClose,
  });

  final Offset center; // image coordinates
  final Size imageSize;
  final ArMeasurement measurement;
  final DateTime lastSeen;
  final bool centeredAndClose;
}

/// A QR code in frame that isn't one of our lot labels (someone's wifi
/// sticker, a shipping label, a rival site's code). Marked so the user can
/// see it was read and rejected rather than missed.
class _VisibleCode {
  const _VisibleCode({
    required this.center,
    required this.imageSize,
    required this.lastSeen,
  });

  final Offset center;
  final Size imageSize;
  final DateTime lastSeen;
}

enum _CameraAccess { checking, granted, denied, permanentlyDenied }

class _ArLotsScreenState extends State<ArLotsScreen> {
  static const Duration _visibleTtl = Duration(milliseconds: 900);
  static const Duration _cardShowDelay = Duration(milliseconds: 500);
  static const Duration _cardHideDelay = Duration(milliseconds: 800);
  static const Duration _metaRetryInterval = Duration(seconds: 15);
  static const Duration _positionsRefreshInterval = Duration(seconds: 20);
  static const int _maxNamedChips = 3;

  /// Named chips carry the lot photo at or below this many labels in frame —
  /// with three or more there isn't room for pictures.
  static const int _maxThumbnailChips = 2;

  /// "You're right next to it": 6 feet, the radius a watched/recommended lot
  /// has to be inside for its beacon to appear.
  static const double _beaconRadiusM = 1.83;

  /// How far out we bother pulling metadata for mapped lots, so a beacon can
  /// pop the moment the user walks into range instead of a fetch later.
  static const double _flagMetaRadiusM = 12;
  static const Duration _flagMetaInterval = Duration(seconds: 3);

  /// Assumed drop from the camera to a label on a table — the only thing that
  /// gives a pose-projected beacon a sensible *height* on screen (the map is
  /// 2D). Wrong by a few tens of centimeters just nudges the pin up or down.
  static const double _labelDropM = 0.8;

  _CameraAccess _access = _CameraAccess.checking;

  /// The native AR session's own lifecycle, from `ArCameraService`'s pose
  /// stream: `checking` | `unsupported` | `installing` | `ready` | `error`.
  /// Only meaningful once [_access] is `granted` and `ArCameraView` has
  /// mounted (that's what starts the native session in the first place).
  String _arStatus = 'checking';
  String? _arStatusMessage;

  late final ArSessionController _session;

  /// Device-reported camera horizontal FOV, or null on the assumed-FOV
  /// fallback. Fetched once; bearings and the observation POST both carry it.
  double? _deviceHFov;

  /// Back camera Brown-Conrady lens distortion coefficients, or null when
  /// unavailable (iOS, or an Android device/HAL that doesn't report them).
  /// Fetched once; every bearing/depression estimate corrects for it.
  List<double>? _lensDistortion;

  final Map<int, _VisibleLot> _visible = {};

  /// Non-lot QR codes in frame, keyed by their raw contents.
  final Map<String, _VisibleCode> _visibleOther = {};
  final Map<int, ArLotMeta> _meta = {};
  final Set<int> _metaPending = {};
  final Map<int, DateTime> _metaAttempt = {};
  ArAuctionMeta? _auction;

  /// Pixel dimensions of the most recent detection pass, kept so a beacon can
  /// still be projected from the pose after the labels leave the frame.
  Size? _lastImageSize;

  /// The bottom checkboxes — beacons for nearby watched / recommended lots.
  /// Off by default: this is opt-in guidance, not a permanent HUD.
  bool _beaconWatched = false;
  bool _beaconRecommended = false;
  DateTime _lastFlagMetaFetch = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _sweepTimer;
  Timer? _positionsTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<ArCameraEvent>? _arPoseSub;
  StreamSubscription<ArDetectionBatch>? _arDetectionSub;
  (double, double, double) _gravity = (0, 9.8, 0); // assume upright until read

  int? _cardPk;
  int? _cardCandidatePk;
  DateTime _cardCandidateSince = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _cardBrokenAt;
  LocateState? _locate;

  @override
  void initState() {
    super.initState();
    _session = ArSessionController(
      auctionSlug: widget.auctionSlug,
      sender: (sessionId, frames) => ArApi.instance.postObservations(
        widget.auctionSlug,
        sessionId,
        frames,
        fovHDeg: _deviceHFov,
      ),
      eventSender: (events) =>
          ArApi.instance.postEvents(widget.auctionSlug, events),
    );
    _initCamera();
    if (widget.locateLotPk != null) {
      _initLocate();
    }
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!mounted) {
      return;
    }
    if (!status.isGranted) {
      setState(
        () => _access = status.isPermanentlyDenied
            ? _CameraAccess.permanentlyDenied
            : _CameraAccess.denied,
      );
      return;
    }
    // Real intrinsics when the device will say — turns QR pixel offsets into
    // accurate bearings instead of the assumed-FOV guess. Independent of who
    // currently owns the camera stream (a plain CameraCharacteristics query),
    // so this is unaffected by ARCore/ARKit owning the capture session below.
    _deviceHFov = await PlatformBridge.cameraHorizontalFovDeg();
    _lensDistortion = await PlatformBridge.cameraLensDistortion();
    if (!mounted) {
      return;
    }
    _arPoseSub = ArCameraService.instance.poseEvents().listen(
      _onArCameraEvent,
      onError: (Object _) {},
    );
    _arDetectionSub = ArCameraService.instance.detectionEvents().listen(
      _onDetections,
      onError: (Object _) {},
    );
    _accelSub =
        accelerometerEventStream(
          samplingPeriod: SensorInterval.uiInterval,
        ).listen((e) {
          _gravity = (e.x, e.y, e.z);
          _session.updateGravity(e.x, e.y, e.z);
        }, onError: (Object _) {});
    // Magnetometer → absolute (magnetic) camera heading, tilt-compensated with
    // the gravity vector. Stamped on each frame so the backend can one day fix
    // island orientation, not just GPS position (BACKEND_SPEC Part 5). Absent
    // hardware just leaves the heading null.
    _magSub = magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval)
        .listen((e) {
          _session.updateHeading(magneticHeadingDeg(_gravity, (e.x, e.y, e.z)));
        }, onError: (Object _) {});
    _sweepTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _sweep(),
    );
    setState(() => _access = _CameraAccess.granted);
  }

  /// Handles one event from `ArCameraService.poseEvents()`: either a session
  /// status change (drives the checking/unsupported/installing/ready/error
  /// explainer alongside [_access]) or a tracked pose, converted via
  /// `arPoseToYawAndOdometry` (ar_geometry.dart) and fed straight into the
  /// session. A pose reported while *not* tracking is dropped rather than
  /// forwarded — same "no update leaves the last known value" contract as a
  /// momentarily-missing magnetometer reading.
  void _onArCameraEvent(ArCameraEvent event) {
    switch (event) {
      case ArStatusUpdate(:final status, :final message):
        if (mounted) {
          setState(() {
            _arStatus = status;
            _arStatusMessage = message;
          });
        }
      case ArPoseUpdate(
        :final tracking,
        :final px,
        :final pz,
        :final fx,
        :final fz,
      ):
        if (!tracking) {
          return;
        }
        final converted = arPoseToYawAndOdometry(
          px: px,
          pz: pz,
          fx: fx,
          fz: fz,
        );
        _session.updateOdometryFromPose(
          yawRad: converted.yawRad,
          odoX: converted.odoX,
          odoY: converted.odoY,
        );
    }
  }

  /// Runs from initState, before the first build — hence the direct
  /// assignment rather than setState; the sweep timer keeps [_locate] fresh
  /// from there.
  void _initLocate() {
    final target = widget.locateLotPk!;
    _session.setLocateTarget(target);
    _locate = _session.locateState;
    unawaited(_fetchMeta({target}));
    _ensurePositionsPolling();
  }

  /// Solved positions are only worth pulling when something on screen depends
  /// on them — locate mode, or a beacon checkbox. The server re-solves about
  /// once a minute; keep pulling so "scan more lots until yours is mapped"
  /// can actually complete.
  void _ensurePositionsPolling() {
    final wanted =
        widget.locateLotPk != null || _beaconWatched || _beaconRecommended;
    if (!wanted) {
      _positionsTimer?.cancel();
      _positionsTimer = null;
      return;
    }
    if (_positionsTimer != null) {
      return;
    }
    unawaited(_refreshPositions());
    _positionsTimer = Timer.periodic(
      _positionsRefreshInterval,
      (_) => unawaited(_refreshPositions()),
    );
  }

  Future<void> _refreshPositions() async {
    final positions = await ArApi.instance.fetchPositions(widget.auctionSlug);
    if (mounted && positions != null) {
      _session.updatePositions(positions);
    }
  }

  @override
  void dispose() {
    _sweepTimer?.cancel();
    _positionsTimer?.cancel();
    _accelSub?.cancel();
    _magSub?.cancel();
    _arPoseSub?.cancel();
    _arDetectionSub?.cancel();
    unawaited(_session.flush());
    super.dispose();
  }

  // ── Detection ─────────────────────────────────────────────────────────────

  void _onDetections(ArDetectionBatch batch) {
    if (!mounted || batch.imageSize.isEmpty) {
      return;
    }
    final imageSize = batch.imageSize;
    _lastImageSize = imageSize;
    final now = DateTime.now();
    final measurements = <int, ArMeasurement>{};
    final seen = <int, _VisibleLot>{};
    final other = <String, _VisibleCode>{};
    for (final barcode in batch.barcodes) {
      final sighting = QrSighting.fromCorners(barcode.corners);
      if (sighting == null) {
        continue;
      }
      final pk = parseLotQr(barcode.rawValue);
      if (pk == null) {
        // Not one of our labels. Still worth marking so a user pointing at
        // the wrong sticker sees that it was read, not missed.
        other[barcode.rawValue ?? ''] = _VisibleCode(
          center: sighting.center,
          imageSize: imageSize,
          lastSeen: now,
        );
        continue;
      }
      final measurement = estimateMeasurement(
        sighting: sighting,
        imageSize: imageSize,
        pitchDownRad: _session.pitchDownRad,
        deviceHFovDeg: _deviceHFov,
        lensDistortion: _lensDistortion,
      );
      measurements[pk] = measurement;
      seen[pk] = _VisibleLot(
        center: sighting.center,
        imageSize: imageSize,
        measurement: measurement,
        lastSeen: now,
        centeredAndClose: _isCenteredAndClose(sighting, imageSize),
      );
    }
    if (seen.isEmpty && other.isEmpty) {
      return; // expiry, not absence-in-one-frame, clears chips
    }
    // Only lots believed to be in this auction feed the position solver and
    // the interaction stats; unknown-yet lots pass through (the server drops
    // cross-auction ones authoritatively).
    final reportable = <int, ArMeasurement>{
      for (final e in measurements.entries)
        if (_meta[e.key]?.inAuction ?? true) e.key: e.value,
    };
    if (reportable.isNotEmpty) {
      _session.addFrame(reportable);
    }
    for (final pk in reportable.keys) {
      _session.recordEvent(pk, ArEventType.scanned);
      if (seen[pk]!.centeredAndClose) {
        _session.recordEvent(pk, ArEventType.zoomed);
      }
    }
    unawaited(_fetchMeta(measurements.keys.toSet()));
    setState(() {
      _visible.addAll(seen);
      _visibleOther.addAll(other);
    });
  }

  static bool _isCenteredAndClose(QrSighting sighting, Size imageSize) {
    final dx = (sighting.center.dx - imageSize.width / 2).abs();
    final dy = (sighting.center.dy - imageSize.height / 2).abs();
    return dx < imageSize.width * 0.3 &&
        dy < imageSize.height * 0.3 &&
        sighting.edgePx >= math.min(imageSize.width, imageSize.height) * 0.04;
  }

  Future<void> _fetchMeta(Set<int> pks) async {
    final now = DateTime.now();
    final wanted = <int>{
      for (final pk in pks)
        if (!_metaPending.contains(pk) &&
            (_meta[pk] == null ||
                // Stubs from a transient failure get retried occasionally;
                // real server rows are good for the whole session.
                (_meta[pk]!.isStub &&
                    now.difference(_metaAttempt[pk] ?? DateTime(2000)) >
                        _metaRetryInterval)))
          pk,
    };
    if (wanted.isEmpty) {
      return;
    }
    _metaPending.addAll(wanted);
    for (final pk in wanted) {
      _metaAttempt[pk] = now;
    }
    try {
      final result = await ArApi.instance.fetchLots(widget.auctionSlug, wanted);
      if (!mounted) {
        return;
      }
      setState(() {
        _auction ??= result.auction;
        for (final lot in result.lots) {
          _meta[lot.pk] = lot;
        }
      });
    } finally {
      _metaPending.removeAll(wanted);
    }
  }

  /// 4 Hz housekeeping: expire stale chips, settle the single-lot card
  /// (debounced both ways so it neither flickers in nor drops out between
  /// detection callbacks), refresh locate guidance, flush trailing
  /// observation batches.
  void _sweep() {
    if (!mounted) {
      return;
    }
    final now = DateTime.now();
    final changed = _visible.isNotEmpty || _visibleOther.isNotEmpty;
    _visible.removeWhere((_, v) => now.difference(v.lastSeen) > _visibleTtl);
    _visibleOther.removeWhere(
      (_, v) => now.difference(v.lastSeen) > _visibleTtl,
    );

    int? candidate;
    if (_visible.length == 1) {
      final entry = _visible.entries.first;
      if (entry.value.centeredAndClose) {
        candidate = entry.key;
      }
    }
    if (candidate != _cardCandidatePk) {
      _cardCandidatePk = candidate;
      _cardCandidateSince = now;
    }
    if (candidate != null) {
      _cardBrokenAt = null;
      if (_cardPk != candidate &&
          now.difference(_cardCandidateSince) >= _cardShowDelay) {
        _cardPk = candidate;
        // The card is the deepest AR interaction there is — "zoomed all the
        // way in" on the lot page's counts.
        if (_meta[candidate]?.inAuction ?? true) {
          _session.recordEvent(candidate, ArEventType.zoomedFull);
        }
      }
    } else if (_cardPk != null) {
      _cardBrokenAt ??= now;
      if (now.difference(_cardBrokenAt!) >= _cardHideDelay) {
        _cardPk = null;
        _cardBrokenAt = null;
      }
    }

    _session.flushIfDue();
    _maybeFetchFlagMeta(now);
    _locate = _session.locateState;
    if (changed ||
        _cardPk != null ||
        _locate != null ||
        _beaconWatched ||
        _beaconRecommended) {
      setState(() {});
    }
  }

  /// With a beacon checkbox on, pull metadata for mapped lots around the
  /// user — we can't know a lot is watched or recommended without it, and
  /// waiting until it's 6 feet away would surface the beacon a fetch late.
  /// Bounded by radius, by one batch per call, and by [_fetchMeta]'s own
  /// "never re-fetch a known lot" rule, so standing still costs nothing.
  void _maybeFetchFlagMeta(DateTime now) {
    if (!_beaconWatched && !_beaconRecommended) {
      return;
    }
    if (now.difference(_lastFlagMetaFetch) < _flagMetaInterval) {
      return;
    }
    final wanted = <int>{
      for (final lot in _session.lotsWithin(_flagMetaRadiusM))
        if (_meta[lot.lotPk] == null) lot.lotPk,
    };
    if (wanted.isEmpty) {
      return;
    }
    _lastFlagMetaFetch = now;
    unawaited(_fetchMeta(wanted.take(ArApi.maxLotsPerFetch).toSet()));
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Open the lot's web page: pop back to the WebView shell with the path to
  /// load. `src=ar` rides along so the page-view beacon records the scan
  /// (counted alongside physical QR scans server-side).
  void _openLotPage(ArLotMeta meta) {
    unawaited(_session.flush());
    final base = meta.lotUrl ?? '/lots/${meta.pk}/';
    final sep = base.contains('?') ? '&' : '?';
    context.pop('$base${sep}src=ar');
  }

  /// Toggle the caller's watch state on [pk] from the card's star. Optimistic:
  /// flip locally, POST it, and revert with a snackbar if the server call
  /// fails (the endpoint sets, not toggles, so it's safe to retry).
  Future<void> _toggleWatch(int pk) async {
    final current = _meta[pk];
    if (current == null) {
      return;
    }
    final next = !current.watched;
    setState(() => _meta[pk] = current.copyWith(watched: next));
    final result = await ArApi.instance.setWatch(pk, watch: next);
    if (!mounted) {
      return;
    }
    final latest = _meta[pk];
    if (latest == null) {
      return;
    }
    if (result == null) {
      setState(() => _meta[pk] = latest.copyWith(watched: current.watched));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't update watch — try again.")),
      );
    } else if (result != latest.watched) {
      setState(() => _meta[pk] = latest.copyWith(watched: result));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  ArLotMeta _metaFor(int pk) => _meta[pk] ?? ArLotMeta.stub(pk);

  String get _title {
    final target = widget.locateLotPk;
    if (target != null) {
      return 'Find ${_metaFor(target).displayName}';
    }
    final auctionTitle = _auction?.title;
    return (auctionTitle == null || auctionTitle.isEmpty)
        ? 'AR Lots'
        : auctionTitle;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black.withValues(alpha: 0.6),
      foregroundColor: Colors.white,
      title: Text(_title, overflow: TextOverflow.ellipsis),
      // No flashlight toggle: ARCore/ARKit own the camera exclusively while
      // tracking, and neither exposes torch control through its public API
      // (unlike the old mobile_scanner/CameraX path, which could toggle the
      // flash directly) — a real, minor capability loss from this rewrite.
    ),
    body: switch (_access) {
      _CameraAccess.checking => const Center(
        child: CircularProgressIndicator(),
      ),
      _CameraAccess.denied => _PermissionExplainer(
        message:
            'AR mode needs the camera to scan lot labels. Grant camera '
            'access to continue.',
        buttonLabel: 'Grant camera access',
        onPressed: _initCamera,
      ),
      _CameraAccess.permanentlyDenied => const _PermissionExplainer(
        message:
            'Camera access is turned off for this app. Enable it in system '
            'settings to use AR mode.',
        buttonLabel: 'Open settings',
        onPressed: openAppSettings,
      ),
      _CameraAccess.granted => _buildScanner(),
    },
  );

  Widget _buildScanner() {
    // ARCore/ARKit reported this device/build can't do AR tracking at all —
    // nothing useful to show behind the camera view in that case.
    if (_arStatus == 'unsupported' || _arStatus == 'error') {
      return _PermissionExplainer(
        message:
            _arStatusMessage ??
            "AR mode couldn't start on this device. Please try again.",
        buttonLabel: 'Go back',
        onPressed: () => context.pop(),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final widgetSize = constraints.biggest;
        final cardMeta = _cardPk == null ? null : _metaFor(_cardPk!);
        final target = widget.locateLotPk;
        // Fitted once per frame and shared by every beacon on it.
        final mapToScreen = _fitVisibleLots(widgetSize);
        final targetBeacon = target == null
            ? null
            : _beaconFor(
                widgetSize,
                pk: target,
                color: _targetColor,
                mapToScreen: mapToScreen,
              );
        // "Oriented" = we can point at the lot, either with a beacon or
        // because its own label is on screen. Until then the banner asks for
        // scans; after it, the beacon speaks for itself.
        final oriented =
            target != null &&
            (targetBeacon != null || _visible.containsKey(target));
        // The camera preview is full-bleed, but interactive overlays must clear
        // the (edge-to-edge) system navigation bar — otherwise the card and its
        // buttons sit under the translucent nav buttons and get cut off.
        final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
        return Stack(
          fit: StackFit.expand,
          children: [
            const ArCameraView(),
            // Session still starting up (checking availability, or Google
            // Play Services for AR / an ARKit warm-up is installing) — the
            // camera view is mounted but has nothing to show yet.
            if (_arStatus != 'ready')
              const ColoredBox(
                color: Colors.black54,
                child: Center(child: CircularProgressIndicator()),
              ),
            ..._buildMarkers(widgetSize),
            ?targetBeacon,
            ..._buildFlagBeacons(widgetSize, mapToScreen),
            if (_locate case final locate? when !oriented)
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: _LocateBanner(state: locate),
              ),
            if (cardMeta != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: _flagBarHeight + 12 + bottomInset,
                child: _LotCard(
                  meta: cardMeta,
                  onOpen: () => _openLotPage(cardMeta),
                  onToggleWatch: () => unawaited(_toggleWatch(cardMeta.pk)),
                ),
              ),
            if (_hint(cardMeta) case final hint?)
              Positioned(
                left: 24,
                right: 24,
                bottom: _flagBarHeight + 36 + bottomInset,
                child: Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    shadows: [Shadow(blurRadius: 8)],
                  ),
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 8 + bottomInset,
              child: _FlagBar(
                watched: _beaconWatched,
                recommended: _beaconRecommended,
                onToggleWatched: () => setState(() {
                  _beaconWatched = !_beaconWatched;
                  _ensurePositionsPolling();
                }),
                onToggleRecommended: () => setState(() {
                  _beaconRecommended = !_beaconRecommended;
                  _ensurePositionsPolling();
                }),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The bottom hint line, or null when the overlay speaks for itself. A
  /// ticked checkbox with no pose yet gets priority: nothing can be "near
  /// you" until the phone has placed itself on the map, and a checkbox that
  /// silently does nothing looks broken.
  String? _hint(ArLotMeta? cardMeta) {
    if ((_beaconWatched || _beaconRecommended) &&
        !_session.hasPose &&
        _locate == null) {
      return 'Scan a few lot labels around you so I can tell what you\'re '
          'standing next to';
    }
    return (_visible.isEmpty && cardMeta == null)
        ? 'Point the camera at lot labels'
        : null;
  }

  /// Beacons for the nearby lots the user ticked the boxes for: any mapped
  /// lot within [_beaconRadiusM] that they're watching (warning) or that's
  /// recommended to them (success). The locate target keeps its own blue
  /// beacon and is never doubled up here.
  List<Widget> _buildFlagBeacons(
    Size widgetSize,
    MapImageTransform? mapToScreen,
  ) {
    if (!_beaconWatched && !_beaconRecommended) {
      return const [];
    }
    final beacons = <Widget>[];
    for (final lot in _session.lotsWithin(_beaconRadiusM)) {
      if (lot.lotPk == widget.locateLotPk) {
        continue;
      }
      final meta = _meta[lot.lotPk];
      if (meta == null || meta.sold || meta.removed) {
        continue;
      }
      final color = _beaconWatched && meta.watched
          ? AppTheme.warning
          : _beaconRecommended && meta.recommended
          ? AppTheme.success
          : null;
      if (color == null) {
        continue;
      }
      final beacon = _beaconFor(
        widgetSize,
        pk: lot.lotPk,
        color: color,
        distanceM: lot.distanceM,
        mapToScreen: mapToScreen,
      );
      if (beacon != null) {
        beacons.add(beacon);
      }
    }
    return beacons;
  }

  /// A beacon for one mapped lot: a pin where it should be, or a small arrow
  /// at the edge of the screen when it's off frame. The position comes from
  /// whichever projection is available, best first:
  ///
  ///  1. A transform fitted from the mapped lots visible *right now*
  ///     (`fitMapToImage`) — no pose solve, no ranges, centimeter-class with
  ///     ≥3 mapped labels in frame.
  ///  2. The solved device pose — bearing puts it left/right, and an assumed
  ///     table height ([_labelDropM]) puts it up/down. Coarser, but it keeps
  ///     working once the anchors leave the frame.
  ///
  /// Null when the lot has no position in the session's active island, when
  /// neither projection is available, or when the lot's own label is on
  /// screen (its highlighted chip is better than any projection of it).
  Widget? _beaconFor(
    Size widgetSize, {
    required int pk,
    required Color color,
    required MapImageTransform? mapToScreen,
    double? distanceM,
  }) {
    if (_visible.containsKey(pk)) {
      return null;
    }
    final position = _session.positionOf(pk);
    if (position == null) {
      return null;
    }
    final aim = _session.aimTo(position.x, position.y);
    final projected =
        mapToScreen?.project(Offset(position.x, position.y)) ??
        _projectFromPose(aim, widgetSize);
    if (projected == null) {
      return null;
    }
    final distance = distanceM ?? aim?.distanceM;
    final inset = Rect.fromLTWH(
      24,
      24,
      widgetSize.width - 48,
      widgetSize.height - 48,
    );
    if (inset.contains(projected)) {
      return Positioned(
        left: projected.dx,
        top: projected.dy,
        child: FractionalTranslation(
          translation: const Offset(-0.5, -1),
          child: _BeaconMarker(
            label: _metaFor(pk).displayName,
            distanceM: distance,
            color: color,
          ),
        ),
      );
    }
    // Projected outside the view: an edge arrow pointing the pan direction.
    final clamped = Offset(
      projected.dx.clamp(inset.left, inset.right),
      projected.dy.clamp(inset.top, inset.bottom),
    );
    final dir = projected - clamped;
    return Positioned(
      left: clamped.dx,
      top: clamped.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: _BeaconArrow(
          angleRad: math.atan2(dir.dy, dir.dx),
          distanceM: distance,
          color: color,
        ),
      ),
    );
  }

  /// Projection 1: the map→screen transform fitted from the mapped lots on
  /// screen right now. Null when too few (or too collinear) are visible.
  MapImageTransform? _fitVisibleLots(Size widgetSize) => fitMapToImage([
    for (final entry in _visible.entries)
      if (_session.positionOf(entry.key) case final p?)
        (
          Offset(p.x, p.y),
          mapImagePointToWidget(
            entry.value.center,
            entry.value.imageSize,
            widgetSize,
          ),
        ),
  ]);

  /// Projection 2: place the lot from the solved pose's bearing and distance.
  /// Bearings beyond the frame are deliberately pushed a full screen width
  /// out (rather than run through `tan`, which flips sign past ±90°) so the
  /// edge-arrow clamp puts the arrow on the correct side even for something
  /// directly behind the user.
  Offset? _projectFromPose(
    ({double bearingRightRad, double distanceM})? aim,
    Size widgetSize,
  ) {
    if (aim == null || widgetSize.isEmpty) {
      return null;
    }
    final focal = _widgetFocalPx(widgetSize);
    final bearing = aim.bearingRightRad;
    final dx = bearing.abs() >= math.pi / 3
        ? (bearing.isNegative ? -widgetSize.width : widgetSize.width)
        : focal * math.tan(bearing);
    // Labels sit below eye level; how far below on screen depends on the
    // distance and how far the camera is already tilted down.
    final depression = math.atan(
      _labelDropM / math.max(aim.distanceM, _labelDropM),
    );
    final dy = focal * math.tan(depression - _session.pitchDownRad);
    return Offset(
      widgetSize.width / 2 + dx,
      (widgetSize.height / 2 + dy).clamp(0.0, widgetSize.height),
    );
  }

  /// Focal length in *widget* pixels: the camera's focal for the detection
  /// image, scaled by the same BoxFit.cover factor `mapImagePointToWidget`
  /// uses. Falls back to the widget's own geometry before any frame has been
  /// processed.
  double _widgetFocalPx(Size widgetSize) {
    final image = _lastImageSize;
    if (image == null || image.isEmpty) {
      return focalPxFor(widgetSize, deviceHFovDeg: _deviceHFov);
    }
    final scale = math.max(
      widgetSize.width / image.width,
      widgetSize.height / image.height,
    );
    return focalPxFor(image, deviceHFovDeg: _deviceHFov) * scale;
  }

  List<Widget> _buildMarkers(Size widgetSize) {
    final compact = _visible.length > _maxNamedChips;
    // The chip carries the lot photo while only one or two labels are up —
    // that's the "I'm looking at this lot" case. It's dropped for the lot the
    // detail card is already showing full-width, and once the frame is busy.
    final showChipThumbnail = !compact && _visible.length <= _maxThumbnailChips;
    final target = widget.locateLotPk;
    return [
      for (final entry in _visible.entries)
        () {
          final meta = _metaFor(entry.key);
          final pos = mapImagePointToWidget(
            entry.value.center,
            entry.value.imageSize,
            widgetSize,
          );
          return Positioned(
            left: pos.dx,
            top: pos.dy,
            child: FractionalTranslation(
              translation: const Offset(-0.5, -0.5),
              child: _LotMarker(
                meta: meta,
                compact: compact,
                showThumbnail: showChipThumbnail && entry.key != _cardPk,
                highlighted: entry.key == target,
              ),
            ),
          );
        }(),
      for (final code in _visibleOther.values)
        () {
          final pos = mapImagePointToWidget(
            code.center,
            code.imageSize,
            widgetSize,
          );
          return Positioned(
            left: pos.dx,
            top: pos.dy,
            child: const FractionalTranslation(
              translation: Offset(-0.5, -0.5),
              child: _InvalidCodeMarker(),
            ),
          );
        }(),
    ];
  }
}

/// The locate target's color, in both the beacon and the highlight ring
/// around its own chip.
const Color _targetColor = Colors.lightBlueAccent;

/// Height reserved at the bottom of the camera view for [_FlagBar], so the
/// detail card and the "point the camera" hint stack above it.
const double _flagBarHeight = 52;

/// Camera-permission and camera-error states share this full-screen message.
class _PermissionExplainer extends StatelessWidget {
  const _PermissionExplainer({
    required this.message,
    required this.buttonLabel,
    required this.onPressed,
  });

  final String message;
  final String buttonLabel;
  final void Function() onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off, size: 64, color: Colors.white54),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
        ],
      ),
    ),
  );
}

/// The overlay marker for one sighted lot: a name chip normally, a bare dot
/// when the frame is crowded. Watched wins the marker style (star), then
/// recommended (green), then sold (grey).
class _LotMarker extends StatelessWidget {
  const _LotMarker({
    required this.meta,
    required this.compact,
    required this.highlighted,
    this.showThumbnail = false,
  });

  final ArLotMeta meta;
  final bool compact;
  final bool highlighted;

  /// Whether the named chip should include the lot's thumbnail below its name.
  final bool showThumbnail;

  // Same warning/success pair the beacons and the checkboxes use, so a lot
  // means the same thing whichever way it shows up on screen.
  Color get _accent => meta.watched
      ? AppTheme.warning
      : meta.recommended
      ? AppTheme.success
      : meta.sold || meta.removed
      ? Colors.grey
      : Colors.white;

  @override
  Widget build(BuildContext context) {
    // Until the server metadata lands, a lot is just a neutral gray dot — no
    // "Lot <pk>" guess (the pk is not a name and only confuses).
    final asDot = meta.isStub || compact;
    final marker = meta.isStub
        ? _dot(Colors.grey.shade400, size: compact ? 16 : 12)
        : asDot
        ? _icon(size: compact ? 22 : 16, dotSize: compact ? 16 : 10)
        : _chip();
    if (!highlighted) {
      return marker;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: asDot ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: asDot ? null : BorderRadius.circular(20),
        border: Border.all(color: _targetColor, width: 3),
      ),
      child: Padding(padding: const EdgeInsets.all(3), child: marker),
    );
  }

  Widget _dot(Color color, {required double size}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.black45),
    ),
  );

  Widget _icon({required double size, required double dotSize}) => meta.watched
      ? Icon(Icons.star, size: size, color: AppTheme.warning)
      : _dot(_accent, size: dotSize);

  /// The named chip: lot name, plus — for the ≤3-lots view — the thumbnail
  /// tucked below the name so the picture is visible without opening the card.
  Widget _chip() => Container(
    constraints: const BoxConstraints(maxWidth: 160),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _icon(size: 16, dotSize: 10),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                meta.sold ? '${meta.displayName} · sold' : meta.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: meta.sold ? Colors.white54 : Colors.white,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        if (showThumbnail)
          if (meta.thumbnailUrl case final url?) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                url,
                width: 140,
                height: 90,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ],
      ],
    ),
  );
}

/// A QR code that isn't a lot label: a grey dot, captioned, so it reads as
/// "seen and ignored" rather than "not detected".
class _InvalidCodeMarker extends StatelessWidget {
  const _InvalidCodeMarker();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: Colors.grey.shade500,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black45),
        ),
      ),
      const SizedBox(height: 3),
      const Text(
        'invalid',
        style: TextStyle(
          color: Colors.white70,
          fontSize: 11,
          shadows: [Shadow(blurRadius: 6)],
        ),
      ),
    ],
  );
}

/// A beacon pin: where a lot should be, in the color that says why we're
/// pointing at it (blue = the lot you asked to find, warning = watched,
/// success = recommended).
class _BeaconMarker extends StatelessWidget {
  const _BeaconMarker({
    required this.label,
    required this.color,
    this.distanceM,
  });

  final String label;
  final Color color;
  final double? distanceM;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        constraints: const BoxConstraints(maxWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          distanceM == null ? label : '$label · ${formatDistance(distanceM!)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      Icon(Icons.location_on, color: color, size: 40),
    ],
  );
}

/// The off-screen form of a beacon: a small arrow at the edge of the view
/// pointing the way to pan, with the distance under it when it's known.
class _BeaconArrow extends StatelessWidget {
  const _BeaconArrow({
    required this.angleRad,
    required this.color,
    this.distanceM,
  });

  final double angleRad;
  final Color color;
  final double? distanceM;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Transform.rotate(
        angle: angleRad,
        child: Icon(Icons.arrow_circle_right, color: color, size: 36),
      ),
      if (distanceM case final d?)
        Text(
          formatDistance(d),
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            shadows: const [Shadow(blurRadius: 6)],
          ),
        ),
    ],
  );
}

/// The bottom checkbox bar: opt in to beacons for nearby watched or
/// recommended lots. Both off by default.
class _FlagBar extends StatelessWidget {
  const _FlagBar({
    required this.watched,
    required this.recommended,
    required this.onToggleWatched,
    required this.onToggleRecommended,
  });

  final bool watched;
  final bool recommended;
  final VoidCallback onToggleWatched;
  final VoidCallback onToggleRecommended;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.7),
    borderRadius: BorderRadius.circular(12),
    child: SizedBox(
      height: _flagBarHeight,
      child: Row(
        children: [
          Expanded(
            child: _FlagCheckbox(
              label: 'Watched',
              value: watched,
              color: AppTheme.warning,
              onToggle: onToggleWatched,
            ),
          ),
          Expanded(
            child: _FlagCheckbox(
              label: 'Recommended',
              value: recommended,
              color: AppTheme.success,
              onToggle: onToggleRecommended,
            ),
          ),
        ],
      ),
    ),
  );
}

class _FlagCheckbox extends StatelessWidget {
  const _FlagCheckbox({
    required this.label,
    required this.value,
    required this.color,
    required this.onToggle,
  });

  final String label;
  final bool value;
  final Color color;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onToggle,
    borderRadius: BorderRadius.circular(12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Checkbox(
          value: value,
          onChanged: (_) => onToggle(),
          activeColor: color,
          checkColor: Colors.black,
          side: const BorderSide(color: Colors.white70, width: 2),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: value ? color : Colors.white,
              fontSize: 14,
              fontWeight: value ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Distance for the beacons and the locate banner. The map's scale is
/// approximate (it comes from a phone-height prior, not measured ranges), so:
/// one decimal close up, whole meters beyond.
String formatDistance(double distanceM) => distanceM < 3
    ? '${distanceM.toStringAsFixed(1)} m'
    : '${distanceM.round()} m';

/// Locate-mode guidance, shown only until the beacon can take over: the
/// user's position relative to the lot isn't known yet, so all we can do is
/// ask for scans (or say the lot isn't on the map at all).
class _LocateBanner extends StatelessWidget {
  const _LocateBanner({required this.state});

  final LocateState state;

  @override
  Widget build(BuildContext context) {
    final (Widget leading, String text) = switch (state) {
      LocateUnmapped() => (
        const Icon(Icons.location_off, color: Colors.white70),
        "This lot hasn't been mapped yet. Scanning nearby labels helps "
            'build the map — check back shortly.',
      ),
      LocateNeedScans() => (
        const Icon(Icons.explore, color: Colors.white),
        'Scan lot labels around you — a few spread apart — so I can figure '
            'out where you are.',
      ),
      // Oriented but with no beacon on screen: the arrow is the guidance.
      LocateAim(:final bearingRightRad, :final distanceM) => (
        Transform.rotate(
          angle: bearingRightRad,
          child: const Icon(Icons.navigation, color: _targetColor, size: 32),
        ),
        'About ${formatDistance(distanceM)} away. Keep scanning labels as you '
            'go to stay oriented.',
      ),
    };
    return Material(
      color: Colors.black.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Text(text, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The single-lot detail card: a fit-to-width photo, the auction's custom
/// label fields, a watch star, and the lot-page button.
class _LotCard extends StatelessWidget {
  const _LotCard({
    required this.meta,
    required this.onOpen,
    required this.onToggleWatch,
  });

  final ArLotMeta meta;
  final void Function() onOpen;
  final void Function() onToggleWatch;

  @override
  Widget build(BuildContext context) {
    // Full-res image when the server has it, otherwise the thumbnail. Fit to
    // the card width; cap the height so the card never grows past ~the bottom
    // half of the screen.
    final imageUrl = meta.imageUrl ?? meta.thumbnailUrl;
    final maxImageHeight = MediaQuery.sizeOf(context).height * 0.4;
    return Material(
      color: Colors.black.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (imageUrl != null) ...[
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxImageHeight),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    imageUrl,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meta.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (meta.lotNumber case final n?)
                            Text(
                              'Lot $n',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          if (meta.sold || meta.removed) ...[
                            const SizedBox(width: 8),
                            Text(
                              meta.sold ? 'SOLD' : 'REMOVED',
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Watch star — sets watch state via the mobile API without
                // opening the web lot page. Hidden until real metadata is in
                // (a stub doesn't know the current watch state).
                if (!meta.isStub)
                  IconButton(
                    onPressed: onToggleWatch,
                    tooltip: meta.watched ? 'Unwatch' : 'Watch',
                    icon: Icon(
                      meta.watched ? Icons.star : Icons.star_border,
                      color: meta.watched ? Colors.amber : Colors.white70,
                    ),
                  ),
              ],
            ),
            for (final field in meta.labelFields)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${field.label}: ',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        field.value,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open lot page'),
            ),
          ],
        ),
      ),
    );
  }
}
