import 'package:freezed_annotation/freezed_annotation.dart';

part 'printer_model.freezed.dart';
part 'printer_model.g.dart';

@freezed
class BluetoothPrinter with _$BluetoothPrinter {
  const factory BluetoothPrinter({
    // The BLE remote identifier (Android MAC, iOS OS-assigned UUID). Used to
    // reconnect without a fresh scan via `BluetoothDevice.fromId`.
    required String address,
    required String name,
    // The GATT characteristic we write label bytes to, once discovered. Stored
    // so a reconnect can target it directly instead of re-sniffing the device.
    // Null until the printer has been connected at least once.
    String? serviceUuid,
    String? characteristicUuid,
    // True while an active connection is open.
    @Default(false) bool connected,
  }) = _BluetoothPrinter;

  factory BluetoothPrinter.fromJson(Map<String, dynamic> json) =>
      _$BluetoothPrinterFromJson(json);
}
