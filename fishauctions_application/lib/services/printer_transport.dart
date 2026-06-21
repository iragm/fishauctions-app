import 'dart:typed_data';

/// The minimal byte-level link a printer driver needs, independent of the
/// Bluetooth implementation. `BluetoothService` implements this over BLE; a
/// fake implements it in tests so the protocol drivers are testable without
/// hardware.
abstract interface class PrinterTransport {
  /// True when a live link with a usable write channel is open.
  bool get isConnected;

  /// Bytes received on the printer's notify characteristic (status replies,
  /// end-of-print acks). A broadcast stream — drivers subscribe before writing
  /// the command whose reply they're waiting for, so they can't miss it.
  Stream<Uint8List> get notifications;

  /// Writes [bytes] to the printer, splitting into BLE-sized chunks as needed.
  /// Throws a `PrinterException` if the link is missing or drops mid-write.
  Future<void> write(List<int> bytes);
}
