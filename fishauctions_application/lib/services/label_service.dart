import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'api_service.dart';

final _log = Logger();

/// Fetches a lot's rendered label from the mobile API
/// (`GET /api/mobile/labels/<lot_pk>/`).
///
/// Two renderers, selected by `?fmt=` (`format` is reserved by DRF for content
/// negotiation and 404s — use `fmt`):
///  • `png` (default) — an RGB PNG for the Bluetooth raster path. Pass the
///    printer's exact geometry via `resolution`/`dpi` so barcodes render
///    crisp at the printhead width instead of being downscaled on-device.
///  • `pdf` — a single-lot PDF laid out with the user's `UserLabelPrefs`,
///    matching what the website's print buttons produce; used by the PDF and
///    System printer methods.
///
/// Requires a valid JWT (attached by the Dio auth interceptor); a 401/403/404
/// surfaces as a DioException for the caller to handle.
class LabelService {
  LabelService._();
  static final LabelService instance = LabelService._();

  /// **Do not "fix" this to `application/pdf` / `image/png`.**
  ///
  /// The endpoint is a DRF `APIView`, and `APIView.initial()` runs content
  /// negotiation *before* authentication against `DEFAULT_RENDERER_CLASSES` —
  /// which the deployment leaves at DRF's default (JSON + browsable HTML).
  /// An honest `Accept: application/pdf` therefore never reaches the view at
  /// all: it comes back **406 Not Acceptable**, which is what "Could not load
  /// the label" was on production. `*/*` negotiates, and the response carries
  /// the real content type anyway because the view returns a plain
  /// `HttpResponse`. `BACKEND_SPEC.md` Part 9 has the server-side fix that
  /// would let a specific Accept header work.
  static const _accept = {'Accept': '*/*'};

  /// The label PNG, rendered server-side. With [widthPx]/[heightPx]/[dpi]
  /// (all together) the server renders at exactly that raster; without them
  /// it falls back to the server default (600×400 @ 203 dpi) and the caller
  /// resizes on-device.
  Future<Uint8List> fetchLabelPng(
    int lotPk, {
    int? widthPx,
    int? heightPx,
    int? dpi,
  }) async {
    final sized = widthPx != null && heightPx != null && dpi != null;
    final res = await ApiService.instance.dio.get<List<int>>(
      'labels/$lotPk/',
      queryParameters: sized
          ? {'fmt': 'png', 'resolution': '${widthPx}x$heightPx', 'dpi': dpi}
          : null,
      options: Options(responseType: ResponseType.bytes, headers: _accept),
    );
    return Uint8List.fromList(res.data ?? const []);
  }

  /// The single-lot label PDF, honoring the user's saved label prefs.
  Future<Uint8List> fetchLabelPdf(int lotPk) async {
    final res = await ApiService.instance.dio.get<List<int>>(
      'labels/$lotPk/',
      queryParameters: {'fmt': 'pdf'},
      options: Options(responseType: ResponseType.bytes, headers: _accept),
    );
    return Uint8List.fromList(res.data ?? const []);
  }

  /// Part of a print run's label PNGs in one request
  /// (`POST labels/batch/`), in [lotPks] order.
  ///
  /// **The answer is deliberately not all of them.** The server renders until
  /// it hits 25 labels or a 3-second budget and leaves the rest, so the
  /// caller's loop is "post what is left, print what comes back" — a run of
  /// three hundred starts printing after the first chunk, and a slow server
  /// hands back a smaller one instead of a minute-long response. What a run
  /// costs is round trips over an auction hall's wifi, not rendering (about
  /// 110 ms a label, cached), and that is what this collapses.
  ///
  /// Same raster parameters as [fetchLabelPng]. A 404 means a deployment
  /// without the endpoint; the caller falls back to one GET per label.
  Future<LabelBatch> fetchLabelBatch(
    List<int> lotPks, {
    int? widthPx,
    int? heightPx,
    int? dpi,
  }) async {
    final sized = widthPx != null && heightPx != null && dpi != null;
    final res = await ApiService.instance.dio.post<Object?>(
      'labels/batch/',
      data: {
        'lots': lotPks,
        if (sized) 'resolution': '${widthPx}x$heightPx',
        if (sized) 'dpi': dpi,
      },
    );
    return parseLabelBatch(res.data);
  }
}

