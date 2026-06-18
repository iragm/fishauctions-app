import 'package:freezed_annotation/freezed_annotation.dart';

part 'printer_model.freezed.dart';
part 'printer_model.g.dart';

@freezed
class BluetoothPrinter with _$BluetoothPrinter {
  const factory BluetoothPrinter({
    required String address,
    required String name,
    // True while an active connection is open.
    @Default(false) bool connected,
  }) = _BluetoothPrinter;

  factory BluetoothPrinter.fromJson(Map<String, dynamic> json) =>
      _$BluetoothPrinterFromJson(json);
}
