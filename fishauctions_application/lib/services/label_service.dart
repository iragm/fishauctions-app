import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_service.dart';

/// Fetches a lot's label image from the mobile API.
///
/// `GET /api/mobile/labels/<lot_pk>/` returns a ready-to-render **RGB PNG**
/// (image/png), not JSON. There are no useful query params: `dpi` doesn't
/// exist, and `format` is reserved by DRF for content negotiation — sending
/// `?format=png` 404s before the handler runs — so we send none. Requires a
/// valid JWT (attached by the Dio auth interceptor); a 401/403/404 surfaces as
/// a DioException for the caller to handle.
class LabelService {
  LabelService._();
  static final LabelService instance = LabelService._();

  Future<Uint8List> fetchLabelPng(int lotPk) async {
    final res = await ApiService.instance.dio.get<List<int>>(
      'labels/$lotPk/',
      options: Options(
        responseType: ResponseType.bytes,
        // The endpoint always returns image/png; ask for it explicitly rather
        // than the client's default Accept: application/json.
        headers: {'Accept': 'image/png'},
      ),
    );
    return Uint8List.fromList(res.data ?? const []);
  }
}
