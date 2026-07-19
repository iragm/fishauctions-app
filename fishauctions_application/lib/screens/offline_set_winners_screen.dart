import 'dart:async';

import 'package:flutter/material.dart';

import '../models/offline_models.dart';
import '../services/offline_store.dart';
import '../services/offline_sync_service.dart';
import 'offline_common.dart';

/// Offline mirror of the web set-winners page
/// (`/auctions/<slug>/lots/set-winners/`): lot number, price, winner fields,
/// a Save button with the same "Ignore errors and save" / "End lot unsold"
/// extras, and a green success banner with Undo. Validation reproduces the
/// web view's messages against the local offline data.
///
/// One deliberate difference: a lot the *server snapshot* already shows as
/// sold can only be re-sold via "Ignore errors and save", and that queued
/// change will come back as a conflict notification if the server still
/// disagrees at sync time — the server copy always wins.
class OfflineSetWinnersScreen extends StatefulWidget {
  const OfflineSetWinnersScreen({super.key});

  @override
  State<OfflineSetWinnersScreen> createState() =>
      _OfflineSetWinnersScreenState();
}

class _OfflineSetWinnersScreenState extends State<OfflineSetWinnersScreen> {
  final _service = OfflineSyncService.instance;
  final _lot = TextEditingController();
  final _price = TextEditingController();
  final _winner = TextEditingController();
  final _lotFocus = FocusNode();

  String? _lotError;
  String? _priceError;
  String? _winnerError;
  String? _successMessage;
  String? _lastOpId;

  OfflineStore get _store => _service.store;

  @override
  void dispose() {
    _lot.dispose();
    _price.dispose();
    _winner.dispose();
    _lotFocus.dispose();
    super.dispose();
  }

  /// The web page shows the lot's name once a number is entered (via the
  /// lot-picture endpoint); offline we show name + seller from local data.
  String _lotHint() {
    final number = _lot.text.trim();
    if (number.isEmpty) {
      return '';
    }
    final lot = _store.findLotByNumber(number);
    if (lot == null) {
      return 'No lot found';
    }
    final seller = lot.sellerKey == null
        ? null
        : _store.findUserByKey(lot.sellerKey!);
    final sellerBit = seller == null ? '' : ' — seller ${seller.bidderNumber}';
    final soldBit = lot.isSold
        ? ' (sold)'
        : lot.endedUnsold
        ? ' (not sold)'
        : '';
    return '${lot.lotName}$sellerBit$soldBit';
  }

  ({OfflineLot? lot, OfflineUser? winner, double? price}) _validate({
    required bool force,
    required bool unsold,
  }) {
    final auction = _store.auction;
    String? lotError;
    String? priceError;
    String? winnerError;

    final lotNumber = _lot.text.trim();
    OfflineLot? lot;
    if (lotNumber.isEmpty) {
      lotError = 'Enter a lot number';
    } else {
      lot = _store.findLotByNumber(lotNumber);
      if (lot == null) {
        lotError = 'No lot found';
      } else if (lot.isSold && !force) {
        lotError = lot.pendingWinnerOpId != null
            ? 'This lot has already been sold'
            : 'This lot has already been sold. It was sold before the '
                  'connection was lost, so use the website to change it.';
      }
    }

    OfflineUser? winner;
    double? price;
    if (!unsold) {
      final winnerNumber = _winner.text.trim();
      if (winnerNumber.isEmpty) {
        winnerError = "Enter the winning bidder's number";
      } else {
        winner = _store.findUserByBidder(winnerNumber);
        if (winner == null) {
          winnerError = 'No bidder found';
        } else if (!winner.invoiceOpen && !force) {
          winnerError = "This user's invoice is not open";
        }
      }

      final priceText = _price.text.trim();
      price = double.tryParse(priceText);
      if (priceText.isEmpty || price == null || price <= 0) {
        price = null;
        priceError = force
            ? 'You can skip some errors, but you still need to enter a price'
            : 'Enter the winning price';
      } else if ((auction?.onlyWholeDollarBids ?? false) &&
          price != price.roundToDouble()) {
        price = null;
        priceError = 'This auction only allows whole dollar amounts';
      }
    }

    setState(() {
      _lotError = lotError;
      _priceError = priceError;
      _winnerError = winnerError;
    });
    final valid = lotError == null && priceError == null && winnerError == null;
    return valid
        ? (lot: lot, winner: winner, price: price)
        : (lot: null, winner: null, price: null);
  }

