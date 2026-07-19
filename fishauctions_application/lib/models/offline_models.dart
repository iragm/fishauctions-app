/// Data model for offline auction management (BACKEND_SPEC.md Part 4).
///
/// Two halves:
/// - the **snapshot** — the server's copy of the operator's last admin
///   auction (users + lots, no images), pulled periodically while online;
/// - the **journal** — an ordered queue of [OfflineOp]s recorded while
///   offline (or while a push is pending), replayed to
///   `POST /api/mobile/offline/sync/` when the connection returns.
///
/// Entities the server doesn't know about yet are referenced by op id
/// (`op:<uuid>`) rather than bidder/lot number, so a server-side renumber of
/// an offline-created row can never redirect a later op at the wrong target.
library;

import 'dart:math';

String newOpId() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class OfflineAuction {
  const OfflineAuction({
    required this.slug,
    required this.title,
    this.currencySymbol = r'$',
    this.useSellerDashLotNumbering = false,
    this.onlyWholeDollarBids = false,
  });

  factory OfflineAuction.fromJson(Map<String, dynamic> json) => OfflineAuction(
    slug: '${json['slug'] ?? ''}',
    title: '${json['title'] ?? ''}',
    currencySymbol: '${json['currency_symbol'] ?? r'$'}',
    useSellerDashLotNumbering: json['use_seller_dash_lot_numbering'] == true,
    onlyWholeDollarBids: json['only_whole_dollar_bids'] == true,
  );

  final String slug;
  final String title;
  final String currencySymbol;
  final bool useSellerDashLotNumbering;
  final bool onlyWholeDollarBids;

  Map<String, dynamic> toJson() => {
    'slug': slug,
    'title': title,
    'currency_symbol': currencySymbol,
    'use_seller_dash_lot_numbering': useSellerDashLotNumbering,
    'only_whole_dollar_bids': onlyWholeDollarBids,
  };
}

/// A person in the auction — a server `AuctionTOS` row (`pk` set) or an
/// offline-created one (`opId` set, not yet on the server).
class OfflineUser {
  const OfflineUser({
    required this.bidderNumber,
    required this.name,
    this.pk,
    this.opId,
    this.email = '',
    this.phoneNumber = '',
    this.invoiceStatus = 'NONE',
  });

  factory OfflineUser.fromJson(Map<String, dynamic> json) => OfflineUser(
    pk: json['pk'] is int ? json['pk'] as int : null,
    bidderNumber: '${json['bidder_number'] ?? ''}',
    name: '${json['name'] ?? ''}',
    email: '${json['email'] ?? ''}',
    phoneNumber: '${json['phone_number'] ?? ''}',
    invoiceStatus: '${json['invoice_status'] ?? 'NONE'}',
  );

  final int? pk;
  final String? opId;
  final String bidderNumber;
  final String name;
  final String email;
  final String phoneNumber;

  /// `DRAFT` / `UNPAID` / `PAID` / `NONE` — from the snapshot; offline-created
  /// users are always `NONE` (no invoice exists yet).
  final String invoiceStatus;

  bool get isLocal => opId != null;

  /// Stable identity for cross-references in the merged view: `pk:<n>` for
  /// server rows, `op:<uuid>` for offline-created ones.
  String get key => isLocal ? 'op:$opId' : 'pk:$pk';

  /// How ops on the wire refer to this user (BACKEND_SPEC.md Part 4
  /// referencing rules).
  String get wireRef => isLocal ? 'op:$opId' : bidderNumber;

  /// Selling/winning requires an open invoice, same as the web set-winners
  /// view ("This user's invoice is not open").
  bool get invoiceOpen => invoiceStatus == 'NONE' || invoiceStatus == 'DRAFT';

  Map<String, dynamic> toJson() => {
    if (pk != null) 'pk': pk,
    'bidder_number': bidderNumber,
    'name': name,
    'email': email,
    'phone_number': phoneNumber,
    'invoice_status': invoiceStatus,
  };
}

