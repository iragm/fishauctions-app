import 'dart:io';

import 'package:fishauctions_application/models/offline_models.dart';
import 'package:fishauctions_application/services/offline_store.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _snapshot({
  bool sellerDash = false,
  List<Map<String, dynamic>>? users,
  List<Map<String, dynamic>>? lots,
}) => {
  'auction': {
    'slug': 'club-2026',
    'title': 'Club Auction',
    'currency_symbol': r'$',
    'use_seller_dash_lot_numbering': sellerDash,
    'only_whole_dollar_bids': false,
  },
  'users':
      users ??
      [
        {
          'pk': 1,
          'bidder_number': '10',
          'name': 'Zed',
          'invoice_status': 'DRAFT',
        },
        {
          'pk': 2,
          'bidder_number': '11',
          'name': 'Ada',
          'invoice_status': 'PAID',
        },
      ],
  'lots':
      lots ??
      [
        {
          'pk': 100,
          'lot_number': '55',
          'lot_name': 'Apisto pair',
          'seller_pk': 1,
          'winner_pk': null,
          'winning_price': null,
          'active': true,
        },
        {
          'pk': 101,
          'lot_number': '56',
          'lot_name': 'Plants',
          'seller_pk': 1,
          'winner_pk': 2,
          'winning_price': '10.00',
          'active': false,
        },
      ],
  'generated_at': '2026-07-18T15:00:00Z',
};

