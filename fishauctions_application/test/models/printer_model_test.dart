import 'package:fishauctions_application/models/printer_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BluetoothPrinter', () {
    test('defaults connected to false', () {
      const printer = BluetoothPrinter(address: '00:11', name: 'Label');
      expect(printer.connected, isFalse);
    });

    test('survives a JSON round-trip', () {
      const printer = BluetoothPrinter(
        address: 'AA:BB:CC',
        name: 'Zebra',
        connected: true,
      );
      final restored = BluetoothPrinter.fromJson(printer.toJson());
      expect(restored, printer);
    });

    test('copyWith updates the connected flag only', () {
      const printer = BluetoothPrinter(address: 'AA:BB', name: 'Zebra');
      final updated = printer.copyWith(connected: true);
      expect(updated.connected, isTrue);
      expect(updated.address, printer.address);
      expect(updated.name, printer.name);
    });
  });
}
