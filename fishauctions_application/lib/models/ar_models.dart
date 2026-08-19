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
    this.scientificName,
    this.commonName,
    this.thumbnailUrl,
    this.imageUrl,
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
    scientificName: json['scientific_name'] as String?,
    commonName: json['common_name'] as String?,
    thumbnailUrl: json['thumbnail_url'] as String?,
    imageUrl: json['image_url'] as String?,
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

  /// The lot's *other* name, and at most one of these two is ever filled —
  /// `Lot.scientific_name_line` / `Lot.common_name_line` are one display rule
  /// with two halves, and the backend decides which half applies.
  ///
  /// A lot the seller called "Yellow lab" carries *Labidochromis caeruleus*
  /// here; one they called "Labidochromis caeruleus" carries "Yellow lab"
  /// instead, because repeating the words already in the big slot is not new
  /// information. Blank for hardware, mixed lots, and any auction whose
  /// `use_scientific_name` is off — the app never has to know which of those it
  /// is, it just draws what it is given.
  ///
  /// Worth the space on a chip in a way almost nothing else is: in a hall you
  /// can read a lot's name from across the room but not its label, and the
  /// species is the thing a buyer is actually scanning for.
  final String? scientificName;
  final String? commonName;

  final String? thumbnailUrl;

  /// Full-size primary image (not the 250×150 thumbnail), for the single-lot
  /// card's fit-to-width photo. Null when the lot has no image or on a stub.
  final String? imageUrl;
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

  /// The second line to draw under [displayName], or null when there isn't
  /// one. [scientificNameIsSecondLine] says whether to italicise it — a
  /// binomial is set in italics, a common name is not.
  String? get secondLine {
    for (final candidate in [scientificName, commonName]) {
      if (candidate != null && candidate.isNotEmpty) {
        return candidate;
      }
    }
    return null;
  }

  bool get scientificNameIsSecondLine =>
      scientificName != null && scientificName!.isNotEmpty;

  /// Copy with an overridden [watched] flag — for the card's watch star's
  /// optimistic toggle before/around the server round trip.
  ArLotMeta copyWith({bool? watched}) => ArLotMeta(
    pk: pk,
    inAuction: inAuction,
    lotNumber: lotNumber,
    name: name,
    scientificName: scientificName,
    commonName: commonName,
    thumbnailUrl: thumbnailUrl,
    imageUrl: imageUrl,
    watched: watched ?? this.watched,
    recommended: recommended,
    sold: sold,
    removed: removed,
    lotUrl: lotUrl,
    labelFields: labelFields,
    hasPosition: hasPosition,
    isStub: isStub,
  );
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

/// One AR interaction with a lot, POSTed to `ar/events/`. The backend turns
/// each into a lot `PageView` tagged `ar_scan` / `ar_zoom` / `ar_zoom_full`,
/// de-duped server-side to one row per user per lot per type — so these are
/// "how many people found this lot in AR", not a hit counter. The app sends
/// each (lot, type) at most once per session for the same reason.
///
/// The app has no literal zoom control (ARCore/ARKit own the camera), so the
/// funnel maps onto how close the user actually got to the label:
///
///  * [scanned] — the label's QR was read at all.
///  * [zoomed] — the user aimed at that one label from close up (it filled
///    enough of a centered frame to be the detail card's candidate).
///  * [zoomedFull] — they held it there and the detail card opened.
enum ArEventType {
  scanned('scanned'),
  zoomed('zoomed'),
  zoomedFull('zoomed_full');

  const ArEventType(this.wire);

  /// The `event` value the backend's ArEventSerializer accepts.
  final String wire;
}

/// One (lot, interaction) pair for `POST ar/events/`.
class ArEvent {
  const ArEvent({required this.lotPk, required this.type});

  final int lotPk;
  final ArEventType type;

  Map<String, dynamic> toJson() => {'lot': lotPk, 'event': type.wire};
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
    this.headingDeg,
    this.odoXM,
    this.odoYM,
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

  /// Absolute compass heading of the camera at capture — degrees clockwise
  /// from **magnetic** north (0 = N, 90 = E), tilt-compensated. Unlike
  /// [yawDeg] (relative, arbitrary zero) this is an absolute reference, so the
  /// solver can fix each disconnected island's *orientation* as a soft prior.
  /// Null when no magnetometer reading is available. BACKEND_SPEC.md Part 5.
  final double? headingDeg;

  /// Cumulative planar displacement since session start (meters), in the
  /// same session-fixed frame as [yawDeg]: +x is the camera's forward
  /// direction at yaw 0 (session start), +y is 90° counterclockwise (the
  /// camera's left). `(0, 0)` is a legitimate value — it's what the first
  /// tracked frame reports — so null means "no tracker", never "didn't
  /// move". Sent as a pair or not at all (both null unless a real tracker
  /// reading backs them). BACKEND_SPEC.md Part 5.
  final double? odoXM;
  final double? odoYM;

  Map<String, dynamic> toJson() => {
    'frame_id': frameId,
    'captured_at': capturedAt.toUtc().toIso8601String(),
    if (yawDeg case final yaw?) 'yaw_deg': double.parse(yaw.toStringAsFixed(2)),
    if (headingDeg case final h?)
      'heading_deg': double.parse(h.toStringAsFixed(1)),
    // Odometry is all-or-nothing too, and (0, 0) must survive — the pair is
    // gated on non-null, not on truthiness.
    if (odoXM case final ox?)
      if (odoYM case final oy?) ...{
        'odo_x_m': double.parse(ox.toStringAsFixed(3)),
        'odo_y_m': double.parse(oy.toStringAsFixed(3)),
      },
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

/// What the lot-scanning screen pops when the user taps "open lot page".
///
/// Carries the lot's **pk** alongside the path deliberately. The pk can't be
/// read back out of the path: an in-auction lot's URL is
/// `/auctions/<slug>/lots/<lot_number>/<lot-slug>/`, where the number after
/// `lots/` is the auction's `lot_number_display` — often not a pk at all
/// (`BOB-1` in a seller-dash auction), and a *different* integer from the pk
/// when it is numeric. The shell needs the real pk to re-enter lot scanning
/// aimed at this lot, so the screen that already knows it says so.
class ArLotPageRequest {
  const ArLotPageRequest({required this.path, required this.lotPk});

  /// Site-relative path to load in the shell, including `?src=ar`.
  final String path;

  /// The lot's primary key, for `fishauctions://ar/<slug>?locate=<pk>`.
  final int lotPk;
}
