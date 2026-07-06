import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/printer_model.dart';
import '../models/printer_profile.dart';
import '../services/bluetooth_service.dart';
import '../services/printer_profile_driver.dart';
import '../services/printer_profile_service.dart';
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

  /// Connects [device] driving it with [profile] (matched by BLE name or
  /// picked by the user in the connect sheet), then — when the profile can —
  /// asks the printer what label roll is loaded so the `/printing/` page can
  /// offer to adopt that size.
  Future<void> connect(
    BluetoothDevice device, {
    String? name,
    PrinterProfile? profile,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      var printer = await BluetoothService.instance.connect(
        device,
        name: name,
        profile: profile,
      );
      if (profile != null) {
        printer = await _withReportedLabelSize(printer, profile);
      }
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
    final profile = await PrinterProfileService.instance.bySlug(
      saved.profileSlug,
    );
    final printer = await bt.reconnect(saved, profile: profile);
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

  /// Best-effort label-size read-back (profiles without a size program, or
  /// printers that don't answer, just don't report one — never an error).
  Future<BluetoothPrinter> _withReportedLabelSize(
    BluetoothPrinter printer,
    PrinterProfile profile,
  ) async {
    try {
      final size = await PrinterProfileDriver(
        BluetoothService.instance,
        profile,
      ).readLabelSize();
      if (size == null) {
        return printer;
      }
      return printer.copyWith(
        labelWidthMm: size.widthMm,
        labelHeightMm: size.heightMm,
      );
    } on Object {
      return printer;
    }
  }
}

final printerProvider =
    AsyncNotifierProvider<PrinterNotifier, BluetoothPrinter?>(
      PrinterNotifier.new,
    );
