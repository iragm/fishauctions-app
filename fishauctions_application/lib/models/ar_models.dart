/// Data classes for AR lot mode — the `/api/mobile/ar/*` contract
/// (BACKEND_SPEC.md Part 3).
///
/// Parsed defensively like `AppConfig`: the endpoints may not exist yet on a
/// deployment (Part 3 not rolled out), and the overlay must keep working from
/// stubs, so every field tolerates absence.
library;

/// One custom label field shown on the single-lot card — the same custom
/// fields the auction prints on its labels (`Auction.label_print_fields`).
/// The backend resolves names and skips empties; the app just renders pairs.
class ArLabelField {
  const ArLabelField({required this.label, required this.value});

  final String label;
  final String value;

  static ArLabelField? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final label = raw['label'];
    final value = raw['value'];
    if (label is! String || value is! String || value.isEmpty) {
      return null;
    }
    return ArLabelField(label: label, value: value);
  }
}

/// Overlay + card metadata for one scanned lot, from `GET ar/lots/`.
class ArLotMeta {
  const ArLotMeta({
    required this.pk,
    required this.inAuction,
    this.lotNumber,
    this.name,
    this.thumbnailUrl,
    this.watched = false,
    this.recommended = false,
    this.sold = false,
    this.removed = false,
    this.lotUrl,
    this.labelFields = const [],
    this.hasPosition = false,
    this.isStub = false,
  });

  factory ArLotMeta.fromJson(Map<String, dynamic> json) => ArLotMeta(
    pk: (json['pk'] as num?)?.toInt() ?? 0,
    inAuction: json['in_auction'] == true,
    lotNumber: json['lot_number'] as String?,
    name: json['name'] as String?,
    thumbnailUrl: json['thumbnail_url'] as String?,
    watched: json['watched'] == true,
    recommended: json['recommended'] == true,
    sold: json['sold'] == true,
    removed: json['removed'] == true,
    lotUrl: json['lot_url'] as String?,
    labelFields: switch (json['label_fields']) {
      final List<dynamic> raw => [
        for (final f in raw) ?ArLabelField.tryParse(f),
      ],
      _ => const [],
    },
    hasPosition: json['has_position'] == true,
  );

  /// Placeholder when the metadata endpoint is unavailable (older backend or
  /// offline): the QR itself only yields the pk, so overlays show `Lot <pk>`
  /// and the card can still open the lot page by its pk-only URL.
  factory ArLotMeta.stub(int pk) =>
      ArLotMeta(pk: pk, inAuction: true, lotUrl: '/lots/$pk/', isStub: true);

  final int pk;

  /// False for a label from some other auction (neutral chip, no
  /// observations reported for it).
  final bool inAuction;
  final String? lotNumber; // Lot.lot_number_display — NOT the pk
  final String? name;
  final String? thumbnailUrl;
  final bool watched;
  final bool recommended;
  final bool sold;
  final bool removed;
  final String? lotUrl; // site-relative path (Lot.lot_link)
  final List<ArLabelField> labelFields;
  final bool hasPosition;

  /// True when this is a local placeholder, not server data.
  final bool isStub;

  String get displayName {
    final n = name;
    if (n != null && n.isNotEmpty) {
      return n;
    }
    final number = lotNumber;
    return number != null && number.isNotEmpty ? 'Lot $number' : 'Lot $pk';
  }
}

/// The `auction` block of `GET ar/lots/`.
class ArAuctionMeta {
  const ArAuctionMeta({required this.slug, required this.title});

  final String slug;
  final String title;

  static ArAuctionMeta? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    return ArAuctionMeta(
      slug: '${raw['slug'] ?? ''}',
      title: '${raw['title'] ?? ''}',
    );
  }
}

/// One measured detection inside a frame, as POSTed to `ar/observations/`.
///
/// Angle-only by design: bearing and gravity-referenced depression are
/// independent of how large anyone printed their labels, so the solver never
/// touches QR size. Range is the server's problem (triangulation across
/// frames + a phone-height prior on depression).
class ArDetection {
  const ArDetection({
    required this.lotPk,
    required this.bearingDeg,
    required this.depressionDeg,
    required this.quality,
  });

