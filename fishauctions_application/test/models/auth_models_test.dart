import 'package:fishauctions_application/models/auth_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppUser.fromJson', () {
    test('maps snake_case fields and parses date_joined', () {
      final user = AppUser.fromJson({
        'id': 7,
        'username': 'angelfish',
        'email': 'a@example.com',
        'first_name': 'Ada',
        'last_name': 'Fish',
        'is_staff': true,
        'date_joined': '2024-01-02T03:04:05Z',
      });

      expect(user.id, 7);
      expect(user.username, 'angelfish');
      expect(user.firstName, 'Ada');
      expect(user.lastName, 'Fish');
      expect(user.isStaff, isTrue);
      expect(user.dateJoined, DateTime.utc(2024, 1, 2, 3, 4, 5));
    });

    test('applies defaults when optional fields are absent', () {
      final user = AppUser.fromJson({
        'id': 1,
        'username': 'guest',
        'email': 'g@example.com',
      });

      expect(user.firstName, '');
      expect(user.lastName, '');
      expect(user.isStaff, isFalse);
      expect(user.dateJoined, isNull);
    });
  });

  group('TokenPair.fromJson', () {
    test('reads access and refresh tokens', () {
      final pair = TokenPair.fromJson({'access': 'a.b.c', 'refresh': 'd.e.f'});
      expect(pair.access, 'a.b.c');
      expect(pair.refresh, 'd.e.f');
    });
  });
}
