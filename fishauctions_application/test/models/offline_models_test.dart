import 'package:fishauctions_application/models/offline_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('newOpId', () {
    test('is a v4 uuid and unique', () {
      final a = newOpId();
      final b = newOpId();
      expect(a, isNot(b));
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
          r'[0-9a-f]{12}$',
        ).hasMatch(a),
        isTrue,
        reason: a,
      );
    });
  });

  group('OfflineSnapshot.fromJson', () {
    test('parses the server shape', () {
      final snapshot = OfflineSnapshot.fromJson({
        'auction': {
          'slug': 'club-2026',
          'title': 'Club Auction',
          'currency_symbol': r'$',
          'use_seller_dash_lot_numbering': false,
          'only_whole_dollar_bids': true,
        },
        'users': [
          {
            'pk': 12,
            'bidder_number': '14',
            'name': 'Ada B',
            'email': 'a@b.c',
            'phone_number': '555',
            'invoice_status': 'DRAFT',
          },
        ],
        'lots': [
          {
            'pk': 901,
            'lot_number': '55',
            'lot_name': 'Apisto pair',
            'quantity': 2,
            'donation': false,
            'seller_pk': 12,
            'winner_pk': null,
            'winning_price': null,
            'active': true,
          },
          {
            'pk': 902,
            'lot_number': '56',
            'lot_name': 'Plants',
            'quantity': 1,
            'donation': true,
            'seller_pk': 12,
            'winner_pk': 12,
            'winning_price': '12.50',
            'active': false,
          },
        ],
        'generated_at': '2026-07-18T15:04:05Z',
      });

      expect(snapshot.auction?.slug, 'club-2026');
      expect(snapshot.auction?.onlyWholeDollarBids, isTrue);
      expect(snapshot.users, hasLength(1));
      expect(snapshot.users.first.key, 'pk:12');
      expect(snapshot.users.first.wireRef, '14');
      expect(snapshot.users.first.invoiceOpen, isTrue);
      expect(snapshot.lots, hasLength(2));
      expect(snapshot.lots.first.sellerKey, 'pk:12');
      expect(snapshot.lots.first.isSold, isFalse);
      expect(snapshot.lots.last.winnerKey, 'pk:12');
      expect(snapshot.lots.last.winningPrice, 12.50);
      expect(snapshot.lots.last.isSold, isTrue);
      expect(snapshot.generatedAt, isNotNull);
    });

    test('null auction means no admin auction', () {
      final snapshot = OfflineSnapshot.fromJson({
        'auction': null,
        'users': [],
        'lots': [],
      });
      expect(snapshot.auction, isNull);
    });

    test('a lot ended without a winner is endedUnsold', () {
      final lot = OfflineLot.fromJson({
        'pk': 1,
        'lot_number': '9',
        'lot_name': 'x',
        'active': false,
        'winner_pk': null,
      });
      expect(lot.endedUnsold, isTrue);
      expect(lot.isSold, isFalse);
    });
  });

  group('OfflineOp', () {
    test('journal round-trip keeps conflict state', () {
      final op =
          OfflineOp(
              opId: newOpId(),
              type: OfflineOpType.setWinner,
              data: {'lot': '55', 'winner': '14', 'winning_price': '12.00'},
            )
            ..status = OfflineOpStatus.conflict
            ..conflictKind = 'winner_conflict'
            ..conflictMessage = 'sold to someone else';

      final restored = OfflineOp.fromJson(op.toJson());
      expect(restored.opId, op.opId);
      expect(restored.type, OfflineOpType.setWinner);
      expect(restored.data['lot'], '55');
      expect(restored.status, OfflineOpStatus.conflict);
      expect(restored.conflictKind, 'winner_conflict');
      expect(restored.conflictMessage, 'sold to someone else');
    });

    test('toWire flattens data next to op_id and type', () {
      final op = OfflineOp(
        opId: 'abc',
        type: OfflineOpType.addUser,
        data: {'bidder_number': '58', 'name': 'New Guy'},
      );
      expect(op.toWire(), {
        'op_id': 'abc',
        'type': 'add_user',
        'bidder_number': '58',
        'name': 'New Guy',
      });
    });

    test('describe covers each op type', () {
      expect(
        OfflineOp(
          opId: 'a',
          type: OfflineOpType.setWinner,
          data: {'lot': '3', 'unsold': true},
        ).describe(),
        contains('unsold'),
      );
      expect(
        OfflineOp(
          opId: 'a',
          type: OfflineOpType.addLot,
          data: {'lot_number': '7', 'lot_name': 'Guppies'},
        ).describe(),
        contains('Guppies'),
      );
    });
  });

  group('OfflineSyncOpResult', () {
    test('parses applied and conflict entries', () {
      final applied = OfflineSyncOpResult.fromJson({
        'op_id': 'a',
        'status': 'applied',
        'lot_number': '301',
      });
      expect(applied.isResolved, isTrue);
      expect(applied.isConflict, isFalse);
      expect(applied.lotNumber, '301');

      final conflict = OfflineSyncOpResult.fromJson({
        'op_id': 'b',
        'status': 'conflict',
        'conflict': 'winner_conflict',
        'message': 'Lot 301 was already sold',
      });
      expect(conflict.isConflict, isTrue);
      expect(conflict.isResolved, isFalse);
      expect(conflict.conflictKind, 'winner_conflict');
    });
  });
}
