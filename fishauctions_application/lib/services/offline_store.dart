import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/offline_models.dart';

/// Local persistence + merge logic for offline auction management
/// (BACKEND_SPEC.md Part 4). Owns two JSON files in the app documents dir:
///
/// - `offline_snapshot.json` — the last server snapshot of the operator's
///   last admin auction, stored verbatim (server field names);
/// - `offline_journal.json` — the queued [OfflineOp]s not yet accepted by the
///   server, plus any that came back as conflicts (kept for display until the
///   operator dismisses them).
///
/// The *merged view* the offline screens render is: snapshot ⊕ pending ops.
/// Conflicted ops are excluded from the merge — the server copy won, and the
/// op lives on only as a red notification.
///
/// All mutation goes through the sync service, which layers push
/// scheduling on top; this class is deliberately network-free so the merge
/// logic is unit-testable with a temp directory.
class OfflineStore extends ChangeNotifier {
  OfflineStore._();

  /// Test hook: a fresh store with file IO redirected to a temp dir.
  @visibleForTesting
  OfflineStore.forDirectory(Directory dir) : _dirOverride = dir;

  static final OfflineStore instance = OfflineStore._();

  Directory? _dirOverride;
  bool _loaded = false;

  Map<String, dynamic>? _snapshotJson;
  OfflineSnapshot? _snapshot;
  List<OfflineOp> _ops = [];

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<Directory> _dir() async =>
      _dirOverride ?? await getApplicationDocumentsDirectory();

  Future<File> _snapshotFile() async =>
      File('${(await _dir()).path}/offline_snapshot.json');

  Future<File> _journalFile() async =>
      File('${(await _dir()).path}/offline_journal.json');