/// A lot — a server row (`pk` set) or an offline-added one (`opId` set).
/// In the merged view a pending `set_winner` op overlays [winnerKey] /
/// [winningPrice] / [endedUnsold] and records itself in [pendingWinnerOpId].
class OfflineLot {
  const OfflineLot({
    required this.lotNumber,
    required this.lotName,
    this.pk,
    this.opId,
    this.quantity = 1,
    this.donation = false,
    this.sellerKey,
    this.winnerKey,
    this.winningPrice,
    this.endedUnsold = false,
    this.pendingWinnerOpId,
  });

  factory OfflineLot.fromJson(Map<String, dynamic> json) => OfflineLot(
    pk: json['pk'] is int ? json['pk'] as int : null,
    lotNumber: '${json['lot_number'] ?? ''}',
    lotName: '${json['lot_name'] ?? ''}',
    quantity: json['quantity'] is int ? json['quantity'] as int : 1,
    donation: json['donation'] == true,
    sellerKey: json['seller_pk'] is int ? 'pk:${json['seller_pk']}' : null,
    winnerKey: json['winner_pk'] is int ? 'pk:${json['winner_pk']}' : null,
    winningPrice: _parsePrice(json['winning_price']),
    endedUnsold: json['active'] == false && json['winner_pk'] == null,
  );

  static double? _parsePrice(Object? raw) => switch (raw) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };

  final int? pk;
  final String? opId;
  final String lotNumber;
  final String lotName;
  final int quantity;
  final bool donation;

  /// [OfflineUser.key] of the seller/winner, or null when unknown.
  final String? sellerKey;
  final String? winnerKey;
  final double? winningPrice;

  /// Ended without a winner ("End lot unsold").
  final bool endedUnsold;

  /// The queued `set_winner` op currently applied to this lot in the merged
  /// view, if any — the handle "Undo" uses to retract it before it syncs.
  final String? pendingWinnerOpId;

  bool get isLocal => opId != null;
  bool get isSold => winnerKey != null && winningPrice != null;
  String get wireRef => isLocal ? 'op:$opId' : lotNumber;

  OfflineLot copyWith({
    String? winnerKey,
    double? winningPrice,
    bool? endedUnsold,
    String? pendingWinnerOpId,
  }) => OfflineLot(
    pk: pk,
    opId: opId,
    lotNumber: lotNumber,
    lotName: lotName,
    quantity: quantity,
    donation: donation,
    sellerKey: sellerKey,
    winnerKey: winnerKey ?? this.winnerKey,
    winningPrice: winningPrice ?? this.winningPrice,
    endedUnsold: endedUnsold ?? this.endedUnsold,
    pendingWinnerOpId: pendingWinnerOpId ?? this.pendingWinnerOpId,
  );
}

class OfflineSnapshot {
  const OfflineSnapshot({
    required this.auction,
    required this.users,
    required this.lots,
    this.generatedAt,
  });

  factory OfflineSnapshot.fromJson(Map<String, dynamic> json) {
    final auctionJson = json['auction'];
    return OfflineSnapshot(
      auction: auctionJson is Map<String, dynamic>
          ? OfflineAuction.fromJson(auctionJson)
          : null,
      users: [
        for (final u in json['users'] as List? ?? const [])
          if (u is Map<String, dynamic>) OfflineUser.fromJson(u),
      ],
      lots: [
        for (final l in json['lots'] as List? ?? const [])
          if (l is Map<String, dynamic>) OfflineLot.fromJson(l),
      ],
      generatedAt: DateTime.tryParse('${json['generated_at']}'),
    );
  }

  /// Null when the server said the caller administers no auction.
  final OfflineAuction? auction;
  final List<OfflineUser> users;
  final List<OfflineLot> lots;
  final DateTime? generatedAt;
}

enum OfflineOpType { addUser, addLot, setWinner }

