import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishauctions_application/services/api_service.dart';
import 'package:fishauctions_application/services/label_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request with three bytes and remembers what was asked.
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? captured;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured = options;
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }
}

String? _accept(RequestOptions options) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == 'accept') {
      return entry.value as String?;
    }
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dio = ApiService.instance.dio;
  final original = dio.httpClientAdapter;
  late _CapturingAdapter adapter;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    adapter = _CapturingAdapter();
    dio.httpClientAdapter = adapter;
  });

  tearDown(() => dio.httpClientAdapter = original);

  group('LabelService', () {
    // Regression test for the production "Could not load the label" bug.
    //
    // The label endpoint is a DRF APIView, and APIView.initial() negotiates
    // content *before* authenticating, against DEFAULT_RENDERER_CLASSES —
    // which is DRF's default here (JSON + browsable HTML). Asking for the
    // media type we actually want got the request rejected with 406 before it
    // ever reached the view. Verified against production: `Accept:
    // application/pdf` and `Accept: image/png` both 406, while `*/*` and
    // `application/json` reach authentication.
    test('fetchLabelPdf sends fmt=pdf and a negotiable Accept', () async {
      final bytes = await LabelService.instance.fetchLabelPdf(7);

      expect(bytes, [1, 2, 3]);
      expect(adapter.captured!.path, 'labels/7/');
      expect(adapter.captured!.queryParameters, {'fmt': 'pdf'});
      expect(_accept(adapter.captured!), '*/*');
    });

    test('fetchLabelPng sends a negotiable Accept', () async {
      await LabelService.instance.fetchLabelPng(7);

      expect(adapter.captured!.path, 'labels/7/');
      expect(_accept(adapter.captured!), '*/*');
    });

    test('fetchLabelPng passes the printer raster when it knows it', () async {
      await LabelService.instance.fetchLabelPng(
        7,
        widthPx: 96,
        heightPx: 48,
        dpi: 203,
      );

      expect(adapter.captured!.queryParameters, {
        'fmt': 'png',
        'resolution': '96x48',
        'dpi': 203,
      });
    });

    test('fetchLabelPng omits the raster params when any is missing', () async {
      await LabelService.instance.fetchLabelPng(7, widthPx: 96);

      expect(adapter.captured!.queryParameters, isEmpty);
    });
  });
}
