import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../models/ar_models.dart';
import '../services/ar_api.dart';
import '../services/ar_session.dart';
import '../utils/ar_geometry.dart';
import '../utils/lot_qr.dart';

/// AR lot mode: a live camera view that recognizes lot-label QR codes and
/// overlays what they are. Reached from the web's app-only buttons —
/// `fishauctions://ar/<auction_slug>` on the auction rules page, plus
/// `?locate=<lot_pk>` from a lot page's "Locate with AR".
///
///  * Few labels in frame → name chips at each code; many → dots. A watched
///    lot's marker is a star, a recommended one is green.
///  * One label centered and close → a card with the lot photo, the custom
///    fields its auction prints on labels, and an "open lot page" button
///    (pops back to the WebView with `?src=ar`, which records the scan).
///  * Every sighting is measured (range/bearing from the QR's corner quad +
///    gravity) and batched to the backend, which fuses everyone's scans into
///    the per-auction lot map (BACKEND_SPEC.md Part 3).
///  * Locate mode aims the user at a target lot once the phone has oriented
///    itself off two mapped labels; until then it asks for more scans.
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

enum _CameraAccess { checking, granted, denied, permanentlyDenied }

class _ArLotsScreenState extends State<ArLotsScreen> {
  static const Duration _visibleTtl = Duration(milliseconds: 900);
  static const Duration _cardShowDelay = Duration(milliseconds: 500);
  static const Duration _cardHideDelay = Duration(milliseconds: 800);
  static const Duration _metaRetryInterval = Duration(seconds: 15);
  static const Duration _positionsRefreshInterval = Duration(seconds: 20);
  static const int _maxNamedChips = 3;

  _CameraAccess _access = _CameraAccess.checking;
  MobileScannerController? _scanner;
  late final ArSessionController _session;

  final Map<int, _VisibleLot> _visible = {};
  final Map<int, ArLotMeta> _meta = {};
  final Set<int> _metaPending = {};
  final Map<int, DateTime> _metaAttempt = {};
  ArAuctionMeta? _auction;

  Timer? _sweepTimer;
  Timer? _positionsTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  (double, double, double) _gravity = (0, 9.8, 0); // assume upright until read
  DateTime? _lastGyroAt;

