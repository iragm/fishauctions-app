import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishauctions_application/models/app_config.dart';
import 'package:fishauctions_application/services/api_service.dart';
import 'package:fishauctions_application/services/auth_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request with a canned status and JSON body, recording what was
/// asked.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.status, this.body);

  final int status;
  final Map<String, Object?> body;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = ApiService.instance;
  final original = api.dio.httpClientAdapter;

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => api.dio.httpClientAdapter = original);

  _CannedAdapter answer(int status, Map<String, Object?> body) {
    final adapter = _CannedAdapter(status, body);
    api.dio.httpClientAdapter = adapter;
    return adapter;
  }

  group('AuthService.requestLoginCode', () {
    test('posts the email and returns the challenge', () async {
      final adapter = answer(200, {'challenge': 'opaque-123'});

      final challenge = await AuthService.instance.requestLoginCode(
        'a@example.com',
      );

      expect(challenge, 'opaque-123');
      expect(adapter.requests.single.path, 'auth/code/request/');
      expect(adapter.requests.single.data, {'email': 'a@example.com'});
    });

    test('an invalid address surfaces the 400 body', () async {
      answer(400, {
        'email': ['Enter a valid email address.'],
      });

      await expectLater(
        AuthService.instance.requestLoginCode('nope'),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 400)
              .having((e) => (e.response?.data as Map)['email'], 'email', [
                'Enter a valid email address.',
              ]),
        ),
      );
    });

    test('rate limiting surfaces as a 429', () async {
      answer(429, {'detail': 'Too many requests.'});

      await expectLater(
        AuthService.instance.requestLoginCode('a@example.com'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            429,
          ),
        ),
      );
    });

    test('a response without a challenge is an error', () async {
      answer(200, {});

      await expectLater(
        AuthService.instance.requestLoginCode('a@example.com'),
        throwsFormatException,
      );
    });
  });

  group('AuthService.loginWithCode', () {
    test('posts the challenge and code', () async {
      // The success path goes on to fetch the profile and register the device
      // (plugins), so the profile fetch is left to fail and only the request
      // body is checked.
      final adapter = answer(200, {'access': 'a', 'refresh': 'r'});

      await expectLater(
        AuthService.instance.loginWithCode('opaque-123', 'AB1-234'),
        throwsA(anything),
      );

      expect(adapter.requests.first.path, 'auth/code/confirm/');
      expect(adapter.requests.first.data, {
        'challenge': 'opaque-123',
        'code': 'AB1-234',
      });
    });

    test('a wrong code surfaces as a 401 and stores no tokens', () async {
      answer(401, {'detail': "That code didn't work."});

      await expectLater(
        AuthService.instance.loginWithCode('opaque-123', 'WRONG'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(await api.hasTokens, isFalse);
    });
  });

  group('AppConfig.emailCodeSignInEnabled', () {
    test('defaults to false when the key is absent', () {
      expect(AppConfig.fromJson({}).emailCodeSignInEnabled, isFalse);
    });

    test('reads the flag', () {
      expect(
        AppConfig.fromJson({
          'email_code_sign_in_enabled': true,
        }).emailCodeSignInEnabled,
        isTrue,
      );
    });
  });
}
