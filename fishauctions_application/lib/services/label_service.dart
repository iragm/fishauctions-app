import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_service.dart';

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
}
