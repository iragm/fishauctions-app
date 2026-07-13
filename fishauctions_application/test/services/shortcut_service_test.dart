import 'package:fishauctions_application/services/shortcut_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pathForType', () {
    test('maps every registered shortcut to its web path', () {
      expect(
        ShortcutService.pathForType('lots_last_auction'),
        '/lots/my-last-auction/',
      );
      expect(ShortcutService.pathForType('selling'), '/selling/');
      expect(ShortcutService.pathForType('invoices'), '/invoices/');
    });

    test('an unknown type (stale launcher-pinned shortcut) maps to null', () {
      expect(ShortcutService.pathForType('removed_in_v2'), isNull);
    });
  });

  group('pending / consume', () {
    test('consume returns the pending path exactly once', () {
      final service = ShortcutService.instance;
      service.pending.value = '/selling/';
      expect(service.consume(), '/selling/');
      // Cleared: a second consumer (e.g. the running-shell listener after
      // _initialUrl already took it) must not navigate again.
      expect(service.consume(), isNull);
    });

    test('a newer tap replaces an unconsumed one', () {
      final service = ShortcutService.instance;
      service.pending.value = '/selling/';
      service.pending.value = '/invoices/';
      expect(service.consume(), '/invoices/');
      expect(service.consume(), isNull);
    });
  });
}
