import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/offline_models.dart';
import 'api_service.dart';

/// Outcome of one pull/push attempt, so the sync layer can tell "the network
/// is down" (keep queueing, retry later) apart from "this deployment doesn't
/// have the endpoints" (disable offline sync for the process) and "the
/// server answered" (apply it).
enum OfflineApiStatus {
  ok,

  /// Endpoint answered but the caller administers no auction.
  noAuction,

  /// Endpoint missing (404) on this deployment, or the caller lost admin
  /// permission (403) — either way, stop trying for now.
  unavailable,

  /// Timeout / connection failure / 5xx — genuinely offline; retry later.
  offline,
}

class OfflinePullResult {
  const OfflinePullResult(this.status, [this.snapshotJson]);

  final OfflineApiStatus status;
  final Map<String, dynamic>? snapshotJson;
}

class OfflinePushResult {
  const OfflinePushResult(this.status, {this.results, this.snapshotJson});

  final OfflineApiStatus status;
  final List<OfflineSyncOpResult>? results;
  final Map<String, dynamic>? snapshotJson;
}

/// HTTP client for the offline-sync endpoints (`/api/mobile/offline/*`,
/// BACKEND_SPEC.md Part 4). Thin like the other services — queueing, retry
/// pacing, and merge state all live in OfflineSyncService/OfflineStore.
///
/// Degradation contract (ArApi-style): the endpoints may not exist on a
/// deployment yet. A 404 flips [available] off for the process and offline
/// mode keeps whatever data it already has.
class OfflineApi {
  OfflineApi._();

  static final OfflineApi instance = OfflineApi._();

  /// Server-side per-call cap on ops (the app chunks to stay under it).
  static const int maxOpsPerPush = 500;

  bool _available = true;

  /// Whether the deployment is known to serve the offline endpoints.
  bool get available => _available;

  OfflineApiStatus _classify(DioException e) {
    final status = e.response?.statusCode;
    if (status == 404) {
      _available = false;
      debugPrint('Offline sync endpoints missing — offline sync disabled.');
      return OfflineApiStatus.unavailable;
    }
    if (status == 403) {
      return OfflineApiStatus.unavailable;
    }
    return OfflineApiStatus.offline;
  }

  /// Pulls the last-admin-auction snapshot.
  Future<OfflinePullResult> fetchSnapshot() async {
    if (!_available) {
      return const OfflinePullResult(OfflineApiStatus.unavailable);
    }
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'offline/snapshot/',
      );
      final data = res.data;
      if (data == null || data['auction'] == null) {
        return const OfflinePullResult(OfflineApiStatus.noAuction);
      }
      return OfflinePullResult(OfflineApiStatus.ok, data);
    } on DioException catch (e) {
      return OfflinePullResult(_classify(e));
    }
  }

  /// Replays queued ops. The server applies them in order, idempotently, and
  /// answers with per-op results plus a fresh snapshot.
  Future<OfflinePushResult> pushOps(
    String auctionSlug,
    List<OfflineOp> ops,
  ) async {
    if (!_available) {
      return const OfflinePushResult(OfflineApiStatus.unavailable);
    }
    try {
      final res = await ApiService.instance.dio.post<Map<String, dynamic>>(
        'offline/sync/',
        data: {
          'auction': auctionSlug,
          'ops': [for (final op in ops.take(maxOpsPerPush)) op.toWire()],
        },
      );
      final data = res.data ?? const {};
      final results = [
        for (final r in data['results'] as List? ?? const [])
          if (r is Map<String, dynamic>) OfflineSyncOpResult.fromJson(r),
      ];
      final snapshot = data['snapshot'];
      return OfflinePushResult(
        OfflineApiStatus.ok,
        results: results,
        snapshotJson: snapshot is Map<String, dynamic> ? snapshot : null,
      );
    } on DioException catch (e) {
      return OfflinePushResult(_classify(e));
    }
  }

  @visibleForTesting
  void resetAvailability() {
    _available = true;
  }
}
