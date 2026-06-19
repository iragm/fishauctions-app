import 'dart:convert';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/printer_model.dart';
import '../services/bluetooth_service.dart';
import '../utils/secure_storage.dart';

const _keyPrinter = 'saved_printer';
const _storage = secureStorage;

class PrinterNotifier extends AsyncNotifier<BluetoothPrinter?> {
  @override
  Future<BluetoothPrinter?> build() => _loadSaved();

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<BluetoothPrinter?> _loadSaved() async {
    final raw = await _storage.read(key: _keyPrinter);
    if (raw == null) {
      return null;
    }
    final saved = BluetoothPrinter.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    // A persisted printer is only *remembered*, not connected — there is no
    // live RFCOMM link on a fresh launch. Never trust a stored `connected:true`
    // or the UI would show a green dot for a socket that doesn't exist.
    return saved.copyWith(connected: BluetoothService.instance.isConnected);
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

  /// Ensures a live link to the remembered printer, reconnecting if the socket
  /// dropped (e.g. after an app restart). Returns the connected printer.
  /// Throws [StateError] if no printer has been set up.
  Future<BluetoothPrinter> ensureConnected() async {
    final saved = state.valueOrNull;
    if (saved == null) {
      throw StateError('No printer configured');
    }
    final bt = BluetoothService.instance;
    if (bt.isConnectedTo(saved.address)) {
      return saved;
    }
    final printer = await bt.connectToAddress(saved.address, name: saved.name);
    state = AsyncData(printer);
    await _persist(printer);
    return printer;
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