  /// Idempotent; every public entry point awaits this. Unreadable files are
  /// treated as absent — offline data is a cache, never worth crashing over.
  Future<void> ensureLoaded() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final snapFile = await _snapshotFile();
      if (snapFile.existsSync()) {
        final raw = jsonDecode(await snapFile.readAsString());
        if (raw is Map<String, dynamic>) {
          _snapshotJson = raw;
          _snapshot = OfflineSnapshot.fromJson(raw);
        }
      }
      final journalFile = await _journalFile();
      if (journalFile.existsSync()) {
        final raw = jsonDecode(await journalFile.readAsString());
        final rawOps = (raw is Map ? raw['ops'] : null) as List? ?? const [];
        _ops = [
          for (final op in rawOps)
            if (op is Map<String, dynamic>) OfflineOp.fromJson(op),
        ];
      }
    } on Object catch (e) {
      debugPrint('Offline store load failed (starting empty): $e');
      _snapshotJson = null;
      _snapshot = null;
      _ops = [];
    }
    // The first load completes after listeners (drawer tile, an offline
    // screen opened straight from a cold start) may already have built.
    notifyListeners();
  }

  Future<void> _persistJournal() async {
    final file = await _journalFile();
    await file.writeAsString(
      jsonEncode({
        'ops': [for (final op in _ops) op.toJson()],
      }),
    );
  }

  Future<void> _persistSnapshot() async {
    final file = await _snapshotFile();
    final json = _snapshotJson;
    if (json == null) {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } else {
      await file.writeAsString(jsonEncode(json));
    }
  }

  /// Sign-out: offline data belongs to the account, wipe it all.
  Future<void> clear() async {
    _snapshotJson = null;
    _snapshot = null;
    _ops = [];
    _loaded = true;
    try {
      await _persistSnapshot();
      final journal = await _journalFile();
      if (journal.existsSync()) {
        journal.deleteSync();
      }
    } on Object catch (e) {
      debugPrint('Offline store clear failed: $e');
    }
    notifyListeners();
  }

  // ── State ─────────────────────────────────────────────────────────────────

  OfflineSnapshot? get snapshot => _snapshot;
  OfflineAuction? get auction => _snapshot?.auction;
  bool get hasData => auction != null;

  List<OfflineOp> get pendingOps => [
    for (final op in _ops)
      if (op.status == OfflineOpStatus.pending) op,
  ];

  List<OfflineOp> get conflicts => [
    for (final op in _ops)
      if (op.status == OfflineOpStatus.conflict) op,
  ];

  /// Stores a fresh server snapshot. Pending ops are untouched — they simply
  /// re-apply on top of the newer base.
  Future<void> saveSnapshot(Map<String, dynamic> json) async {
    await ensureLoaded();
    _snapshotJson = json;
    _snapshot = OfflineSnapshot.fromJson(json);
    await _persistSnapshot();
    notifyListeners();
  }

  /// Applies a sync response: accepted ops leave the journal, conflicted ones
  /// are marked and kept for display. Returns the ops that *newly* became
  /// conflicts (for the "needs attention" notification).
  Future<List<OfflineOp>> applyResults(
    List<OfflineSyncOpResult> results, {
    Map<String, dynamic>? snapshotJson,
  }) async {
    await ensureLoaded();
    final byId = {for (final r in results) r.opId: r};
    final newConflicts = <OfflineOp>[];
    _ops.removeWhere((op) => byId[op.opId]?.isResolved ?? false);
    for (final op in _ops) {
      final result = byId[op.opId];
      if (result != null &&
          result.isConflict &&
          op.status != OfflineOpStatus.conflict) {
        op
          ..status = OfflineOpStatus.conflict
          ..conflictKind = result.conflictKind
          ..conflictMessage = result.message;
        newConflicts.add(op);
      }
    }
    if (snapshotJson != null) {
      _snapshotJson = snapshotJson;
      _snapshot = OfflineSnapshot.fromJson(snapshotJson);
      await _persistSnapshot();
    }
    await _persistJournal();
    notifyListeners();
    return newConflicts;
  }

  /// Removes an op outright — "Undo" on a not-yet-synced sale, or dismissing
  /// a conflict notification. Returns false if the op already left the queue.
  Future<bool> removeOp(String opId) async {
    await ensureLoaded();
    final before = _ops.length;
    _ops.removeWhere((op) => op.opId == opId);
    if (_ops.length == before) {
      return false;
    }
    await _persistJournal();
    notifyListeners();
    return true;
  }

  // ── Recording offline changes ─────────────────────────────────────────────

  Future<OfflineOp> _append(
    OfflineOpType type,
    Map<String, dynamic> data,
  ) async {
    final op = OfflineOp(opId: newOpId(), type: type, data: data);
    _ops.add(op);
    await _persistJournal();
    notifyListeners();
    return op;
  }

  /// Mirrors the web add-user modal (bidder number blank on the web means
  /// auto-assign; offline the caller pre-fills [nextBidderNumber] so the
  /// admin can hand the person a concrete number immediately).
  Future<OfflineOp> addUser({
    required String bidderNumber,
    required String name,
    String email = '',
    String phoneNumber = '',
  }) => _append(OfflineOpType.addUser, {
    'bidder_number': bidderNumber,
    'name': name,
    'email': email,
    'phone_number': phoneNumber,
  });

  /// One web bulk-add row. [seller] is the merged-view user.
  Future<OfflineOp> addLot({
    required OfflineUser seller,
    required String lotNumber,
    required String lotName,
    int quantity = 1,
    bool donation = false,
  }) => _append(OfflineOpType.addLot, {
    'seller': seller.wireRef,
    'lot_number': lotNumber,
    'lot_name': lotName,
    'quantity': quantity,
    'donation': donation,
  });

  /// Mirrors the set-winners page's save. Replaces any pending winner op on
  /// the same lot (that's what "force save" over a locally-sold lot means —
  /// the earlier queued sale was the mistake).
  Future<OfflineOp> setWinner({
    required OfflineLot lot,
    required OfflineUser winner,
    required double winningPrice,
  }) async {
    await _removePendingWinnerOp(lot);
    return _append(OfflineOpType.setWinner, {
      'lot': lot.wireRef,
      'winner': winner.wireRef,
      'winning_price': winningPrice.toStringAsFixed(2),
    });
  }

  /// Mirrors the set-winners page's "End lot unsold".
  Future<OfflineOp> endUnsold({required OfflineLot lot}) async {
    await _removePendingWinnerOp(lot);
    return _append(OfflineOpType.setWinner, {
      'lot': lot.wireRef,
      'unsold': true,
    });
  }

  Future<void> _removePendingWinnerOp(OfflineLot lot) async {
    final pending = lot.pendingWinnerOpId;
    if (pending != null) {
      await removeOp(pending);
    }
  }

  // ── Merged view (snapshot ⊕ pending ops) ──────────────────────────────────

  /// All users, server + offline-created, ordered by name like the web users
  /// page. Conflicted add_user ops are excluded (the server copy won).
  List<OfflineUser> mergedUsers() {
    final users = [...?_snapshot?.users];
    for (final op in pendingOps) {
      if (op.type == OfflineOpType.addUser) {
        users.add(
          OfflineUser(
            opId: op.opId,
            bidderNumber: '${op.data['bidder_number'] ?? ''}',
            name: '${op.data['name'] ?? ''}',
            email: '${op.data['email'] ?? ''}',
            phoneNumber: '${op.data['phone_number'] ?? ''}',
          ),
        );
      }
    }
    users.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return users;
  }

  /// All lots with pending add_lot/set_winner ops applied on top.
  List<OfflineLot> mergedLots() {
    final users = mergedUsers();
    final byBidder = {for (final u in users) u.bidderNumber: u};
    final byOp = {
      for (final u in users)
        if (u.opId != null) 'op:${u.opId}': u,
    };

    OfflineUser? resolveUser(String ref) =>
        ref.startsWith('op:') ? byOp[ref] : byBidder[ref];

    final lots = [...?_snapshot?.lots];
    final indexByRef = <String, int>{};
    for (var i = 0; i < lots.length; i++) {
      indexByRef[lots[i].lotNumber] = i;
    }
    for (final op in pendingOps) {
      switch (op.type) {
        case OfflineOpType.addUser:
          break;
        case OfflineOpType.addLot:
          final seller = resolveUser('${op.data['seller']}');
          lots.add(
            OfflineLot(
              opId: op.opId,
              lotNumber: '${op.data['lot_number'] ?? ''}',
              lotName: '${op.data['lot_name'] ?? ''}',
              quantity: op.data['quantity'] is int
                  ? op.data['quantity'] as int
                  : 1,
              donation: op.data['donation'] == true,
              sellerKey: seller?.key,
            ),
          );
          indexByRef[lots.last.lotNumber] = lots.length - 1;
          indexByRef['op:${op.opId}'] = lots.length - 1;
        case OfflineOpType.setWinner:
          final index = indexByRef['${op.data['lot']}'];
          if (index == null) {
            break;
          }
          if (op.data['unsold'] == true) {
            lots[index] = OfflineLot(
              pk: lots[index].pk,
              opId: lots[index].opId,
              lotNumber: lots[index].lotNumber,
              lotName: lots[index].lotName,
              quantity: lots[index].quantity,
              donation: lots[index].donation,
              sellerKey: lots[index].sellerKey,
              endedUnsold: true,
              pendingWinnerOpId: op.opId,
            );
          } else {
            final winner = resolveUser('${op.data['winner']}');
            lots[index] = lots[index].copyWith(
              winnerKey: winner?.key,
              winningPrice: double.tryParse('${op.data['winning_price']}'),
              pendingWinnerOpId: op.opId,
            );
          }
      }
    }
    return lots;
  }

  /// Σ winning_price of merged lots each user won — the offline "total
  /// bought". Deliberately no invoice math (fees, splits, adjustments).
  Map<String, double> totalBoughtByUserKey() {
    final totals = <String, double>{};
    for (final lot in mergedLots()) {
      final winner = lot.winnerKey;
      final price = lot.winningPrice;
      if (winner != null && price != null) {
        totals[winner] = (totals[winner] ?? 0) + price;
      }
    }
    return totals;
  }

  OfflineUser? findUserByBidder(String bidderNumber) {
    for (final user in mergedUsers()) {
      if (user.bidderNumber == bidderNumber) {
        return user;
      }
    }
    return null;
  }

  OfflineUser? findUserByKey(String key) {
    for (final user in mergedUsers()) {
      if (user.key == key) {
        return user;
      }
    }
    return null;
  }

  OfflineLot? findLotByNumber(String lotNumber) {
    for (final lot in mergedLots()) {
      if (lot.lotNumber == lotNumber) {
        return lot;
      }
    }
    return null;
  }

  /// Next free numeric bidder number (max + 1 over the merged users; non-
  /// numeric bidder numbers are ignored, same as they'd never collide).
  String nextBidderNumber() {
    var max = 0;
    for (final user in mergedUsers()) {
      final n = int.tryParse(user.bidderNumber);
      if (n != null && n > max) {
        max = n;
      }
    }
    return '${max + 1}';
  }

  /// Provisional display number for an offline-added lot: in seller-dash
  /// auctions `<bidder>-<n>`, otherwise the global numeric max + 1. Queued
  /// add_lot ops count toward the max, so calling this again after recording
  /// one yields the next number. The server may still renumber on sync (the
  /// sync response echoes the final number), so the UI marks these as
  /// provisional.
  String nextLotNumber({required OfflineUser seller}) {
    final lots = mergedLots();
    if (auction?.useSellerDashLotNumbering ?? false) {
      final prefix = '${seller.bidderNumber}-';
      var max = 0;
      for (final lot in lots) {
        if (lot.lotNumber.startsWith(prefix)) {
          final n = int.tryParse(lot.lotNumber.substring(prefix.length));
          if (n != null && n > max) {
            max = n;
          }
        }
      }
      return '$prefix${max + 1}';
    }
    var max = 0;
    for (final lot in lots) {
      final n = int.tryParse(lot.lotNumber);
      if (n != null && n > max) {
        max = n;
      }
    }
    return '${max + 1}';
  }
}