void main() {
  late Directory dir;
  late OfflineStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline_store_test');
    store = OfflineStore.forDirectory(dir);
    await store.ensureLoaded();
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('starts empty', () {
    expect(store.hasData, isFalse);
    expect(store.pendingOps, isEmpty);
    expect(store.mergedUsers(), isEmpty);
  });

  test('saveSnapshot exposes users sorted by name', () async {
    await store.saveSnapshot(_snapshot());
    expect(store.hasData, isTrue);
    expect(store.auction?.slug, 'club-2026');
    expect([for (final u in store.mergedUsers()) u.name], ['Ada', 'Zed']);
  });

  test('offline-added users merge in and bidder numbers advance', () async {
    await store.saveSnapshot(_snapshot());
    expect(store.nextBidderNumber(), '12');

    await store.addUser(bidderNumber: '12', name: 'New Guy');
    final users = store.mergedUsers();
    expect(users, hasLength(3));
    final local = store.findUserByBidder('12')!;
    expect(local.isLocal, isTrue);
    expect(local.wireRef, startsWith('op:'));
    expect(store.nextBidderNumber(), '13');
  });

  test('offline-added lots merge with provisional global numbers', () async {
    await store.saveSnapshot(_snapshot());
    final seller = store.findUserByBidder('10')!;
    expect(store.nextLotNumber(seller: seller), '57');

    await store.addLot(
      seller: seller,
      lotNumber: '57',
      lotName: 'Bag of plants',
    );
    final lot = store.findLotByNumber('57')!;
    expect(lot.isLocal, isTrue);
    expect(lot.sellerKey, seller.key);
    expect(store.nextLotNumber(seller: seller), '58');
  });

  test('seller-dash auctions number per seller', () async {
    await store.saveSnapshot(
      _snapshot(
        sellerDash: true,
        lots: [
          {
            'pk': 100,
            'lot_number': '10-3',
            'lot_name': 'x',
            'seller_pk': 1,
            'active': true,
          },
        ],
      ),
    );
    final seller = store.findUserByBidder('10')!;
    final other = store.findUserByBidder('11')!;
    expect(store.nextLotNumber(seller: seller), '10-4');
    expect(store.nextLotNumber(seller: other), '11-1');
  });

  test('setWinner overlays the lot and feeds total bought', () async {
    await store.saveSnapshot(_snapshot());
    final lot = store.findLotByNumber('55')!;
    final winner = store.findUserByBidder('11')!;

    await store.setWinner(lot: lot, winner: winner, winningPrice: 12);

    final sold = store.findLotByNumber('55')!;
    expect(sold.isSold, isTrue);
    expect(sold.winnerKey, winner.key);
    expect(sold.pendingWinnerOpId, isNotNull);
    // 10.00 from the server snapshot + 12 pending.
    expect(store.totalBoughtByUserKey()[winner.key], 22.0);
  });

  test('re-selling a locally sold lot replaces the pending op', () async {
    await store.saveSnapshot(_snapshot());
    final winner1 = store.findUserByBidder('10')!;
    final winner2 = store.findUserByBidder('11')!;

    await store.setWinner(
      lot: store.findLotByNumber('55')!,
      winner: winner1,
      winningPrice: 5,
    );
    await store.setWinner(
      lot: store.findLotByNumber('55')!,
      winner: winner2,
      winningPrice: 8,
    );

    final winnerOps = [
      for (final op in store.pendingOps)
        if (op.type == OfflineOpType.setWinner) op,
    ];
    expect(winnerOps, hasLength(1));
    expect(store.findLotByNumber('55')!.winnerKey, winner2.key);
  });

  test('endUnsold marks the merged lot', () async {
    await store.saveSnapshot(_snapshot());
    await store.endUnsold(lot: store.findLotByNumber('55')!);
    final lot = store.findLotByNumber('55')!;
    expect(lot.endedUnsold, isTrue);
    expect(lot.isSold, isFalse);
  });

  test('set_winner ops on offline-added lots resolve via op refs', () async {
    await store.saveSnapshot(_snapshot());
    await store.addUser(bidderNumber: '12', name: 'New Guy');
    final localSeller = store.findUserByBidder('12')!;
    await store.addLot(seller: localSeller, lotNumber: '57', lotName: 'Shrimp');
    await store.setWinner(
      lot: store.findLotByNumber('57')!,
      winner: localSeller,
      winningPrice: 3,
    );

    final op = store.pendingOps.last;
    expect(op.data['lot'], startsWith('op:'));
    expect(op.data['winner'], startsWith('op:'));
    expect(store.totalBoughtByUserKey()[localSeller.key], 3.0);
  });

  test('applyResults drops accepted ops and marks conflicts once', () async {
    await store.saveSnapshot(_snapshot());
    final accepted = await store.addUser(bidderNumber: '12', name: 'A');
    final conflicted = await store.setWinner(
      lot: store.findLotByNumber('55')!,
      winner: store.findUserByBidder('11')!,
      winningPrice: 12,
    );

    final newConflicts = await store.applyResults([
      OfflineSyncOpResult.fromJson({
        'op_id': accepted.opId,
        'status': 'applied',
      }),
      OfflineSyncOpResult.fromJson({
        'op_id': conflicted.opId,
        'status': 'conflict',
        'conflict': 'winner_conflict',
        'message': 'Lot 55 was already sold to bidder 10',
      }),
    ], snapshotJson: _snapshot());

    expect(newConflicts, hasLength(1));
    expect(store.pendingOps, isEmpty);
    expect(store.conflicts, hasLength(1));
    expect(store.conflicts.first.conflictMessage, contains('already sold'));
    // A conflicted winner op no longer overlays the merged view.
    expect(store.findLotByNumber('55')!.isSold, isFalse);

    // Replaying the same conflict result must not re-notify.
    final again = await store.applyResults([
      OfflineSyncOpResult.fromJson({
        'op_id': conflicted.opId,
        'status': 'conflict',
        'conflict': 'winner_conflict',
        'message': 'Lot 55 was already sold to bidder 10',
      }),
    ]);
    expect(again, isEmpty);
  });

  test('removeOp is the undo path and reports already-gone', () async {
    await store.saveSnapshot(_snapshot());
    final op = await store.setWinner(
      lot: store.findLotByNumber('55')!,
      winner: store.findUserByBidder('11')!,
      winningPrice: 12,
    );
    expect(await store.removeOp(op.opId), isTrue);
    expect(store.findLotByNumber('55')!.isSold, isFalse);
    expect(await store.removeOp(op.opId), isFalse);
  });

  test('persists snapshot and journal across instances', () async {
    await store.saveSnapshot(_snapshot());
    await store.addUser(bidderNumber: '12', name: 'New Guy');

    final reopened = OfflineStore.forDirectory(dir);
    await reopened.ensureLoaded();
    expect(reopened.hasData, isTrue);
    expect(reopened.pendingOps, hasLength(1));
    expect(reopened.findUserByBidder('12')?.name, 'New Guy');
  });

  test('clear wipes everything', () async {
    await store.saveSnapshot(_snapshot());
    await store.addUser(bidderNumber: '12', name: 'New Guy');
    await store.clear();

    expect(store.hasData, isFalse);
    expect(store.pendingOps, isEmpty);
    final reopened = OfflineStore.forDirectory(dir);
    await reopened.ensureLoaded();
    expect(reopened.hasData, isFalse);
    expect(reopened.pendingOps, isEmpty);
  });
}
