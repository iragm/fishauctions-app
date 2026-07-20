import 'package:fishauctions_application/models/ar_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ArLotMeta', () {
    test('parses a full server row', () {
      final meta = ArLotMeta.fromJson(const {
        'pk': 123,
        'in_auction': true,
        'lot_number': '45',
        'name': 'Apistogramma pair',
        'thumbnail_url': 'https://cdn.example/l.jpg',
        'watched': true,
        'recommended': false,
        'sold': false,
        'removed': false,
        'lot_url': '/lots/123/apisto-pair/',
        'label_fields': [
          {'label': 'Table', 'value': '3'},
          {'label': 'Empty', 'value': ''}, // skipped
          'garbage', // skipped
        ],
        'has_position': true,
      });
      expect(meta.pk, 123);
      expect(meta.inAuction, isTrue);
      expect(meta.displayName, 'Apistogramma pair');
      expect(meta.watched, isTrue);
      expect(meta.labelFields, hasLength(1));
      expect(meta.labelFields.single.label, 'Table');
      expect(meta.hasPosition, isTrue);
      expect(meta.isStub, isFalse);
    });

    test('tolerates a minimal removed row', () {
      final meta = ArLotMeta.fromJson(const {
        'pk': 9,
        'in_auction': false,
        'removed': true,
        'name': null,
      });
      expect(meta.inAuction, isFalse);
      expect(meta.removed, isTrue);
      expect(meta.displayName, 'Lot 9');
      expect(meta.labelFields, isEmpty);
    });

    test('stub keeps the overlay and lot page usable offline', () {
      final stub = ArLotMeta.stub(77);
      expect(stub.isStub, isTrue);
      expect(stub.displayName, 'Lot 77');
      expect(stub.lotUrl, '/lots/77/');
      expect(stub.inAuction, isTrue);
    });

    test('prefers the display lot number over the pk', () {
      final meta = ArLotMeta.fromJson(const {
        'pk': 123,
        'in_auction': true,
        'lot_number': '45',
      });
      expect(meta.displayName, 'Lot 45');
    });
  });

  group('ArAuctionMeta', () {
    test('parses slug and title, rejects non-maps', () {
      final auction = ArAuctionMeta.tryParse(const {
        'slug': 'tfcb',
        'title': 'TFCB Annual',
      });
      expect(auction!.slug, 'tfcb');
      expect(auction.title, 'TFCB Annual');
      expect(ArAuctionMeta.tryParse('nope'), isNull);
    });
  });

  group('ArPositions', () {
    test('parses positions and counters, skipping malformed rows', () {
      final positions = ArPositions.fromJson(const {
        'updated_at': '2026-07-17T15:04:05Z',
        'positions': [
          {'lot': 1, 'x': 1.5, 'y': -2, 'confidence': 0.7},
          {'lot': 2, 'x': null, 'y': 0}, // malformed
          {'x': 3, 'y': 4}, // malformed
        ],
        'unsold_total': 10,
        'unsold_with_position': 4,
      });
      expect(positions.byLot.keys, [1]);
      expect(positions.byLot[1]!.y, -2);
      expect(positions.unsoldTotal, 10);
      expect(positions.unsoldWithPosition, 4);
    });

    test('tolerates an empty payload', () {
      final positions = ArPositions.fromJson(const {});
      expect(positions.byLot, isEmpty);
      expect(positions.unsoldTotal, 0);
    });

    test('parses the island component id, null when the server omits it', () {
      final positions = ArPositions.fromJson(const {
        'positions': [
          {'lot': 1, 'x': 0, 'y': 0, 'component': 2},
          {'lot': 2, 'x': 1, 'y': 1},
        ],
      });
      expect(positions.byLot[1]!.component, 2);
      expect(positions.byLot[2]!.component, isNull);
    });
  });

  group('ArFrame', () {
    test('serializes the angle-only observation payload shape', () {
      final frame = ArFrame(
        frameId: 'f000001',
        capturedAt: DateTime.utc(2026, 7, 17, 12, 30),
        detections: const [
          ArDetection(
            lotPk: 5,
            bearingDeg: -12.3456,
            depressionDeg: 28.912,
            quality: 0.876,
          ),
        ],
      );
      final json = frame.toJson();
      expect(json['frame_id'], 'f000001');
      expect(json['captured_at'], '2026-07-17T12:30:00.000Z');
      final d = (json['detections'] as List).single as Map<String, dynamic>;
      expect(d['lot'], 5);
      expect(d['bearing_deg'], -12.35);
      expect(d['depression_deg'], 28.91);
      expect(d['quality'], 0.88);
      // No size-derived range — the whole point of the angle-only design.
      expect(d.containsKey('range_m'), isFalse);
      // No gyro data ⇒ yaw omitted entirely, never sent as a fake 0.
      expect(json.containsKey('yaw_deg'), isFalse);
    });

    test('carries the session-cumulative gyro heading when available', () {
      final frame = ArFrame(
        frameId: 'f000002',
        capturedAt: DateTime.utc(2026, 7, 17, 12, 31),
        yawDeg: -93.4567,
        detections: const [],
      );
      expect(frame.toJson()['yaw_deg'], -93.46);
    });
  });
}
