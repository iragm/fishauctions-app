import 'package:fishauctions_application/services/printer_setup_prompt.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('PrinterSetupPrompt', () {
    // The whole point: printing with nothing paired takes the user to the
    // printing page once. A print button that keeps yanking them off the page
    // they were on is worse than no printer.
    test('walks the user to setup on the first print only', () async {
      final prompt = PrinterSetupPrompt.instance;

      expect(await prompt.consumeFirstRun(), isTrue);
      expect(await prompt.consumeFirstRun(), isFalse);
      expect(await prompt.consumeFirstRun(), isFalse);
    });

    // Unpairing is starting over, so the automatic trip is useful again.
    test('reset restores first-run behavior', () async {
      final prompt = PrinterSetupPrompt.instance;
      await prompt.consumeFirstRun();

      await prompt.reset();

      expect(await prompt.consumeFirstRun(), isTrue);
    });
  });
}
