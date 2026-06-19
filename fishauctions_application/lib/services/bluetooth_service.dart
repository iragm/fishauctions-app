import 'dart:typed_data';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/printer_model.dart';
import '../utils/android_platform.dart';

/// Wraps flutter_bluetooth_serial for thermal label printing.
/// Android only — iOS classic BT requires MFi certification.
class BluetoothService {
  BluetoothService._();
  static final BluetoothService instance = BluetoothService._();

  BluetoothConnection? _connection;
  BluetoothPrinter? _connectedPrinter;

  BluetoothPrinter? get connectedPrinter => _connectedPrinter;
  bool get isConnected => _connection != null && (_connection!.isConnected);

  // ── Permissions ───────────────────────────────────────────────────────────

  /// Minimum permissions to open an RFCOMM link to a known/paired printer.
  /// Listing bonded devices and connecting needs CONNECT but not SCAN, so this
  /// never triggers a location prompt.
  Future<bool> requestConnectPermissions() async {
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
    ].request();
    return statuses.values.every((s) => s.isGranted);
  }

  /// Extra permissions needed to *discover* new (unpaired) printers.
  ///
  /// Android 12+ (API 31+) uses BLUETOOTH_SCAN (declared neverForLocation, so
  /// no location prompt). Android 11 and below cannot return classic-BT
  /// discovery results without the runtime location permission, so request it
  /// there. Connecting to already-paired printers does not need this.
  Future<bool> requestScanPermissions() async {
    final perms = <Permission>[Permission.bluetoothScan];
    if (await AndroidPlatform.sdkInt() < 31) {
      perms.add(Permission.locationWhenInUse);
    }
    final statuses = await perms.request();
    return statuses.values.every((s) => s.isGranted);
  }

  // ── Discovery ─────────────────────────────────────────────────────────────

  /// Returns already-paired BT devices. No active scan is needed to reconnect
  /// to a printer the user has paired before.
  Future<List<BluetoothDevice>> getPairedDevices() =>
      FlutterBluetoothSerial.instance.getBondedDevices();

  /// Starts a discovery scan. Caller must cancel the subscription when done.
  Stream<BluetoothDiscoveryResult> startDiscovery() =>
      FlutterBluetoothSerial.instance.startDiscovery();

  Future<void> cancelDiscovery() =>
      FlutterBluetoothSerial.instance.cancelDiscovery();

  // ── Connection ────────────────────────────────────────────────────────────

  Future<BluetoothPrinter> connect(BluetoothDevice device) =>
      connectToAddress(device.address, name: device.name);

  /// Opens an RFCOMM connection to a MAC [address]. Used both for the initial
  /// pairing (from a discovered [BluetoothDevice]) and to silently reconnect to
  /// a remembered printer before a print job.
  Future<BluetoothPrinter> connectToAddress(
    String address, {
    String? name,
  }) async {
    await disconnect();
    _connection = await BluetoothConnection.toAddress(address);
    _connectedPrinter = BluetoothPrinter(
      address: address,
      name: (name == null || name.isEmpty) ? address : name,
      connected: true,
    );
    return _connectedPrinter!;
  }

  /// True when an RFCOMM link to [address] is currently open.
  bool isConnectedTo(String address) =>
      isConnected && _connectedPrinter?.address == address;

  Future<void> disconnect() async {
    if (_connection != null) {
      await _connection!.close();
      _connection = null;
    }
    if (_connectedPrinter != null) {
      _connectedPrinter = _connectedPrinter!.copyWith(connected: false);
    }
  }

  // ── Printing ──────────────────────────────────────────────────────────────

  /// Sends raw bytes to the connected printer.
  ///
  /// [data] is whatever the backend returns — currently a PNG, eventually
  /// raw TSPL commands when the backend gains that capability.
  ///
  /// Writes in [chunkSize]-byte chunks and waits for each to drain. Sending a
  /// whole label image in one `add()` can overflow the RFCOMM output buffer on
  /// many thermal printers and silently truncate the print.
  Future<void> sendBytes(Uint8List data, {int chunkSize = 512}) async {
    final conn = _connection;
    if (conn == null || !conn.isConnected) {
      throw StateError('No printer connected');
    }
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    for (var offset = 0; offset < data.length; offset += chunkSize) {
      final end = (offset + chunkSize < data.length)
          ? offset + chunkSize
          : data.length;
      conn.output.add(Uint8List.sublistView(data, offset, end));
      await conn.output.allSent;
    }
  }
}
