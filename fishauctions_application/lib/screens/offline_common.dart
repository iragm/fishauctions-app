/// Shared bits for the offline screens (users / add user / add lots /
/// set winners).
library;

import 'package:flutter/material.dart';

import '../models/offline_models.dart';
import '../services/offline_sync_service.dart';

/// `$12` for whole amounts, `$12.50` otherwise — matches how the web shows
/// prices without dragging a currency-formatting dependency in.
String offlineMoney(OfflineAuction? auction, double value) {
  final symbol = auction?.currencySymbol ?? r'$';
  final amount = value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2);
  return '$symbol$amount';
}

/// The sync-state strip shown under the offline screens' app bars: red for
/// conflicts needing attention, amber while offline with queued changes,
/// otherwise a quiet "synced" line. Mirrors the web's alert styling.
class OfflineStatusBanner extends StatelessWidget {
  const OfflineStatusBanner({required this.service, super.key});

  final OfflineSyncService service;

  @override
  Widget build(BuildContext context) {
    final conflicts = service.store.conflicts;
    final pending = service.store.pendingOps.length;
    final children = <Widget>[];

    for (final conflict in conflicts) {
      children.add(
        Material(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.15),
          child: ListTile(
            dense: true,
            leading: Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(conflict.conflictMessage ?? 'Change rejected'),
            subtitle: Text(
              '${conflict.describe()} — didn\'t sync; the server\'s copy '
              'was kept. Resolve on the website if needed.',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Dismiss',
              onPressed: () => service.store.removeOp(conflict.opId),
            ),
          ),
        ),
      );
    }

    final String text;
    final IconData icon;
    if (service.offline) {
      icon = Icons.cloud_off;
      text = pending > 0
          ? 'Offline — $pending change${pending == 1 ? '' : 's'} will sync '
                'when the connection returns'
          : 'Offline — using saved auction data';
    } else if (pending > 0) {
      icon = Icons.cloud_upload;
      text = 'Syncing $pending change${pending == 1 ? '' : 's'}…';
    } else {
      icon = Icons.cloud_done;
      final at = service.lastSyncAt;
      text = at == null ? 'Not synced yet' : 'Synced ${_ago(at)}';
    }
    children.add(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Theme.of(context).hintColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  static String _ago(DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inMinutes < 1) {
      return 'just now';
    }
    if (delta.inHours < 1) {
      return '${delta.inMinutes} min ago';
    }
    return '${delta.inHours} h ago';
  }
}
