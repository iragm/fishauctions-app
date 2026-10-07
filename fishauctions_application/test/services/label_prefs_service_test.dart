import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishauctions_application/models/label_prefs.dart';
import 'package:fishauctions_application/services/api_service.dart';
import 'package:fishauctions_application/services/label_prefs_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers `labels/prefs/` with [method], or holds the answer while [hold] is
/// set — a hall's wifi that's up but passing nothing.
class _PrefsAdapter implements HttpClientAdapter {
  String method = 'bluetooth';
  Completer<void>? hold;
  int requests = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    await hold?.future;
    return ResponseBody.fromString(
      jsonEncode({'print_method': method}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dio = ApiService.instance.dio;
  final original = dio.httpClientAdapter;
  final service = LabelPrefsService.instance;
  late _PrefsAdapter adapter;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    adapter = _PrefsAdapter();
    dio.httpClientAdapter = adapter;
    await service.clear();
  });

  tearDown(() => dio.httpClientAdapter = original);

  test('a fresh copy answers from memory without a request', () async {
    expect((await service.fetch())?.printMethod, PrintMethod.bluetooth);
    expect((await service.fetch())?.printMethod, PrintMethod.bluetooth);
    expect(adapter.requests, 1);
  });

  test('markStale sends the next lookup to the server', () async {
    await service.fetch();
    adapter.method = 'pdf';
    service.markStale();
    expect((await service.fetch())?.printMethod, PrintMethod.pdf);
    expect(adapter.requests, 2);
  });

  test('a stalled network answers with the last good copy', () async {
    await service.fetch();
    service.markStale();
    adapter.hold = Completer<void>();
    final started = DateTime.now();
    final prefs = await service.fetch();
    expect(prefs?.printMethod, PrintMethod.bluetooth);
    // Bounded by the service's wait, not the client's 15 s timeouts.
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 5)),
    );
    adapter.hold!.complete();
  });

  test('sign-out forgets the prefs, memory and disk alike', () async {
    await service.fetch();
    await service.clear();
    adapter.hold = Completer<void>();
    expect(await service.fetch(), isNull);
    adapter.hold!.complete();
  });
}