  int? _cardPk;
  int? _cardCandidatePk;
  DateTime _cardCandidateSince = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _cardBrokenAt;
  LocateState? _locate;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    _session = ArSessionController(
      auctionSlug: widget.auctionSlug,
      sender: (sessionId, frames) => ArApi.instance.postObservations(
        widget.auctionSlug,
        sessionId,
        frames,
      ),
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
    // Higher than the 640×480 Android default: a ~1–2 cm printed QR needs the
    // pixels to decode beyond arm's length. (Android-only knob; iOS Vision
    // picks its own buffer.)
    _scanner = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.unrestricted,
      cameraResolution: const Size(1920, 1080),
    );
    _accelSub =
        accelerometerEventStream(
          samplingPeriod: SensorInterval.uiInterval,
        ).listen((e) {
          _gravity = (e.x, e.y, e.z);
          _session.updateGravity(e.x, e.y, e.z);
        }, onError: (Object _) {});
    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen((e) {
          final last = _lastGyroAt;
          _lastGyroAt = e.timestamp;
          if (last == null) {
            return;
          }
          final dt = e.timestamp.difference(last).inMicroseconds / 1e6;
          if (dt <= 0 || dt > 0.5) {
            return; // stream hiccup; integrating over it would smear yaw
          }
          final (gx, gy, gz) = _gravity;
          _session.integrateGyro(e.x, e.y, e.z, dt, gx: gx, gy: gy, gz: gz);
        }, onError: (Object _) {});
    _sweepTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _sweep(),
    );
    setState(() => _access = _CameraAccess.granted);
  }

  Future<void> _initLocate() async {
    final target = widget.locateLotPk!;
    _session.setLocateTarget(
      target,
      await ArApi.instance.fetchPositions(widget.auctionSlug),
    );
    unawaited(_fetchMeta({target}));
    // The server re-solves about once a minute; keep pulling so "scan more
    // lots until yours is mapped" can actually complete.
    _positionsTimer = Timer.periodic(_positionsRefreshInterval, (_) async {
      final positions = await ArApi.instance.fetchPositions(widget.auctionSlug);
      if (mounted && positions != null) {
        _session.updatePositions(positions);
      }
    });
    if (mounted) {
      setState(() => _locate = _session.locateState);
    }
  }

  @override
  void dispose() {
    _sweepTimer?.cancel();
    _positionsTimer?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    unawaited(_session.flush());
    _scanner?.dispose();
    super.dispose();
  }

  // ── Detection ─────────────────────────────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    if (!mounted || capture.size.isEmpty) {
      return;
    }
    final imageSize = capture.size;
    final now = DateTime.now();
    final measurements = <int, ArMeasurement>{};
    final seen = <int, _VisibleLot>{};
    for (final barcode in capture.barcodes) {
      final pk = parseLotQr(barcode.rawValue);
      if (pk == null) {
        continue;
      }
      final sighting = QrSighting.fromCorners(barcode.corners);
      if (sighting == null) {
        continue;
      }
      final measurement = estimateMeasurement(
        sighting: sighting,
        imageSize: imageSize,
        qrEdgeMm: _auction?.qrEdgeMm ?? 12.0,
        pitchDownRad: _session.pitchDownRad,
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
    if (seen.isEmpty) {
      return; // expiry, not absence-in-one-frame, clears chips
    }
    // Only lots believed to be in this auction feed the position solver;
    // unknown-yet lots pass through (the server drops cross-auction ones
    // authoritatively).
    final reportable = <int, ArMeasurement>{
      for (final e in measurements.entries)
        if (_meta[e.key]?.inAuction ?? true) e.key: e.value,
    };
    if (reportable.isNotEmpty) {
      _session.addFrame(reportable);
    }
    unawaited(_fetchMeta(measurements.keys.toSet()));
    setState(() => _visible.addAll(seen));
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
    final changed = _visible.isNotEmpty;
    _visible.removeWhere((_, v) => now.difference(v.lastSeen) > _visibleTtl);

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
      }
    } else if (_cardPk != null) {
      _cardBrokenAt ??= now;
      if (now.difference(_cardBrokenAt!) >= _cardHideDelay) {
        _cardPk = null;
        _cardBrokenAt = null;
      }
    }

    _session.flushIfDue();
    _locate = _session.locateState;
    if (changed || _cardPk != null || _locate != null) {
      setState(() {});
    }
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

  Future<void> _toggleTorch() async {
    await _scanner?.toggleTorch();
    if (mounted) {
      setState(() => _torchOn = !_torchOn);
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
      actions: [
        if (_access == _CameraAccess.granted)
          IconButton(
            onPressed: _toggleTorch,
            tooltip: 'Flashlight',
            icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
          ),
      ],
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

  Widget _buildScanner() => LayoutBuilder(
    builder: (context, constraints) {
      final widgetSize = constraints.biggest;
      final cardMeta = _cardPk == null ? null : _metaFor(_cardPk!);
      return Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _scanner,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _PermissionExplainer(
              message: 'The camera failed to start (${error.errorCode.name}).',
              buttonLabel: 'Try again',
              onPressed: () => _scanner?.start(),
            ),
            placeholderBuilder: (context) =>
                const ColoredBox(color: Colors.black),
          ),
          ..._buildMarkers(widgetSize),
          if (_locate case final locate?)
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: _LocateBanner(
                state: locate,
                targetVisible:
                    widget.locateLotPk != null &&
                    _visible.containsKey(widget.locateLotPk),
              ),
            ),
          if (cardMeta != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _LotCard(
                meta: cardMeta,
                onOpen: () => _openLotPage(cardMeta),
              ),
            ),
          if (_visible.isEmpty && cardMeta == null)
            const Positioned(
              left: 24,
              right: 24,
              bottom: 48,
              child: Text(
                'Point the camera at lot labels',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  shadows: [Shadow(blurRadius: 8)],
                ),
              ),
            ),
        ],
      );
    },
  );

  List<Widget> _buildMarkers(Size widgetSize) {
    final compact = _visible.length > _maxNamedChips;
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
                highlighted: entry.key == target,
              ),
            ),
          );
        }(),
    ];
  }
}

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
  });

  final ArLotMeta meta;
  final bool compact;
  final bool highlighted;

  Color get _accent => meta.watched
      ? Colors.amber
      : meta.recommended
      ? Colors.lightGreenAccent
      : meta.sold || meta.removed
      ? Colors.grey
      : Colors.white;

  @override
  Widget build(BuildContext context) {
    final Widget icon = meta.watched
        ? Icon(Icons.star, size: compact ? 22 : 16, color: Colors.amber)
        : Container(
            width: compact ? 16 : 10,
            height: compact ? 16 : 10,
            decoration: BoxDecoration(
              color: _accent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black45),
            ),
          );
    final marker = compact
        ? icon
        : Container(
            constraints: const BoxConstraints(maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
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
          );
    if (!highlighted) {
      return marker;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: compact ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: compact ? null : BorderRadius.circular(20),
        border: Border.all(color: Colors.lightBlueAccent, width: 3),
      ),
      child: Padding(padding: const EdgeInsets.all(3), child: marker),
    );
  }
}

/// Locate-mode guidance banner.
class _LocateBanner extends StatelessWidget {
  const _LocateBanner({required this.state, required this.targetVisible});

  final LocateState state;
  final bool targetVisible;

  /// Sub-meter precision would be a lie given the ±20% range scale; one
  /// decimal close up, whole meters beyond.
  static String _formatDistance(double distanceM) =>
      distanceM < 3 ? distanceM.toStringAsFixed(1) : '${distanceM.round()}';

  @override
  Widget build(BuildContext context) {
    final (Widget leading, String text) = switch (state) {
      LocateUnmapped() => (
        const Icon(Icons.location_off, color: Colors.white70),
        "This lot hasn't been mapped yet. Scanning nearby labels helps "
            'build the map — check back shortly.',
      ),
      LocateNeedScans(:final fixCount) => (
        const Icon(Icons.explore, color: Colors.white),
        'Scan lot labels around you so I can figure out where you are '
            '($fixCount/2).',
      ),
      LocateAim(:final bearingRightRad, :final distanceM) => (
        Transform.rotate(
          angle: bearingRightRad,
          child: const Icon(
            Icons.navigation,
            color: Colors.lightBlueAccent,
            size: 32,
          ),
        ),
        targetVisible
            ? "It's in view — look for the highlighted label!"
            : 'About ${_formatDistance(distanceM)} m away. Keep scanning '
                  'labels as you go to stay oriented.',
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

/// The single-lot detail card: photo, custom label fields, lot-page button.
class _LotCard extends StatelessWidget {
  const _LotCard({required this.meta, required this.onOpen});

  final ArLotMeta meta;
  final void Function() onOpen;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.85),
    borderRadius: BorderRadius.circular(16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (meta.thumbnailUrl case final url?) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    url,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(width: 12),
              ],
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
                        if (meta.watched) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.star, size: 16, color: Colors.amber),
                        ],
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