  Future<void> _save({bool force = false}) async {
    final v = _validate(force: force, unsold: false);
    final lot = v.lot;
    final winner = v.winner;
    final price = v.price;
    if (lot == null || winner == null || price == null) {
      return;
    }
    final op = await _service.recordedOp(
      (store) => store.setWinner(lot: lot, winner: winner, winningPrice: price),
    );
    _finish(
      op,
      'Bidder ${winner.bidderNumber} is now the winner of lot '
      '${lot.lotNumber}',
    );
  }

  Future<void> _endUnsold() async {
    final v = _validate(force: false, unsold: true);
    final lot = v.lot;
    if (lot == null) {
      return;
    }
    final op = await _service.recordedOp((store) => store.endUnsold(lot: lot));
    _finish(op, 'Lot ${lot.lotNumber} ended, not sold');
  }

  void _finish(OfflineOp op, String message) {
    if (!mounted) {
      return;
    }
    _lot.clear();
    _price.clear();
    _winner.clear();
    setState(() {
      _successMessage = message;
      _lastOpId = op.opId;
      _lotError = null;
      _priceError = null;
      _winnerError = null;
    });
    _lotFocus.requestFocus();
  }

  Future<void> _undo() async {
    final opId = _lastOpId;
    if (opId == null) {
      return;
    }
    final removed = await _store.removeOp(opId);
    if (!mounted) {
      return;
    }
    setState(() {
      _successMessage = null;
      _lastOpId = null;
    });
    if (!removed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Already synced — undo it from the website'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_service, _service.store]),
    builder: (context, _) {
      final auction = _store.auction;
      final wholeDollars = auction?.onlyWholeDollarBids ?? false;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            auction == null
                ? 'Set lot winners'
                : 'Set winners — ${auction.title}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            OfflineStatusBanner(service: _service),
            if (_successMessage != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.green.shade700,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(_successMessage!)),
                    TextButton(
                      onPressed: () => unawaited(_undo()),
                      child: const Text('Undo'),
                    ),
                  ],
                ),
              ),
            TextField(
              controller: _lot,
              focusNode: _lotFocus,
              autofocus: true,
              keyboardType: (auction?.useSellerDashLotNumbering ?? false)
                  ? TextInputType.text
                  : TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Lot number',
                helperText: _lotHint(),
                errorText: _lotError,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _price,
              keyboardType: TextInputType.numberWithOptions(
                decimal: !wholeDollars,
              ),
              decoration: InputDecoration(
                labelText: 'Sell price',
                prefixText: auction?.currencySymbol ?? r'$',
                suffixText: wholeDollars ? '.00' : null,
                errorText: _priceError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _winner,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Winner',
                hintText: 'Winning bidder number',
                errorText: _winnerError,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => unawaited(_save()),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                    ),
                    onPressed: () => unawaited(_save()),
                    child: const Text('Save'),
                  ),
                ),
                // The web page's split-button dropdown next to Save.
                PopupMenuButton<String>(
                  icon: const Icon(Icons.arrow_drop_down),
                  tooltip: 'More save options',
                  onSelected: (choice) {
                    switch (choice) {
                      case 'force':
                        unawaited(_save(force: true));
                      case 'unsold':
                        unawaited(_endUnsold());
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'force',
                      child: Text('Ignore errors and save'),
                    ),
                    PopupMenuItem(
                      value: 'unsold',
                      child: Text('End lot unsold'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
