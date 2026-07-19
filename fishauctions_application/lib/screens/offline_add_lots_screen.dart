import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/offline_models.dart';
import '../services/offline_sync_service.dart';
import 'offline_common.dart';

/// Offline mirror of the web bulk-add-lots page for one seller (the "Add
/// lots" link next to each name on the users page): their existing lots,
/// then a formset of empty rows — lot name, quantity, donation — matching
/// the web page's simple mode. Rows left blank are ignored, like the web
/// formset. Lot numbers are assigned locally (provisional until synced).
class OfflineAddLotsScreen extends StatefulWidget {
  const OfflineAddLotsScreen({required this.userKey, super.key});

  /// [OfflineUser.key] of the seller these lots belong to.
  final String userKey;

  @override
  State<OfflineAddLotsScreen> createState() => _OfflineAddLotsScreenState();
}

class _LotRow {
  final name = TextEditingController();
  final quantity = TextEditingController(text: '1');
  bool donation = false;

  void dispose() {
    name.dispose();
    quantity.dispose();
  }
}

class _OfflineAddLotsScreenState extends State<OfflineAddLotsScreen> {
  /// Empty rows to start with — the web formset default when the auction has
  /// no max_lots_per_user.
  static const _defaultRows = 5;

  final _service = OfflineSyncService.instance;
  final _rows = [for (var i = 0; i < _defaultRows; i++) _LotRow()];
  bool _saving = false;

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _save(OfflineUser seller) async {
    if (_saving) {
      return;
    }
    final filled = [
      for (final row in _rows)
        if (row.name.text.trim().isNotEmpty) row,
    ];
    if (filled.isEmpty) {
      context.pop();
      return;
    }
    setState(() => _saving = true);
    final numbers = <String>[];
    for (final row in filled) {
      // Recomputed per row — the op recorded below counts toward the max, so
      // consecutive rows get consecutive numbers.
      final lotNumber = _service.store.nextLotNumber(seller: seller);
      numbers.add(lotNumber);
      await _service.recordedOp(
        (store) => store.addLot(
          seller: seller,
          lotNumber: lotNumber,
          lotName: row.name.text.trim(),
          quantity: int.tryParse(row.quantity.text.trim()) ?? 1,
          donation: row.donation,
        ),
      );
    }
    if (mounted) {
      context.pop(
        'Added ${filled.length} lot${filled.length == 1 ? '' : 's'} for '
        '${seller.name} (${numbers.join(', ')})',
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_service, _service.store]),
    builder: (context, _) {
      final store = _service.store;
      final auction = store.auction;
      final seller = store.findUserByKey(widget.userKey);
      if (auction == null || seller == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Add lots')),
          body: const Center(child: Text('User not found in offline data')),
        );
      }
      final existing = [
        for (final lot in store.mergedLots())
          if (lot.sellerKey == seller.key) lot,
      ];
      return Scaffold(
        appBar: AppBar(
          title: Text(
            'Add lots — ${seller.name} (${seller.bidderNumber})',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (existing.isNotEmpty) ...[
              Text(
                'Existing lots',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              for (final lot in existing)
                _existingLotRow(context, auction, lot),
              const Divider(height: 24),
            ],
            Text('New lots', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final row in _rows) _editableRow(row),
            TextButton.icon(
              onPressed: () => setState(() => _rows.add(_LotRow())),
              icon: const Icon(Icons.add),
              label: const Text('Add another row'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : () => unawaited(_save(seller)),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    },
  );

  Widget _existingLotRow(
    BuildContext context,
    OfflineAuction auction,
    OfflineLot lot,
  ) {
    final String status;
    if (lot.isSold) {
      final winner = lot.winnerKey == null
          ? null
          : _service.store.findUserByKey(lot.winnerKey!);
      status =
          'sold to ${winner?.bidderNumber ?? '?'} for '
          '${offlineMoney(auction, lot.winningPrice ?? 0)}';
    } else if (lot.endedUnsold) {
      status = 'not sold';
    } else {
      status = '';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              // Provisional numbers (not yet on the server) are marked, the
              // server may still renumber them on sync.
              lot.isLocal ? '${lot.lotNumber}*' : lot.lotNumber,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(lot.lotName, overflow: TextOverflow.ellipsis)),
          Text(
            status,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }

  Widget _editableRow(_LotRow row) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: row.name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Lot name',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: TextField(
            controller: row.quantity,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Qty',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: row.donation,
              onChanged: (v) => setState(() => row.donation = v ?? false),
            ),
            const Text('Donate', style: TextStyle(fontSize: 10)),
          ],
        ),
      ],
    ),
  );
}
