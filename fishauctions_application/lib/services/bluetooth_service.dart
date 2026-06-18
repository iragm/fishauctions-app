import 'dart:typed_data';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/printer_model.dart';

/// Wraps flutter_bluetooth_serial for thermal label printing.
/// Android only — iOS classic BT requires MFi certification.
class BluetoothService {
  BluetoothService._();
  static final BluetoothService instance = BluetoothService._();

  BluetoothConnection? _connection;
  BluetoothPrinter? _connectedPrinter;

  BluetoothPrinter? get connectedPrinter => _connectedPrinter;
  bool get isConnected =>
      _connection != null && (_connection!.isConnected);

  // ── Permissions ───────────────────────────────────────────────────────────

  Future<bool> requestPermissions() async {
    // Android 12+: BLUETOOTH_SCAN is neverForLocation in the manifest so
    // location isn't needed. Older Android needs it for discovery, but
    // paired-device listing works without it.
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    return statuses.values.every((s) => s.isGranted);
  }

  // ── Discovery ─────────────────────────────────────────────────────────────

  /// Returns already-paired BT devices (no active scan needed for known printers).
  Future<List<BluetoothDevice>> getPairedDevices() =>
      FlutterBluetoothSerial.instance.getBondedDevices();

  /// Starts a discovery scan. Caller must cancel the subscription when done.
  Stream<BluetoothDiscoveryResult> startDiscovery() =>
      FlutterBluetoothSerial.instance.startDiscovery();

  Future<void> cancelDiscovery() =>
      FlutterBluetoothSerial.instance.cancelDiscovery();

  // ── Connection ────────────────────────────────────────────────────────────

  Future<BluetoothPrinter> connect(BluetoothDevice device) async {
    await disconnect();
    _connection = await BluetoothConnection.toAddress(device.address);
    _connectedPrinter = BluetoothPrinter(
      address: device.address,
      name: device.name ?? device.address,
      connected: true,
    );
    return _connectedPrinter!;
  }

  Future<void> disconnect() async {
    if (_connection != null) {
      await _connection!.close();
      _connection = null;
    }
    if (_connectedPrinter != null) {
      _connectedPrinter =
          _connectedPrinter!.copyWith(connected: false);
    }
  }

  // ── Printing ──────────────────────────────────────────────────────────────

  /// Sends raw bytes to the connected printer.
  /// [data] is whatever the backend returns — currently a PNG, eventually
  /// raw TSPL commands when the backend gains that capability.
  Future<void> sendBytes(Uint8List data) async {
    if (_connection == null || !_connection!.isConnected) {
      throw StateError('No printer connected');
    }
    _connection!.output.add(data);
    await _connection!.output.allSent;
  }
}
