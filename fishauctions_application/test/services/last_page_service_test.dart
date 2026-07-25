import 'dart:convert';

import 'package:fishauctions_application/services/last_page_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = LastPageService.instance;

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  /// Plants a saved page as if it had been written [age] ago by [user].
  Future<void> seed(String path, {int user = 1, Duration? age}) =>
      const FlutterSecureStorage().write(
        key: 'last_web_page',
        value: jsonEncode({
          'path': path,
          'user': user,
          'at': DateTime.now()
              .subtract(age ?? Duration.zero)
              .millisecondsSinceEpoch,
        }),
      );

  test('restores the page the same user was last on', () async {
    await service.remember('/lots/42/?src=lot_list', userId: 7);
    expect(await service.restore(userId: 7), '/lots/42/?src=lot_list');
  });

  test('nothing saved yet', () async {
    expect(await service.restore(userId: 7), isNull);
  });

  test("never restores another account's page", () async {
    await service.remember('/invoices/9/', userId: 7);
    expect(await service.restore(userId: 8), isNull);
  });

  test('a stale page is not where the user is any more', () async {
    await seed(
      '/lots/42/',
      user: 7,
      age: LastPageService.maxAge + const Duration(minutes: 1),
    );
    expect(await service.restore(userId: 7), isNull);
    await seed(
      '/lots/42/',
      user: 7,
      age: LastPageService.maxAge - const Duration(minutes: 1),
    );
    expect(await service.restore(userId: 7), '/lots/42/');
  });

  test('auth plumbing pages are never saved', () async {
    await service.remember('/login/?next=/lots/1/', userId: 7);
    await service.remember('/api/mobile/auth/web-session/consume/', userId: 7);
    await service.remember('/logout/', userId: 7);
    expect(await service.restore(userId: 7), isNull);
  });

  test('sign-out forgets it', () async {
    await service.remember('/lots/42/', userId: 7);
    await service.clear();
    expect(await service.restore(userId: 7), isNull);
  });

  test('corrupt storage degrades to no restore', () async {
    await const FlutterSecureStorage().write(
      key: 'last_web_page',
      value: 'not json',
    );
    expect(await service.restore(userId: 7), isNull);
  });
}
