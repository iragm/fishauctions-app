import 'package:fishauctions_application/services/push_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('consumeRoute', () {
    test('returns the pending route exactly once', () {
      final service = PushService.instance;
      service.pendingRoute.value = '/lots/123/';
      expect(service.consumeRoute(), '/lots/123/');
      // Cleared: the cold-start pickup in _onWebViewCreated and the listener
      // must not both navigate.
      expect(service.consumeRoute(), isNull);
    });

    test('null when nothing is pending', () {
      PushService.instance.pendingRoute.value = null;
      expect(PushService.instance.consumeRoute(), isNull);
    });
  });
}