  final int lotPk;

  /// Horizontal angle in the camera frame, positive to the right.
  final double bearingDeg;

  /// Angle of the ray below horizontal (positive looking down at a label).
  final double depressionDeg;
  final double quality; // 0..1

  Map<String, dynamic> toJson() => {
    'lot': lotPk,
    'bearing_deg': double.parse(bearingDeg.toStringAsFixed(2)),
    'depression_deg': double.parse(depressionDeg.toStringAsFixed(2)),
    'quality': double.parse(quality.toStringAsFixed(2)),
  };
}

/// One camera frame's worth of detections. Detections sharing a frame are
/// mutually constraining — that's the signal the server's solver fuses.
class ArFrame {
  const ArFrame({
    required this.frameId,
    required this.capturedAt,
    required this.detections,
    this.yawDeg,
  });

  final String frameId;
  final DateTime capturedAt;
  final List<ArDetection> detections;

  /// Integrated gyro heading at capture, degrees ccw-positive about gravity,
  /// zero at session start. Lets the solver chain frames that saw only one
  /// label each (walking a room scanning one QR at a time) into real
  /// geometry: without it each frame's heading is a free unknown and
  /// single-detection frames constrain nothing but a range circle. Null when
  /// the device delivered no gyro data — absence must mean "unknown", never
  /// "didn't turn". Drift handling is the server's problem (it knows Δt).
  final double? yawDeg;

  Map<String, dynamic> toJson() => {
    'frame_id': frameId,
    'captured_at': capturedAt.toUtc().toIso8601String(),
    if (yawDeg case final yaw?) 'yaw_deg': double.parse(yaw.toStringAsFixed(2)),
    'detections': [for (final d in detections) d.toJson()],
  };
}

/// A solved lot position from `GET ar/positions/` — meters in the auction's
/// arbitrary-but-stable 2D frame.
class ArLotPosition {
  const ArLotPosition({
    required this.lotPk,
    required this.x,
    required this.y,
    required this.confidence,
    this.component,
  });

  final int lotPk;
  final double x;
  final double y;
  final double confidence;

  /// Connectivity-island id from the solver. Positions in different
  /// components share no observations, so their coordinates are *not* in a
  /// common frame — locate mode must never mix them (aiming at a component-B
  /// target from component-A landmarks gives a confident wrong arrow). Null
  /// on backends that predate island labeling (treated as one component).
  final int? component;

  static ArLotPosition? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final lot = (raw['lot'] as num?)?.toInt();
    final x = (raw['x'] as num?)?.toDouble();
    final y = (raw['y'] as num?)?.toDouble();
    if (lot == null || x == null || y == null) {
      return null;
    }
    return ArLotPosition(
      lotPk: lot,
      x: x,
      y: y,
      confidence: (raw['confidence'] as num?)?.toDouble() ?? 0,
      component: (raw['component'] as num?)?.toInt(),
    );
  }
}

/// The full `GET ar/positions/` payload.
class ArPositions {
  const ArPositions({
    required this.byLot,
    required this.unsoldTotal,
    required this.unsoldWithPosition,
  });

  factory ArPositions.fromJson(Map<String, dynamic> json) {
    final byLot = <int, ArLotPosition>{};
    if (json['positions'] case final List<dynamic> raw) {
      for (final entry in raw) {
        final p = ArLotPosition.tryParse(entry);
        if (p != null) {
          byLot[p.lotPk] = p;
        }
      }
    }
    return ArPositions(
      byLot: byLot,
      unsoldTotal: (json['unsold_total'] as num?)?.toInt() ?? 0,
      unsoldWithPosition: (json['unsold_with_position'] as num?)?.toInt() ?? 0,
    );
  }

  final Map<int, ArLotPosition> byLot;
  final int unsoldTotal;
  final int unsoldWithPosition;
}