enum OfflineOpStatus { pending, conflict }

/// One queued offline change. [data] is exactly the wire payload minus
/// `op_id`/`type` (see BACKEND_SPEC.md Part 4 for per-type fields), so
/// serialization is trivial and new fields need no model change.
class OfflineOp {
  OfflineOp({
    required this.opId,
    required this.type,
    required this.data,
    DateTime? createdAt,
    this.status = OfflineOpStatus.pending,
    this.conflictKind,
    this.conflictMessage,
  }) : createdAt = createdAt ?? DateTime.now();

  factory OfflineOp.fromJson(Map<String, dynamic> json) => OfflineOp(
    opId: '${json['op_id']}',
    type: _typeFromWire('${json['type']}'),
    data: Map<String, dynamic>.from(json['data'] as Map? ?? const {}),
    createdAt: DateTime.tryParse('${json['created_at']}'),
    status: json['status'] == 'conflict'
        ? OfflineOpStatus.conflict
        : OfflineOpStatus.pending,
    conflictKind: json['conflict_kind'] as String?,
    conflictMessage: json['conflict_message'] as String?,
  );

  final String opId;
  final OfflineOpType type;
  final Map<String, dynamic> data;
  final DateTime createdAt;

  OfflineOpStatus status;
  String? conflictKind;
  String? conflictMessage;

  static const _wireTypes = {
    OfflineOpType.addUser: 'add_user',
    OfflineOpType.addLot: 'add_lot',
    OfflineOpType.setWinner: 'set_winner',
  };

  static OfflineOpType _typeFromWire(String wire) => _wireTypes.entries
      .firstWhere(
        (e) => e.value == wire,
        orElse: () => const MapEntry(OfflineOpType.setWinner, 'set_winner'),
      )
      .key;

  String get wireType => _wireTypes[type]!;

  Map<String, dynamic> toWire() => {'op_id': opId, 'type': wireType, ...data};

  /// Journal persistence — includes local-only bookkeeping the wire omits.
  Map<String, dynamic> toJson() => {
    'op_id': opId,
    'type': wireType,
    'data': data,
    'created_at': createdAt.toIso8601String(),
    'status': status == OfflineOpStatus.conflict ? 'conflict' : 'pending',
    if (conflictKind != null) 'conflict_kind': conflictKind,
    if (conflictMessage != null) 'conflict_message': conflictMessage,
  };

  /// Short human label for conflict lists ("Lot 301 → bidder 14").
  String describe() => switch (type) {
    OfflineOpType.addUser =>
      'Add user ${data['name']} (${data['bidder_number']})',
    OfflineOpType.addLot =>
      'Add lot ${data['lot_number']}: ${data['lot_name']}',
    OfflineOpType.setWinner when data['unsold'] == true =>
      'End lot ${data['lot']} unsold',
    OfflineOpType.setWinner =>
      'Lot ${data['lot']} → bidder ${data['winner']} '
          'for ${data['winning_price']}',
  };
}

/// One per-op entry of the sync response.
class OfflineSyncOpResult {
  const OfflineSyncOpResult({
    required this.opId,
    required this.status,
    this.conflictKind,
    this.message,
    this.bidderNumber,
    this.lotNumber,
  });

  factory OfflineSyncOpResult.fromJson(Map<String, dynamic> json) =>
      OfflineSyncOpResult(
        opId: '${json['op_id']}',
        status: '${json['status']}',
        conflictKind: json['conflict'] as String?,
        message: json['message'] as String?,
        bidderNumber: json['bidder_number'] as String?,
        lotNumber: json['lot_number'] as String?,
      );

  final String opId;

  /// `applied` / `already_applied` / `conflict`.
  final String status;
  final String? conflictKind;
  final String? message;
  final String? bidderNumber;
  final String? lotNumber;

  bool get isConflict => status == 'conflict';
  bool get isResolved => status == 'applied' || status == 'already_applied';
}