/// One `labels/batch/` answer.
@immutable
class LabelBatch {
  const LabelBatch({
    required this.labels,
    this.remaining = const [],
    this.skipped = const [],
  });

  /// The labels the server got to, in the order it returned them.
  final List<({int lot, Uint8List png})> labels;

  /// The lots it didn't get to this time, to ask for again.
  final List<int> remaining;

  /// Lots it will never render for this caller (deleted, not theirs), with
  /// the server's reason. Per-lot, and never a reason to stop the run.
  final List<({int lot, String detail})> skipped;
}

/// Reads a `labels/batch/` body. Throws [FormatException] for anything that
/// isn't one, so the caller can fall back to one request per label rather
/// than print from a shape it doesn't understand.
LabelBatch parseLabelBatch(Object? body) {
  final json = body is String ? jsonDecode(body) : body;
  if (json is! Map) {
    throw const FormatException('labels/batch/ did not answer with an object');
  }
  final rawLabels = json['labels'];
  if (rawLabels is! List) {
    throw const FormatException('labels/batch/ answered without a labels list');
  }
  final labels = <({int lot, Uint8List png})>[];
  for (final entry in rawLabels) {
    final lot = entry is Map ? entry['lot'] : null;
    final png = entry is Map ? entry['png'] : null;
    if (lot is! int || png is! String) {
      throw const FormatException('labels/batch/ sent a malformed label');
    }
    labels.add((lot: lot, png: base64Decode(png)));
  }
  final rawRemaining = json['remaining'];
  final rawSkipped = json['skipped'];
  return LabelBatch(
    labels: labels,
    remaining: [
      if (rawRemaining is List)
        for (final lot in rawRemaining)
          if (lot is int) lot,
    ],
    skipped: [
      if (rawSkipped is List)
        for (final entry in rawSkipped)
          if (entry is Map && entry['lot'] is int)
            (
              lot: entry['lot'] as int,
              detail: entry['detail'] is String
                  ? entry['detail'] as String
                  : 'This label could not be printed.',
            ),
    ],
  );
}

/// Maps a failed label fetch to a message the user can act on. Shared by every
/// print path (the PDF screen and the Bluetooth job), so a label that won't
/// render explains itself the same way wherever it was asked for.
///
/// "Could not load the label, please try again" used to be the answer to
/// everything that wasn't a 401/403/404/429 — including the server being
/// unreachable and the server refusing the request, which need opposite
/// responses from the user. So: say when it's the connection, say when it's
/// the server, and pass through the server's own explanation when it gave one
/// (a 400 here means the label can't be rendered for this lot — e.g. a lot
/// with no auction has no label layout to render against).
String labelFetchErrorMessage(DioException e) {
  final code = e.response?.statusCode;
  switch (code) {
    case 401:
    case 403:
      return "You don't have permission to print this lot's label.";
    case 404:
      return 'That lot could not be found. It may have been removed.';
    case 429:
      return 'Too many requests right now. Wait a moment and try again.';
    case null:
      _log.w('Label fetch failed with no response: ${e.type} ${e.message}');
      return "Couldn't reach the server. Check your connection and try again.";
    default:
      final detail = _detailOf(e);
      _log.w('Label fetch failed: HTTP $code ${detail ?? ''}');
      if (code >= 500) {
        return "The server couldn't produce this label right now "
            '(HTTP $code). Try again in a moment.';
      }
      return detail != null
          ? '$detail (HTTP $code)'
          : 'Could not load the label (HTTP $code). Please try again.';
  }
}

/// The API's `{"detail": …}` explanation, if it sent one. Label requests ask
/// for bytes, so an error body arrives as raw bytes rather than parsed JSON.
String? _detailOf(DioException e) {
  final data = e.response?.data;
  try {
    final body = data is List<int> ? utf8.decode(data) : data?.toString();
    if (body == null || body.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(body);
    final detail = decoded is Map ? decoded['detail'] : null;
    return detail is String && detail.isNotEmpty ? detail : null;
  } on Object {
    return null; // Not JSON (an HTML error page from a proxy, say).
  }
}
