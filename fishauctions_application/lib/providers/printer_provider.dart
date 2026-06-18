import 'dart:convert';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/printer_model.dart';
import '../services/bluetooth_service.dart';

const _keyPrinter = 'saved_printer';
const _storage = FlutterSecureStorage();

class PrinterNotifier extends AsyncNotifier<BluetoothPrinter?> {
  @override
  Future<BluetoothPrinter?> build() => _loadSaved();

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<BluetoothPrinter?> _loadSaved() async {
    final raw = await _storage.read(key: _keyPrinter);
    if (raw == null) {
      return null;
    }
    return BluetoothPrinter.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<void> _persist(BluetoothPrinter? printer) async {
    if (printer == null) {
      await _storage.delete(key: _keyPrinter);
    } else {
      await _storage.write(
        key: _keyPrinter,
        value: jsonEncode(printer.toJson()),
      );
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> connect(BluetoothDevice device) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final printer = await BluetoothService.instance.connect(device);
      await _persist(printer);
      return printer;
    });
  }

  Future<void> disconnect() async {
    await BluetoothService.instance.disconnect();
    final current = state.valueOrNull;
    if (current != null) {
      final updated = current.copyWith(connected: false);
      state = AsyncData(updated);
      await _persist(updated);
    }
  }

  Future<void> forget() async {
    await BluetoothService.instance.disconnect();
    state = const AsyncData(null);
    await _persist(null);
  }
}

final printerProvider =
    AsyncNotifierProvider<PrinterNotifier, BluetoothPrinter?>(
  PrinterNotifier.new,
);
