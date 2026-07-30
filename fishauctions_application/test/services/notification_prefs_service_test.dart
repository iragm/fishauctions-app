import 'package:fishauctions_application/services/notification_prefs_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// `notifications/prefs/` parsing. Same defensive contract as every other
/// optional mobile endpoint: a body that isn't the expected shape must read as
/// "off", never throw — the caller's fallback is to point the user at the web
/// preferences page, which is always correct.
void main() {
  group('NotificationPrefs.tryParse', () {
    test('reads both toggles', () {
      final prefs = NotificationPrefs.tryParse({
        'push_instead_of_email': true,
        'push_when_lots_sell': true,
      })!;
      expect(prefs.pushInsteadOfEmail, isTrue);
      expect(prefs.pushWhenLotsSell, isTrue);
      expect(prefs.allOn, isTrue);
    });

    test('one toggle off is not allOn', () {
      final prefs = NotificationPrefs.tryParse({
        'push_instead_of_email': true,
        'push_when_lots_sell': false,
      })!;
      expect(prefs.allOn, isFalse);
    });

    test('missing keys read as off', () {
      final prefs = NotificationPrefs.tryParse(<String, dynamic>{})!;
      expect(prefs.pushInsteadOfEmail, isFalse);
      expect(prefs.pushWhenLotsSell, isFalse);
    });

    test('non-boolean truthy values are not treated as true', () {
      // Only a real `true` counts: a string "1" from a hand-rolled response
      // must not silently claim the user opted in.
      final prefs = NotificationPrefs.tryParse({
        'push_instead_of_email': '1',
        'push_when_lots_sell': 1,
      })!;
      expect(prefs.allOn, isFalse);
    });

    test('a non-map body yields null', () {
      expect(NotificationPrefs.tryParse(null), isNull);
      expect(NotificationPrefs.tryParse('nope'), isNull);
    });
  });
}
