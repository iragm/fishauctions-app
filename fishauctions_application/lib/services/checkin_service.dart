import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/checkin_models.dart';
import 'api_service.dart';
import 'location_service.dart';

/// Proximity check-in — the "welcome to the auction" nudges
/// (BACKEND_SPEC.md Part 6).
///
/// While the WebView shell is up, periodically reports the phone's position;
/// the backend decides everything product-side (which in-person auction's
/// welcome geofence/time window the user is inside, whether to offer a join,
/// auto-check them in, or — for admins — offer to pin the auction's exact
/// location) and returns display-ready actions the shell surfaces. Same
/// dumb-sensor-and-display division as AR observations.
///
/// Hard rules:
/// - **Never prompts for location.** Pings happen only when whileInUse
///   permission already exists (granted contextually on a location-aware web
///   page — see [LocationService]). No permission → no pings, silently.
/// - Foreground only by design: no background geofencing, no extra
///   permissions. People at an auction open the app anyway; the shell pings
///   at mount, on resume, and every [pingInterval] while running.
/// - Degradation contract: a 404 (deployment without Part 6) disables pings
///   for the process; other failures are swallowed and retried next tick.
class CheckinService {
  CheckinService._();
  static final CheckinService instance = CheckinService._();

  static const Duration pingInterval = Duration(minutes: 10);

  /// Floor between pings — a resume right after the periodic tick (or a
  /// remount) must not double-hit the server or the GPS.
  static const Duration minGap = Duration(minutes: 2);

  /// Fresh nudges for the shell. Same shape as
  /// `OfflineSyncService.newConflicts`: the shell listens, then calls
  /// [consumeNewActions].
  final ValueNotifier<List<CheckinAction>> newActions = ValueNotifier(const []);

  Timer? _periodic;
  bool _available = true;
  bool _pinging = false;
  DateTime? _lastPing;
  final Set<String> _surfaced = {};

  void start() {
    _periodic?.cancel();
    _periodic = Timer.periodic(pingInterval, (_) => unawaited(ping()));
    unawaited(ping());
  }

  void stop() {
    _periodic?.cancel();
    _periodic = null;
    newActions.value = const [];
  }

  void onAppResumed() {
    unawaited(ping());
  }

  /// Takes (and clears) the pending nudges.
  List<CheckinAction> consumeNewActions() {
    final actions = newActions.value;
    newActions.value = const [];
    return actions;
  }

  /// Reports the current position, if permitted, and queues whatever nudges
  /// the server returns. Safe to call opportunistically.
  Future<void> ping() async {
    if (!_available || _pinging) {
      return;
    }
    final last = _lastPing;
    if (last != null && DateTime.now().difference(last) < minGap) {
      return;
    }
    _pinging = true;
    try {
      final position = await LocationService.instance.positionIfPermitted();
      if (position == null) {
        return; // no permission or no fix — stay silent, try again next tick
      }
      _lastPing = DateTime.now();
      final res = await ApiService.instance.dio.post<Map<String, dynamic>>(
        'checkin/ping/',
        data: {'latitude': position.latitude, 'longitude': position.longitude},
      );
      final parsed = switch (res.data?['actions']) {
        final List<dynamic> raw => [
          for (final a in raw) ?CheckinAction.tryParse(a),
        ],
        _ => const <CheckinAction>[],
      };
      // The server dedupes persistently; this only stops a re-ping from
      // re-opening a sheet the user dismissed minutes ago.
      final fresh = [
        for (final a in parsed)
          if (_surfaced.add(a.key)) a,
      ];
      if (fresh.isNotEmpty) {
        newActions.value = [...newActions.value, ...fresh];
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _available = false;
        debugPrint('Check-in endpoint missing — proximity nudges disabled.');
      }
    } finally {
      _pinging = false;
    }
  }

  /// Joins [auctionSlug] for the signed-in user — the server-side equivalent
  /// of confirming the rules page, plus an immediate check-in on
  /// check-in-mode auctions (the user is physically at the venue). Null on
  /// failure.
  Future<CheckinJoinResult?> join(String auctionSlug) async {
    try {
      final res = await ApiService.instance.dio.post<Map<String, dynamic>>(
        'checkin/join/',
        data: {'auction': auctionSlug},
      );
      final data = res.data;
      return data == null ? null : CheckinJoinResult.fromJson(data);
    } on DioException {
      return null;
    }
  }

  /// Pins [auctionSlug]'s location to this phone's current position
  /// (admin-gated server-side). Returns false when no fix was available or
  /// the server refused.
  Future<bool> setAuctionLocation(String auctionSlug) async {
    final position = await LocationService.instance.positionIfPermitted();
    if (position == null) {
      return false;
    }
    try {
      await ApiService.instance.dio.post<void>(
        'checkin/set-location/',
        data: {
          'auction': auctionSlug,
          'latitude': position.latitude,
          'longitude': position.longitude,
        },
      );
      return true;
    } on DioException {
      return false;
    }
  }

  @visibleForTesting
  void reset() {
    _available = true;
    _lastPing = null;
    _surfaced.clear();
    newActions.value = const [];
  }
}
