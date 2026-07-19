import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/offline_models.dart';
import '../services/offline_sync_service.dart';
import 'offline_common.dart';

/// Offline mirror of the web users page (`/auctions/<slug>/users/`) for the
/// operator's last admin auction: every user with their total bought (plain
/// Σ winning_price from offline data — no invoice math), an **Add lots**
/// button per row, and **Add user** / **Set lot winners** at the top. Works
/// entirely from the local snapshot + queued ops; the status banner shows
/// sync state and conflicts.
class OfflineUsersScreen extends StatefulWidget {
  const OfflineUsersScreen({super.key});

  @override
  State<OfflineUsersScreen> createState() => _OfflineUsersScreenState();
}

class _OfflineUsersScreenState extends State<OfflineUsersScreen> {
  final _service = OfflineSyncService.instance;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    unawaited(_service.store.ensureLoaded());
  }

  List<OfflineUser> _filteredUsers() {
    final users = _service.store.mergedUsers();
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) {
      return users;
    }
    return [
      for (final u in users)
        if (u.bidderNumber.toLowerCase().contains(q) ||
            u.name.toLowerCase().contains(q) ||
            u.email.toLowerCase().contains(q))
          u,
    ];
  }

  Future<void> _open(String location) async {
    final message = await context.push(location);
    if (message is String && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_service, _service.store]),
    builder: (context, _) {
      final store = _service.store;
      final auction = store.auction;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            auction == null ? 'Offline mode' : 'Users — ${auction.title}',
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: _service.syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              tooltip: 'Sync now',
              onPressed: _service.syncing
                  ? null
                  : () => unawaited(_service.sync()),
            ),
          ],
        ),
        body: auction == null ? _empty(context) : _body(context, auction),
      );
    },
  );

  /// Shown when there's no snapshot yet — first run offline, a deployment
  /// without the sync endpoints, or an account that administers no auction.
  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).hintColor),
          const SizedBox(height: 16),
          Text(
            'No offline auction data yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Offline mode keeps a copy of the last auction you admin. '
            'Open the app with a connection once and it will sync '
            'automatically.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );

  Widget _body(BuildContext context, OfflineAuction auction) {
    final users = _filteredUsers();
    final totals = _service.store.totalBoughtByUserKey();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OfflineStatusBanner(service: _service),
        // Header actions, mirroring the web users page header (+ the
        // set-winners button the request wants at the top of this page).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => unawaited(_open('/offline/add-user')),
                icon: const Icon(Icons.person_add, size: 18),
                label: const Text('Add user'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => unawaited(_open('/offline/set-winners')),
                icon: const Icon(Icons.gavel, size: 18),
                label: const Text('Set lot winners'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: 'Filter by bidder number, name, email...',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
        ),
        // Column headers, like the web table's ID / Name / (invoice) row.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              SizedBox(width: 52, child: _header(context, 'ID')),
              Expanded(child: _header(context, 'Name')),
              _header(context, 'Bought'),
              // Space matching the per-row "Add lots" button.
              const SizedBox(width: 96),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: users.isEmpty
              ? Center(
                  child: Text(
                    _filter.isEmpty ? 'No users yet' : 'No matching users',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.separated(
                  itemCount: users.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) =>
                      _userRow(context, auction, users[i], totals),
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).hintColor,
      fontWeight: FontWeight.bold,
    ),
  );

  Widget _userRow(
    BuildContext context,
    OfflineAuction auction,
    OfflineUser user,
    Map<String, double> totals,
  ) {
    final total = totals[user.key];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              user.bidderNumber,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(user.name, overflow: TextOverflow.ellipsis),
                    ),
                    if (user.isLocal) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: 'Added offline — not synced yet',
                        child: Icon(
                          Icons.cloud_upload,
                          size: 14,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ],
                ),
                if (user.email.isNotEmpty)
                  Text(
                    user.email,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
              ],
            ),
          ),
          Text(total == null ? '—' : offlineMoney(auction, total)),
          SizedBox(
            width: 96,
            child: TextButton.icon(
              onPressed: () => unawaited(
                _open('/offline/add-lots/${Uri.encodeComponent(user.key)}'),
              ),
              icon: const Icon(Icons.post_add, size: 18),
              label: const Text('Add lots'),
            ),
          ),
        ],
      ),
    );
  }
}
