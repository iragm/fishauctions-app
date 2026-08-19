import 'package:fishauctions_application/config/environment.dart';
import 'package:fishauctions_application/services/deep_link_service.dart';
import 'package:fishauctions_application/utils/external_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = Uri.parse(EnvironmentConfig.webBaseUrl).host;

  group('DeepLinkService.webPathFor', () {
    test('takes a page on this deployment', () {
      expect(
        DeepLinkService.webPathFor(Uri.parse('https://$host/lots/123/')),
        '/lots/123/',
      );
    });

    test('keeps the query and the fragment', () {
      expect(
        DeepLinkService.webPathFor(
          Uri.parse('https://$host/lots/123/?locate=8#bids'),
        ),
        '/lots/123/?locate=8#bids',
      );
    });

    test('a bare host is the site root', () {
      expect(DeepLinkService.webPathFor(Uri.parse('https://$host')), '/');
    });

    // The app can only be signed in to one deployment, so opening another's
    // page inside the shell would render a signed-out site in a signed-in app.
    test('refuses another host', () {
      expect(
        DeepLinkService.webPathFor(Uri.parse('https://example.com/lots/1/')),
        isNull,
      );
    });

    // A host-less location reaching the router's exception handler is a
    // mistaken push, not a deep link — turning it into a web load would hide
    // the bug.
    test('refuses a bare in-app path', () {
      expect(DeepLinkService.webPathFor(Uri.parse('/tap-to-pay')), isNull);
    });

    test('refuses a non-http scheme', () {
      expect(
        DeepLinkService.webPathFor(Uri.parse('fishauctions://print/12')),
        isNull,
      );
      expect(
        DeepLinkService.webPathFor(Uri.parse('mailto:someone@example.com')),
        isNull,
      );
    });
  });

  group('DeepLinkService.offer', () {
    setUp(DeepLinkService.instance.consume);

    test('parks a site link and hands it over exactly once', () {
      expect(
        DeepLinkService.instance.offer(Uri.parse('https://$host/invoices/')),
        isTrue,
      );
      expect(DeepLinkService.instance.pending.value, '/invoices/');
      expect(DeepLinkService.instance.consume(), '/invoices/');
      expect(DeepLinkService.instance.consume(), isNull);
    });

    test('leaves a non-site location alone', () {
      expect(DeepLinkService.instance.offer(Uri.parse('/login')), isFalse);
      expect(DeepLinkService.instance.pending.value, isNull);
    });
  });

  group('isHandoffScheme', () {
    test('the three the OS owns', () {
      expect(isHandoffScheme(Uri.parse('mailto:a@b.com?subject=hi')), isTrue);
      expect(isHandoffScheme(Uri.parse('tel:+15555550123')), isTrue);
      expect(isHandoffScheme(Uri.parse('sms:+15555550123')), isTrue);
      expect(isHandoffScheme(Uri.parse('MAILTO:a@b.com')), isTrue);
    });

    // Not "anything that isn't http": this shell renders user-authored HTML.
    test('nothing that can launch an arbitrary app', () {
      for (final url in [
        'intent://scan/#Intent;scheme=zxing;end',
        'javascript:alert(1)',
        'file:///etc/passwd',
        'market://details?id=com.example',
        'https://auction.fish/lots/1/',
      ]) {
        expect(isHandoffScheme(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });
}
