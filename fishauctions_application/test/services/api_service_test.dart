import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fishauctions_application/services/api_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A JWT with the given expiry. Only the payload is real — nothing here checks
/// a signature, and neither does [ApiService], which reads `exp` purely to
/// decide whether to *ask* for a new token.
String jwtExpiring(Duration fromNow) {
  final exp =
      DateTime.now().toUtc().add(fromNow).millisecondsSinceEpoch ~/ 1000;
  String seg(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.${seg({'exp': exp})}.sig';
}

RequestOptions _options() => RequestOptions(path: 'auth/refresh/');

/// The server's answer to a refresh, as a Dio failure.
DioException _status(int code, {Map<String, List<String>>? headers}) =>
    DioException.badResponse(
      statusCode: code,
      requestOptions: _options(),
      response: Response<dynamic>(
        statusCode: code,
        requestOptions: _options(),
        headers: Headers.fromMap(headers ?? const {}),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = ApiService.instance;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    api.onSessionInvalidated = null;
  });
  tearDown(() {
    api
      ..postRefresh = ((refresh) async {
        throw StateError('no refresh expected in this test');
      })
      ..onSessionInvalidated = null;
  });

  group('ApiService token storage', () {
    test('reports no tokens before login', () async {
      expect(await api.hasTokens, isFalse);
      expect(await api.getAccessToken(), isNull);
    });

    test('persists and reads back both tokens', () async {
      await api.saveTokens('access-1', 'refresh-1');

      expect(await api.getAccessToken(), 'access-1');
      expect(await api.getRefreshToken(), 'refresh-1');
      expect(await api.hasTokens, isTrue);
    });

    test('clearTokens removes everything', () async {
      await api.saveTokens('access-1', 'refresh-1');
      await api.clearTokens();

      expect(await api.hasTokens, isFalse);
      expect(await api.getAccessToken(), isNull);
      expect(await api.getRefreshToken(), isNull);
    });

    test('the Dio base URL targets the mobile API namespace', () {
      expect(api.dio.options.baseUrl, endsWith('/api/mobile/'));
    });
  });

  group('ensureFreshAccessToken', () {
    test('makes no network call while the token has life left', () async {
      await api.saveTokens(jwtExpiring(const Duration(hours: 1)), 'refresh-1');
      api.postRefresh = (refresh) async => fail('should not have refreshed');

      expect(await api.ensureFreshAccessToken(), isTrue);
    });

    test('reports no session rather than refreshing one', () async {
      api.postRefresh = (refresh) async => fail('should not have refreshed');

      expect(await api.ensureFreshAccessToken(), isFalse);
    });

    test('an expired token is refreshed before it is used', () async {
      // The config endpoint reads the bearer token *optionally*, so a stale
      // one is answered with 200 and the signed-out payload rather than a
      // 401 — there is no error for anything downstream to notice, which is
      // why this has to happen up front.
      await api.saveTokens(jwtExpiring(const Duration(hours: -1)), 'refresh-1');
      api.postRefresh = (refresh) async => Response<dynamic>(
        requestOptions: _options(),
        statusCode: 200,
        data: {
          'access': jwtExpiring(const Duration(hours: 1)),
          'refresh': 'r2',
        },
      );

      expect(await api.ensureFreshAccessToken(), isTrue);
      expect(await api.getRefreshToken(), 'r2');
    });

    test('a token expiring within the margin is treated as due', () async {
      await api.saveTokens(jwtExpiring(const Duration(seconds: 30)), '');

      // No refresh token, so it cannot succeed; the point is that it did not
      // wave the nearly-dead access token through.
      expect(await api.ensureFreshAccessToken(), isFalse);
    });

    test('an unreadable token is treated as due, not as valid', () async {
      await api.saveTokens('not-a-jwt', '');

      expect(await api.ensureFreshAccessToken(), isFalse);
    });
  });

  group('refresh failures that must NOT sign anybody out', () {
    late bool invalidated;

    setUp(() async {
      invalidated = false;
      await api.saveTokens('access-1', 'refresh-1');
      api.onSessionInvalidated = () => invalidated = true;
    });

    Future<void> expectSessionSurvived() async {
      expect(await api.hasTokens, isTrue, reason: 'tokens must be kept');
      expect(invalidated, isFalse, reason: 'must not sign out');
    }

    test('a 400 — a malformed request, not a dead session', () async {
      // The server answers a missing `refresh` field with 400; a rejected
      // token is always 401. Treating 400 as death signed people out for a
      // client-side bug.
      api.postRefresh = (refresh) async {
        throw _status(400);
      };

      expect(await api.refreshTokens(), isFalse);
      await expectSessionSurvived();
    });

    test('a 403', () async {
      api.postRefresh = (refresh) async {
        throw _status(403);
      };

      expect(await api.refreshTokens(), isFalse);
      await expectSessionSurvived();
    });

    test('a 500', () async {
      api.postRefresh = (refresh) async {
        throw _status(500);
      };

      expect(await api.refreshTokens(), isFalse);
      await expectSessionSurvived();
    });

    test('an offline phone', () async {
      api.postRefresh = (refresh) async {
        throw DioException.connectionError(
          requestOptions: _options(),
          reason: 'offline',
        );
      };

      expect(await api.refreshTokens(), isFalse);
      await expectSessionSurvived();
    });

    test('a 200 with no tokens in it', () async {
      api.postRefresh = (refresh) async =>
          Response<dynamic>(requestOptions: _options(), statusCode: 200);

      expect(await api.refreshTokens(), isFalse);
      await expectSessionSurvived();
    });

    test('a 401 for a token that was rotated mid-flight', () async {
      // A sign-in or an earlier refresh replaced the pair while this request
      // was in the air: the rejection describes a token nobody is using, and
      // wiping the fresh one would be the bug.
      api.postRefresh = (refresh) async {
        await api.saveTokens('access-2', 'refresh-2');
        throw _status(401);
      };

      expect(await api.refreshTokens(), isFalse);
      expect(await api.getRefreshToken(), 'refresh-2');
      await expectSessionSurvived();
    });

    test('a throttled refresh backs off and retries', () async {
      // /auth/refresh/ is throttled per IP, and an auction hall is a room
      // full of these phones behind one NAT — a 429 says nothing about this
      // session's credentials.
      var calls = 0;
      api.postRefresh = (refresh) async {
        calls++;
        if (calls == 1) {
          // Retry-After is honoured, which is also what keeps this test fast.
          throw _status(
            429,
            headers: {
              'retry-after': ['1'],
            },
          );
        }
        return Response<dynamic>(
          requestOptions: _options(),
          statusCode: 200,
          data: {'access': 'a2', 'refresh': 'r2'},
        );
      };

      expect(await api.refreshTokens(), isTrue);
      expect(calls, 2);
      await expectSessionSurvived();
    });
  });

  group('the one signal that does end a session', () {
    test('a 401 for the token still in storage', () async {
      await api.saveTokens('access-1', 'refresh-1');
      var invalidated = false;
      api
        ..onSessionInvalidated = (() => invalidated = true)
        ..postRefresh = ((refresh) async {
          throw _status(401);
        });

      expect(await api.refreshTokens(), isFalse);
      expect(await api.hasTokens, isFalse);
      expect(invalidated, isTrue);
    });
  });

  group('single-flight', () {
    test('concurrent refreshes share one call to the server', () async {
      // Rotation with blacklisting makes a token valid exactly once, so two
      // concurrent refreshes guarantee one 401 and a spurious sign-out.
      await api.saveTokens('access-1', 'refresh-1');
      var calls = 0;
      api.postRefresh = (refresh) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return Response<dynamic>(
          requestOptions: _options(),
          statusCode: 200,
          data: {'access': 'a2', 'refresh': 'r2'},
        );
      };

      final results = await Future.wait([
        api.refreshTokens(),
        api.refreshTokens(),
        api.refreshTokens(),
      ]);

      expect(results, everyElement(isTrue));
      expect(calls, 1);
    });
  });
}
