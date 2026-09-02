import 'package:fishauctions_application/config/environment.dart';
import 'package:fishauctions_application/utils/connect_flows.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = Uri.parse(EnvironmentConfig.webBaseUrl).host;
  Uri site(String pathAndQuery) =>
      Uri.parse('${EnvironmentConfig.webBaseUrl}$pathAndQuery');

  group('connect launchers', () {
    test('the four provider launchers are diverted out of the shell', () {
      for (final path in [
        '/square/connect/',
        '/paypal/connect/',
        '/mailchimp/connect/my-club/',
        '/google-calendar/connect/my-club/',
      ]) {
        expect(
          startsConnectFlowInShell(site(path)),
          isTrue,
          reason: '$path should run in the auth session',
        );
        expect(connectFlowRole(site(path)), ConnectFlowRole.launcher);
      }
    });

    test('a query string does not stop a launcher matching', () {
      // /square/connect/?club=<slug> is how the club membership page connects
      // a club rather than a user.
      expect(startsConnectFlowInShell(site('/square/connect/?club=abc')), true);
    });

    test('ordinary pages are left in the shell', () {
      for (final path in [
        '/',
        '/lots/all/',
        '/auctions/spring-2026/',
        '/clubs/my-club/',
        // A near-miss: the launchers are anchored, not prefix-matched.
        '/lots/123/square/connect/',
        '/square/connect/extra/',
      ]) {
        expect(
          startsConnectFlowInShell(site(path)),
          isFalse,
          reason: '$path should render in the shell',
        );
      }
    });

    test('the Discord settings page is a page, not a launcher', () {
      final uri = site('/clubs/my-club/discord/');
      // It has forms on it and belongs in the shell...
      expect(startsConnectFlowInShell(uri), isFalse);
      // ...but if anything opens it outside the shell it needs a session.
      expect(connectFlowRole(uri), ConnectFlowRole.page);
      expect(needsWebSessionHandoff(uri), isTrue);
    });
  });

  group('provider hosts', () {
    test('every provider a connect round trip passes through', () {
      for (final url in [
        'https://connect.squareup.com/oauth2/authorize',
        'https://connect.squareupsandbox.com/oauth2/authorize',
        'https://www.paypal.com/connect',
        'https://login.mailchimp.com/oauth2/authorize',
        'https://accounts.google.com/o/oauth2/v2/auth',
        'https://discord.com/oauth2/authorize?client_id=1',
      ]) {
        final uri = Uri.parse(url);
        expect(isConnectProviderHost(uri), isTrue, reason: url);
        expect(connectFlowRole(uri), ConnectFlowRole.provider);
        expect(runsInAuthSession(uri), isTrue);
        // Our session means nothing on their domain.
        expect(needsWebSessionHandoff(uri), isFalse);
      }
    });

    test('an unrelated site still goes to the system browser', () {
      for (final url in [
        'https://maps.google.com/?q=1',
        'https://example.com/',
        // Not a subdomain of paypal.com, despite the suffix.
        'https://notpaypal.com/',
      ]) {
        expect(runsInAuthSession(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });

  group('connectNextPath', () {
    test('marks the round trip as app-originated', () {
      expect(
        connectNextPath(site('/square/connect/')),
        '/square/connect/?return_to_app=1',
      );
    });

    test('preserves an existing query', () {
      final next = connectNextPath(site('/square/connect/?club=my-club'));
      final parsed = Uri.parse(next);
      expect(parsed.path, '/square/connect/');
      expect(parsed.queryParameters, {'club': 'my-club', 'return_to_app': '1'});
    });

    test('is site-relative, so the consume view will honour it', () {
      // An off-host `next` is rejected server-side and falls back to home.
      final next = connectNextPath(site('/mailchimp/connect/my-club/'));
      expect(next, startsWith('/'));
      expect(next, isNot(contains(host)));
    });
  });
}
