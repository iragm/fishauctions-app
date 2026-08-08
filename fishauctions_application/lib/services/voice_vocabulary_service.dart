import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../models/voice_vocabulary.dart';
import 'api_service.dart';

final _log = Logger();

/// Fetches the identifiers that are legal answers in one auction
/// (`BACKEND_SPEC.md` Part VOICE-2), and keeps them fresh while selling runs.
///
/// **Refresh is not optional.** Bidders are registered at the check-in desk
/// *during* the auction, so a vocabulary fetched once when the page loaded is
/// stale within minutes, and a bidder missing from it is a bidder every match
/// marks unsure.
///
/// There is deliberately **no offline fallback** — this never reads
/// `OfflineStore`. Offline mode is the one part of the app where a bug means a
/// stuck auction with no way to recover, and it stays as small as it is. When
/// the fetch fails, voice still runs against [VoiceVocabulary.empty]: every
/// value is then marked unsure, which is the honest answer when we can't check
/// one.
class VoiceVocabularyService {
  VoiceVocabularyService._();

  static final VoiceVocabularyService instance = VoiceVocabularyService._();

  /// How often to re-pull while a session is live.
  static const Duration refreshInterval = Duration(minutes: 2);

  String? _slug;
  String? _etag;
  VoiceVocabulary _vocabulary = VoiceVocabulary.empty;
  Timer? _timer;

  /// True once a deployment has answered 404 — an older backend without the
  /// endpoint. Stops the retry loop for the process rather than pointlessly
  /// re-asking every two minutes for the rest of the auction.
  bool _unsupported = false;

  bool get isSupported => !_unsupported;

  VoiceVocabulary get current => _vocabulary;

  /// Load the vocabulary for [slug] and start refreshing it. Safe to call
  /// repeatedly; switching auctions drops the old index.
  Future<VoiceVocabulary> begin(String slug) async {
    if (_slug != slug) {
      _slug = slug;
      _etag = null;
      _vocabulary = VoiceVocabulary.empty;
    }
    await refresh();
    _timer?.cancel();
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
    return _vocabulary;
  }

  void end() {
    _timer?.cancel();
    _timer = null;
  }

  /// Pull the current lists. Cheap when nothing changed — the endpoint is
  /// ETag'd, and a 304 skips rebuilding the spoken-form index, which is the
  /// expensive half.
  Future<void> refresh() async {
    final slug = _slug;
    if (slug == null || _unsupported) {
      return;
    }
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'auctions/$slug/voice/vocabulary/',
        options: Options(
          headers: {if (_etag != null) 'If-None-Match': _etag},
          // A 304 is a success here, not something to throw on.
          validateStatus: (status) =>
              status != null && status >= 200 && status < 400,
        ),
      );
      if (res.statusCode == 304) {
        return;
      }
      final data = res.data;
      if (data == null) {
        return;
      }
      _etag = res.headers.value('etag');
      _vocabulary = VoiceVocabulary.fromJson(data);
      _log.d(
        'Voice vocabulary: ${_vocabulary.lotNumbers.length} lots, '
        '${_vocabulary.bidderNumbers.length} bidders',
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _unsupported = true;
        _log.i('Voice vocabulary endpoint absent; matching will be fuzzy only');
        return;
      }
      _log.w('Voice vocabulary refresh failed: $e');
    } on Object catch (e) {
      _log.w('Voice vocabulary parse failed: $e');
    }
  }

  /// Test hook — stop [begin] reaching the network at all, the same way a 404
  /// does in production.
  @visibleForTesting
  bool get offlineForTesting => _unsupported;

  @visibleForTesting
  set offlineForTesting(bool value) => _unsupported = value;

  /// Test hook — inject a vocabulary without a network round trip.
  @visibleForTesting
  VoiceVocabulary get vocabularyForTesting => _vocabulary;

  @visibleForTesting
  set vocabularyForTesting(VoiceVocabulary vocabulary) =>
      _vocabulary = vocabulary;
}
