import 'package:fishauctions_application/config/environment.dart';
import 'package:fishauctions_application/services/connect_flow_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final service = ConnectFlowService.instance;
  Uri site(String pathAndQuery) =>
      Uri.parse('${EnvironmentConfig.webBaseUrl}$pathAndQuery');

  var mints = 0;
  late List<String> opened;

  /// Fails the flow the way the platform does when the session never ran, or
  /// when the user tapped Done.
  ConnectAuthenticator failingWith(String code) =>
      ({required url, required callbackScheme}) async =>
          throw PlatformException(code: code);

  setUp(() {
    mints = 0;
    opened = [];
    service
      ..mintHandoff = ({next}) async {
        mints++;
        return '${EnvironmentConfig.webBaseUrl}'
            '/api/mobile/auth/web-session/consume/?t=tok$mints'
            '&next=${Uri.encodeQueryComponent(next ?? '')}';
      }
      ..authenticate = ({required url, required callbackScheme}) async {
        opened.add(url);
        return '$callbackScheme://square-connected';
      };
  });

  group('resolve', () {
    test('wraps one of our connect URLs in a fresh handoff', () async {
      final target = await service.resolve(site('/square/connect/'));

      expect(target.path, '/api/mobile/auth/web-session/consume/');
      expect(target.queryParameters['t'], 'tok1');
      // Percent-encoded: an unencoded `&` inside next is eaten by the query
      // parser and the server falls back to the home page.
      expect(
        target.queryParameters['next'],
        '/square/connect/?return_to_app=1',
      );
    });

    test('preserves a club slug through the handoff', () async {
      final target = await service.resolve(site('/square/connect/?club=abc'));
      final next = Uri.parse(target.queryParameters['next']!);

      expect(next.path, '/square/connect/');
      expect(next.queryParameters, {'club': 'abc', 'return_to_app': '1'});
    });

    test('a provider URL is opened as-is, with no handoff', () async {
      final url = Uri.parse('https://connect.squareup.com/oauth2/authorize');

      expect(await service.resolve(url), url);
      expect(mints, 0);
    });

    test('a handoff that cannot be minted falls back to the URL', () async {
      service.mintHandoff = ({next}) async => null;

      expect(
        await service.resolve(site('/paypal/connect/')),
        site('/paypal/connect/'),
      );
    });

    test('a throwing mint never aborts the flow', () async {
      service.mintHandoff = ({next}) async => throw StateError('offline');

      expect(
        await service.resolve(site('/paypal/connect/')),
        site('/paypal/connect/'),
      );
    });
  });

  group('run', () {
    test('mints a NEW token on every attempt', () async {
      // The token is single-use with a 300s TTL; replaying a consumed one
      // redirects to /login/, which is the symptom this whole change removes.
      await service.run(site('/square/connect/'));
      await service.run(site('/square/connect/'));

      expect(mints, 2);
      expect(opened, hasLength(2));
      expect(opened[0], contains('t=tok1'));
      expect(opened[1], contains('t=tok2'));
    });

    test('a redirect to the callback scheme is a completed flow', () async {
      expect(
        await service.run(site('/square/connect/')),
        ConnectFlowOutcome.redirected,
      );
    });

    test('a Done tap is reported as dismissed, never as a failure', () async {
      // Mailchimp, PayPal and Google Calendar all end this way today: the
      // connection succeeded, and the platform still calls it a cancellation.
      service.authenticate = failingWith('CANCELED');

      expect(
        await service.run(site('/mailchimp/connect/my-club/')),
        ConnectFlowOutcome.dismissed,
      );
    });

    test('a session that cannot start falls back to the browser', () async {
      service.authenticate = failingWith('UNSUPPORTED');

      expect(
        await service.run(site('/square/connect/')),
        ConnectFlowOutcome.unavailable,
      );
    });

    test('a non-platform error is also just unavailable', () async {
      service.authenticate = ({required url, required callbackScheme}) async =>
          throw StateError('no plugin');

      expect(
        await service.run(site('/square/connect/')),
        ConnectFlowOutcome.unavailable,
      );
    });
  });
}
