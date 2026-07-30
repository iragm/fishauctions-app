import 'package:fishauctions_application/config/environment.dart';
import 'package:fishauctions_application/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `terms_url` / `privacy_policy_url` half of `/api/mobile/config/`.
///
/// These paths are rendered as links on the login and signup screens (an App
/// Store requirement for an app that creates accounts) and loaded inside the
/// signed-out login trap — so the normalization has two jobs: cope with the
/// backend sending either an absolute URL or a bare path, and refuse to turn
/// the trap into a doorway to some other host.
void main() {
  final host = Uri.parse(EnvironmentConfig.webBaseUrl).host;

  group('AppConfig legal paths', () {
    test('absent → terms falls back to /tos/, privacy stays empty', () {
      final cfg = AppConfig.fromJson({'brand_name': 'auction.fish'});
      expect(cfg.termsPath, AppConfig.defaultTermsPath);
      expect(cfg.privacyPath, isEmpty);
      // No published policy → no link at all, rather than a dead one.
      expect(cfg.hasPrivacyPolicy, isFalse);
    });

    test('site-relative paths pass through', () {
      final cfg = AppConfig.fromJson({
        'terms_url': '/terms/',
        'privacy_policy_url': '/privacy/',
      });
      expect(cfg.termsPath, '/terms/');
      expect(cfg.privacyPath, '/privacy/');
      expect(cfg.hasPrivacyPolicy, isTrue);
    });

    test('an absolute URL on our own host is reduced to its path', () {
      final cfg = AppConfig.fromJson({
        'terms_url': 'https://$host/tos/',
        'privacy_policy_url': 'https://$host/privacy/policy/',
      });
      expect(cfg.termsPath, '/tos/');
      expect(cfg.privacyPath, '/privacy/policy/');
    });

    test('an off-host URL is rejected, not followed', () {
      // These load in the restricted WebView the signup flow uses; honoring an
      // arbitrary host would make it a way out of the login trap.
      final cfg = AppConfig.fromJson({
        'terms_url': 'https://evil.example/tos/',
        'privacy_policy_url': 'https://evil.example/privacy/',
      });
      expect(cfg.termsPath, AppConfig.defaultTermsPath);
      expect(cfg.privacyPath, isEmpty);
    });

    test('protocol-relative and junk values fall back', () {
      final cfg = AppConfig.fromJson({
        'terms_url': '//evil.example/tos/',
        'privacy_policy_url': 'not a url',
      });
      expect(cfg.termsPath, AppConfig.defaultTermsPath);
      expect(cfg.privacyPath, isEmpty);
    });

    test('an empty string is treated as unset', () {
      final cfg = AppConfig.fromJson({
        'terms_url': '',
        'privacy_policy_url': '',
      });
      expect(cfg.termsPath, AppConfig.defaultTermsPath);
      expect(cfg.hasPrivacyPolicy, isFalse);
    });
  });
}
