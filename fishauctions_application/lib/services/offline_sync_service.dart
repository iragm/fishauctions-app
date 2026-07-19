import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/offline_models.dart';
import 'offline_api.dart';
import 'offline_store.dart';

/// Orchestrates offline auction sync (BACKEND_SPEC.md Part 4) on top of
/// [OfflineStore] (persistence + merge) and [OfflineApi] (HTTP):
///
/// - **Pull**: while the shell is up, periodically refresh the snapshot of
///   the operator's last admin auction so going offline always has recent
///   data to fall back on. Also refreshed on app resume.
/// - **Push**: every recorded change schedules a debounced push, so while
///   online, offline-screen changes reach the server within seconds; while
///   offline the queue just grows and the periodic timer keeps retrying.
///   A push both drains the queue *and* refreshes the snapshot (one round
///   trip), so pull-after-push is never needed.
/// - **Conflicts**: ops the server rejected surface via [newConflicts] (for
///   the shell's "needs attention" snackbar) and stay listed in the store
///   until dismissed. The server copy always wins — this service never
///   retries a conflicted op.
///
/// The offline *screens* record changes through [recordedOp]-wrapped store
/// mutations below rather than on the store directly, so every change gets a
/// push scheduled.
class OfflineSyncService extends ChangeNotifier {
  OfflineSyncService._({OfflineStore? store, OfflineApi? api})
    : store = store ?? OfflineStore.instance,
      api = api ?? OfflineApi.instance;

  /// Test hook: a fresh service over injected store/api.
  @visibleForTesting
  OfflineSyncService.forTest({required this.store, required this.api});

  static final OfflineSyncService instance = OfflineSyncService._();

  final OfflineStore store;
  final OfflineApi api;

  static const _pullInterval = Duration(minutes: 5);
  static const _pushDebounce = Duration(seconds: 3);

  Timer? _periodic;
  Timer? _debounce;
  bool _syncing = false;
  bool _queued = false;

  bool _offline = false;
  DateTime? _lastSyncAt;

  /// Ops that just came back as conflicts — the WebView shell listens and
  /// shows a "needs attention" snackbar, then calls [consumeNewConflicts].
  final ValueNotifier<List<OfflineOp>> newConflicts = ValueNotifier(const []);

  /// True when the last sync attempt failed on the network (the app is
  /// probably offline). Cleared by the next successful attempt.
  bool get offline => _offline;

  bool get syncing => _syncing;
  DateTime? get lastSyncAt => _lastSyncAt;

  /// Begins periodic syncing. Idempotent — the shell calls this on mount.
  void start() {
    if (_periodic != null) {
      return;
    }
    _periodic = Timer.periodic(_pullInterval, (_) => unawaited(sync()));
    unawaited(sync());
  }

  /// App returned to the foreground — data may be minutes stale.
  void onAppResumed() {
    if (_periodic != null) {
      unawaited(sync());
    }
  }

  /// Sign-out: stop syncing and wipe the account's offline data.
  Future<void> stopAndClear() async {
    _periodic?.cancel();
    _periodic = null;
    _debounce?.cancel();
    _debounce = null;
    newConflicts.value = const [];
    await store.clear();
    notifyListeners();
  }

  List<OfflineOp> consumeNewConflicts() {
    final conflicts = newConflicts.value;
    newConflicts.value = const [];
    return conflicts;
  }

  /// One sync attempt: push the queue when there is one (the response also
  /// refreshes the snapshot), otherwise just pull. Coalesces overlapping
  /// calls — a call during a running sync queues exactly one follow-up.
  Future<void> sync() async {
    if (_syncing) {
      _queued = true;
      return;
    }
    _syncing = true;
    notifyListeners();
    try {
      await store.ensureLoaded();
      final pending = store.pendingOps;
      if (pending.isNotEmpty && store.auction != null) {
        await _push(pending);
      } else {
        await _pull();
      }
    } finally {
      _syncing = false;
      notifyListeners();
      if (_queued) {
        _queued = false;
        unawaited(sync());
      }
    }
  }

  Future<void> _pull() async {
    final result = await api.fetchSnapshot();
    switch (result.status) {
      case OfflineApiStatus.ok:
        await store.saveSnapshot(result.snapshotJson!);
        _markOnline();
      case OfflineApiStatus.noAuction:
        // Definitive server answer: not an auction admin (anymore). Keep any
        // existing data — it may be admin-ship lapsing mid-auction — but
        // record the successful contact.
        _markOnline();
      case OfflineApiStatus.unavailable:
        _markOnline();
      case OfflineApiStatus.offline:
        _offline = true;
    }
  }

  Future<void> _push(List<OfflineOp> pending) async {
    final slug = store.auction?.slug;
    if (slug == null) {
      return;
    }
    final result = await api.pushOps(slug, pending);
    switch (result.status) {
      case OfflineApiStatus.ok:
        final conflicts = await store.applyResults(
          result.results ?? const [],
          snapshotJson: result.snapshotJson,
        );
        if (conflicts.isNotEmpty) {
          newConflicts.value = [...newConflicts.value, ...conflicts];
        }
        _markOnline();
        // More ops may exceed one chunk — keep draining.
        if (store.pendingOps.isNotEmpty) {
          _queued = true;
        }
      case OfflineApiStatus.noAuction:
      case OfflineApiStatus.unavailable:
        // Ops stay queued; a later pull/push (permission restored, endpoint
        // deployed) picks them up.
        _markOnline();
      case OfflineApiStatus.offline:
        _offline = true;
    }
  }

  void _markOnline() {
    _offline = false;
    _lastSyncAt = DateTime.now();
  }

  /// Wraps a store mutation so the change starts syncing shortly — instant
  /// server writes while online, a growing queue while offline.
  Future<T> recordedOp<T>(Future<T> Function(OfflineStore store) mutate) async {
    await store.ensureLoaded();
    final result = await mutate(store);
    _debounce?.cancel();
    _debounce = Timer(_pushDebounce, () => unawaited(sync()));
    notifyListeners();
    return result;
  }
}
