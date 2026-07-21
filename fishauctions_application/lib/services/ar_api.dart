import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/ar_models.dart';
import 'api_service.dart';

/// HTTP client for the AR endpoints (`/api/mobile/ar/*`, BACKEND_SPEC.md
/// Part 3). Thin like the other services — all state beyond
/// endpoint-availability flags lives in `ArSessionController`.
///
/// Degradation contract: these endpoints may not exist on a deployment yet.
/// A 404 flips the matching `…Available` flag off for the process, callers
/// get stubs/nulls, and AR mode keeps working as a plain QR overlay.
class ArApi {
  ArApi._();
  static final ArApi instance = ArApi._();

  /// Per-call pk cap, mirroring the server's limit.
  static const int maxLotsPerFetch = 50;

  bool _lotsAvailable = true;
  bool _observationsAvailable = true;
  bool _positionsAvailable = true;

  /// Whether observation reporting is worth attempting (endpoint present).
  bool get observationsAvailable => _observationsAvailable;

  /// Fetches overlay metadata for [pks] in one batched call. Missing endpoint
  /// or a failed request degrade to stubs — a scan overlay that stops
  /// rendering because the network blipped would be worse than pk-only chips.
  Future<({ArAuctionMeta? auction, List<ArLotMeta> lots})> fetchLots(
    String auctionSlug,
    Set<int> pks,
  ) async {
    final wanted = pks.take(maxLotsPerFetch).toList();
    if (wanted.isEmpty) {
      return (auction: null, lots: const <ArLotMeta>[]);
    }
    if (!_lotsAvailable) {
      return (
        auction: null,
        lots: [for (final pk in wanted) ArLotMeta.stub(pk)],
      );
    }
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'ar/lots/',
        queryParameters: {'auction': auctionSlug, 'lots': wanted.join(',')},
      );
      final data = res.data ?? const {};
      final lots = switch (data['lots']) {
        final List<dynamic> raw => [
          for (final l in raw)
            if (l is Map<String, dynamic>) ArLotMeta.fromJson(l),
        ],
        _ => const <ArLotMeta>[],
      };
      return (auction: ArAuctionMeta.tryParse(data['auction']), lots: lots);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _lotsAvailable = false;
        debugPrint('AR lots endpoint missing — overlaying pk-only stubs.');
      }
      return (
        auction: null,
        lots: [for (final pk in wanted) ArLotMeta.stub(pk)],
      );
    }
  }

  /// Uploads a batch of observation frames. Fire-and-forget semantics: any
  /// failure is swallowed (a 404 disables further attempts) — scan overlays
  /// must never stall on telemetry.
  ///
  /// [fovHDeg] is the device-reported camera horizontal FOV the bearings were
  /// computed against, or null when the assumed-FOV fallback was used — the
  /// server widens its bearing noise model for uncalibrated sessions.
  Future<void> postObservations(
    String auctionSlug,
    String sessionId,
    List<ArFrame> frames, {
    double? fovHDeg,
  }) async {
    if (!_observationsAvailable || frames.isEmpty) {
      return;
    }
    try {
      await ApiService.instance.dio.post<void>(
        'ar/observations/',
        data: {
          'auction': auctionSlug,
          'session_id': sessionId,
          if (fovHDeg != null)
            'fov_hdeg': double.parse(fovHDeg.toStringAsFixed(1)),
          'frames': [for (final f in frames) f.toJson()],
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _observationsAvailable = false;
        debugPrint('AR observations endpoint missing — reporting disabled.');
      }
    }
  }

  /// Fetches the solved lot positions for locate mode. Null when unavailable
  /// (endpoint missing, offline) — locate mode then reports "not mapped yet".
  Future<ArPositions?> fetchPositions(String auctionSlug) async {
    if (!_positionsAvailable) {
      return null;
    }
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'ar/positions/',
        queryParameters: {'auction': auctionSlug},
      );
      final data = res.data;
      return data == null ? null : ArPositions.fromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _positionsAvailable = false;
      }
      return null;
    }
  }

  /// Sets (not toggles) the caller's watch state on a lot via
  /// `POST /api/mobile/lots/<pk>/watch/`, so the AR card's star works without
  /// opening the web lot page. The endpoint is idempotent. Returns the
  /// server's resulting `watched` state, or null on any failure so the caller
  /// can revert its optimistic toggle.
  Future<bool?> setWatch(int lotPk, {required bool watch}) async {
    try {
      final res = await ApiService.instance.dio.post<Map<String, dynamic>>(
        'lots/$lotPk/watch/',
        data: {'watch': watch},
      );
      final watched = res.data?['watched'];
      return watched is bool ? watched : watch;
    } on DioException {
      return null;
    }
  }

  @visibleForTesting
  void resetAvailability() {
    _lotsAvailable = true;
    _observationsAvailable = true;
    _positionsAvailable = true;
  }
}
