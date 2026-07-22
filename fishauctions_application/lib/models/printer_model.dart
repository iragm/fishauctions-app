import 'package:freezed_annotation/freezed_annotation.dart';

part 'printer_model.freezed.dart';
part 'printer_model.g.dart';

@freezed
abstract class BluetoothPrinter with _$BluetoothPrinter {
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
    // The ThermalPrinterProfile driving this printer (see
    // PrinterProfileService). Null for printers saved by pre-profile app
    // builds, which resolve to the D11s profile those builds hardcoded.
    String? profileSlug,
    // Label media size the printer itself reported on connect (profiles with
    // a label_size_program). Null when the printer can't say — the user's
    // label prefs are the fallback.
    double? labelWidthMm,
    double? labelHeightMm,
    // True while an active connection is open.
    @Default(false) bool connected,
  }) = _BluetoothPrinter;

  factory BluetoothPrinter.fromJson(Map<String, dynamic> json) =>
      _$BluetoothPrinterFromJson(json);
}
