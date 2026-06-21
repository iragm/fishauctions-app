import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

// flutter_blue_plus exports its own `BluetoothService` (a GATT service); hide
// it so it doesn't clash with this class. We still consume those service
// objects via type inference from `device.servicesList`.
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:permission_handler/permission_handler.dart';

import '../models/printer_model.dart';
import '../utils/android_platform.dart';
import 'printer_exception.dart';
import 'printer_transport.dart';

export 'printer_exception.dart';

/// Wraps flutter_blue_plus (BLE) for thermal label printing on iOS + Android,
/// and implements [PrinterTransport] so the protocol drivers (e.g.
/// `D11sDriver`) stay hardware-agnostic and testable.
///
/// BLE — not classic SPP — so iOS works without MFi. This is the transport
/// only: label bytes come from a `PrinterDriver`. Connecting prefers the known
/// Fichero/AiYin D11s service/characteristics and falls back to the first
/// writable characteristic for other (raw-command) printers.
class BluetoothService implements PrinterTransport {
  BluetoothService._();
  static final BluetoothService instance = BluetoothService._();

  /// flutter_blue_plus is free under `License.nonprofit` for personal,
  /// nonprofit, and educational use; for-profit use needs a paid commercial
  /// license. auction.fish is treated as nonprofit/hobbyist. If this becomes a
  /// commercial deployment, purchase the commercial license and flip this ONE
  /// constant to `License.commercial`. See the package's LICENSE.md.
  static const _license = License.nonprofit;

  /// How long to wait for a BLE link before giving up, so a powered-off printer
  /// can't hang the UI indefinitely.
  static const _connectTimeout = Duration(seconds: 15);

  // Known Fichero / AiYin D11s GATT identifiers (lowercased 128-bit form, as
  // `Guid.str` returns). Preferred on connect; other printers fall back to
  // generic writable/notify discovery.
  static const _d11sServiceUuid = '000018f0-0000-1000-8000-00805f9b34fb';
  static const _d11sWriteCharUuid = '00002af1-0000-1000-8000-00805f9b34fb';
  static const _d11sNotifyCharUuid = '00002af0-0000-1000-8000-00805f9b34fb';

  // The reference client streams the raster in 200-byte BLE writes spaced 20ms
  // apart; the printer drops data sent faster than this.
  static const _bleChunk = 200;
  static const _bleChunkDelay = Duration(milliseconds: 20);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothPrinter? _connectedPrinter;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  final StreamController<Uint8List> _notifyController =
      StreamController<Uint8List>.broadcast();
  bool _sending = false;

  BluetoothPrinter? get connectedPrinter => _connectedPrinter;

  /// True only with a live link AND a resolved write characteristic — both are
  /// needed to actually print.
  @override
  bool get isConnected =>
      _device != null && _device!.isConnected && _writeChar != null;

  @override
  Stream<Uint8List> get notifications => _notifyController.stream;

  // ── Permissions ───────────────────────────────────────────────────────────

  /// Minimum permissions to connect to a known printer. On Android 12+ this is
  /// BLUETOOTH_CONNECT; older releases fall back to the legacy BLUETOOTH perm.
  Future<bool> requestConnectPermissions() async {
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
    ].request();
    return statuses.values.every((s) => s.isGranted);
  }

  /// Extra permission to *discover* new printers. Android 12+ uses
  /// BLUETOOTH_SCAN (declared neverForLocation, so no location prompt); Android
  /// 11 and below need runtime location to return BLE scan results.
  Future<bool> requestScanPermissions() async {
    final perms = <Permission>[Permission.bluetoothScan];
    if (await AndroidPlatform.sdkInt() < 31) {
      perms.add(Permission.locationWhenInUse);
    }
    final statuses = await perms.request();
    return statuses.values.every((s) => s.isGranted);
  }

  /// True once the user has permanently denied a Bluetooth permission ("Don't
  /// ask again"): the prompt can't reappear, so the only fix is OS settings.
  Future<bool> isPermissionPermanentlyDenied() async =>
      await Permission.bluetoothConnect.isPermanentlyDenied ||
      await Permission.bluetooth.isPermanentlyDenied;

  /// Opens this app's OS settings page so the user can grant a permission they
  /// previously denied permanently.
  Future<void> openSettings() => openAppSettings();

  // ── Adapter state ─────────────────────────────────────────────────────────

  /// Whether the phone's Bluetooth radio is on. Scans and connections fail
  /// confusingly when it's off, so check this first and show a clear prompt.
  Future<bool> isAdapterOn() async =>
      FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;

  /// Asks the OS to turn the radio on. Android can show a system prompt; iOS
  /// has no API for this (the user toggles it in Control Center), so there we
  /// just report whether it's already on.
  Future<bool> requestEnableAdapter() async {
    if (await isAdapterOn()) {
      return true;
    }
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      await FlutterBluePlus.turnOn();
    } on Exception {
      return false;
    }
    return isAdapterOn();
  }

  // ── Discovery ─────────────────────────────────────────────────────────────

  /// Printers the OS already knows — Android's bonded list. Instant, and enough
  /// to reconnect a printer the user paired before without a fresh scan.
  /// (iOS has no equivalent bonded list; rely on scanning there.)
  Future<List<BluetoothDevice>> knownDevices() async {
    try {
      return await FlutterBluePlus.bondedDevices;
    } on Exception {
      return const [];
    }
  }

  /// Live scan results. The caller listens and stops the scan when done.
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  Stream<bool> get isScanningStream => FlutterBluePlus.isScanning;

  bool get isScanning => FlutterBluePlus.isScanningNow;

  Future<void> startScan({Duration timeout = const Duration(seconds: 12)}) =>
      FlutterBluePlus.startScan(timeout: timeout);

  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
  }

  // ── Connection ────────────────────────────────────────────────────────────

  /// Connects to a freshly discovered [device] and resolves its print
  /// characteristic. Returns the printer to remember.
  Future<BluetoothPrinter> connect(
    BluetoothDevice device, {
    String? name,
  }) async {
    final write = await _openLink(device);
    _connectedPrinter = BluetoothPrinter(
      address: device.remoteId.str,
      name: (name != null && name.isNotEmpty)
          ? name
          : (device.platformName.isNotEmpty
                ? device.platformName
                : device.remoteId.str),
      serviceUuid: write.serviceUuid.str,
      characteristicUuid: write.characteristicUuid.str,
      connected: true,
    );
    return _connectedPrinter!;
  }

  /// Re-opens the link to a [saved] printer (e.g. after an app restart),
  /// targeting its remembered characteristic so it doesn't re-sniff the device.
  Future<BluetoothPrinter> reconnect(BluetoothPrinter saved) async {
    final device = BluetoothDevice.fromId(saved.address);
    final write = await _openLink(
      device,
      preferredService: saved.serviceUuid,
      preferredChar: saved.characteristicUuid,
    );
    _connectedPrinter = saved.copyWith(
      serviceUuid: write.serviceUuid.str,
      characteristicUuid: write.characteristicUuid.str,
      connected: true,
    );
    return _connectedPrinter!;
  }

  /// True when a live link to [remoteId] with a usable print channel is open.
  bool isConnectedTo(String remoteId) =>
      isConnected && _connectedPrinter?.address == remoteId;

  Future<void> disconnect() async {
    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;
    final device = _device;
    _device = null;
    _writeChar = null;
    if (device != null) {
      try {
        await device.disconnect();
      } on Exception {
        // Already disconnected — nothing to clean up.
      }
    }
    if (_connectedPrinter != null) {
      _connectedPrinter = _connectedPrinter!.copyWith(connected: false);
    }
  }

  /// Shared connect path: open the GATT link, discover services, then resolve
  /// the write characteristic and subscribe to notifications. Throws a
  /// [PrinterException] with a clear next step for every failure.
  Future<BluetoothCharacteristic> _openLink(
    BluetoothDevice device, {
    String? preferredService,
    String? preferredChar,
  }) async {
    await disconnect();
    if (!await isAdapterOn()) {
      throw const PrinterException(
        'Bluetooth is off. Turn on Bluetooth, then try again.',
      );
    }
    try {
      await device.connect(license: _license, timeout: _connectTimeout);
    } on TimeoutException {
      throw const PrinterException(
        "Couldn't reach the printer. Make sure it's powered on and within a "
        'few feet, then try again.',
      );
    } on Object {
      throw const PrinterException(
        "Couldn't connect to the printer. Make sure it's powered on and in "
        'range, then try again.',
      );
    }
    try {
      await device.discoverServices();
    } on Object {
      await device.disconnect();
      throw const PrinterException(
        "Couldn't read the printer's capabilities. Try again, or forget and "
        're-pair the printer.',
      );
    }
    final write = _resolveWrite(
      device,
      preferredService: preferredService,
      preferredChar: preferredChar,
    );
    if (write == null) {
      await device.disconnect();
      throw const PrinterException(
        "This device doesn't expose a printable channel. Make sure you picked "
        'the right printer.',
      );
    }
    _device = device;
    _writeChar = write;
    _watchConnection(device);
    await _subscribeNotify(device);
    return write;
  }

  /// Picks the characteristic to print through: the remembered one (reconnect),
  /// else the known D11s write characteristic, else the first writable
  /// characteristic (generic/raw printers), preferring write-with-response.
  BluetoothCharacteristic? _resolveWrite(
    BluetoothDevice device, {
    String? preferredService,
    String? preferredChar,
  }) {
    if (preferredChar != null) {
      final c = _findChar(device, preferredChar, service: preferredService);
      if (c != null && _isWritable(c)) {
        return c;
      }
    }
    final known = _findChar(
      device,
      _d11sWriteCharUuid,
      service: _d11sServiceUuid,
    );
    if (known != null && _isWritable(known)) {
      return known;
    }
    BluetoothCharacteristic? fallback;
    for (final s in device.servicesList) {
      for (final c in s.characteristics) {
        if (c.properties.write) {
          return c;
        }
        fallback ??= c.properties.writeWithoutResponse ? c : null;
      }
    }
    return fallback;
  }

  /// Subscribes to the printer's notify characteristic (D11s `2af0`, else the
  /// first notify/indicate characteristic) and forwards its bytes to
  /// [notifications]. Best-effort: raw printers may have none, and printing
  /// still works without status — we just can't read paper/cover/battery.
  Future<void> _subscribeNotify(BluetoothDevice device) async {
    final notify =
        _findChar(device, _d11sNotifyCharUuid, service: _d11sServiceUuid) ??
        _firstNotify(device);
    if (notify == null) {
      return;
    }
    try {
      await notify.setNotifyValue(true);
      _notifySub = notify.onValueReceived.listen((value) {
        if (!_notifyController.isClosed) {
          _notifyController.add(Uint8List.fromList(value));
        }
      });
    } on Object {
      // Status is unavailable, but printing may still work.
    }
  }

  BluetoothCharacteristic? _findChar(
    BluetoothDevice device,
    String charUuid, {
    String? service,
  }) {
    for (final s in device.servicesList) {
      if (service != null && s.serviceUuid.str != service) {
        continue;
      }
      for (final c in s.characteristics) {
        if (c.characteristicUuid.str == charUuid) {
          return c;
        }
      }
    }
    return null;
  }

  BluetoothCharacteristic? _firstNotify(BluetoothDevice device) {
    for (final s in device.servicesList) {
      for (final c in s.characteristics) {
        if (c.properties.notify || c.properties.indicate) {
          return c;
        }
      }
    }
    return null;
  }

  bool _isWritable(BluetoothCharacteristic c) =>
      c.properties.write || c.properties.writeWithoutResponse;

  void _watchConnection(BluetoothDevice device) {
    _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _writeChar = null;
        if (_connectedPrinter != null) {
          _connectedPrinter = _connectedPrinter!.copyWith(connected: false);
        }
      }
    });
  }

  // ── Printing ──────────────────────────────────────────────────────────────

  /// [PrinterTransport.write] — sends [bytes] to the printer, chunked for BLE.
  @override
  Future<void> write(List<int> bytes) =>
      _writeChunked(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

  /// Sends a complete rendered payload as a single job (interim path for the
  /// on-device TSPL renderer / raw printers). Drivers like `D11sDriver` use
  /// [write] directly and sequence their own commands.
  Future<void> sendBytes(Uint8List data) async {
    if (_sending) {
      throw const PrinterException(
        'A label is already printing. Wait for it to finish, then try again.',
      );
    }
    _sending = true;
    try {
      await _writeChunked(data);
    } finally {
      _sending = false;
    }
  }

  /// Writes [data] to the connected printer in MTU-safe chunks (200 bytes,
  /// 20ms apart). Throws a [PrinterException] when the link is missing or
  /// drops.
  Future<void> _writeChunked(Uint8List data) async {
    final device = _device;
    final writeChar = _writeChar;
    if (device == null || writeChar == null || device.isDisconnected) {
      throw const PrinterException(
        'The printer connection dropped. Reconnect the printer and try again.',
      );
    }
    // Use write-without-response only when the characteristic can't do
    // acknowledged writes; acknowledged writes are more reliable for print
    // jobs where a dropped chunk silently truncates the label.
    final withoutResponse =
        !writeChar.properties.write &&
        writeChar.properties.writeWithoutResponse;
    try {
      for (var offset = 0; offset < data.length; offset += _bleChunk) {
        final end = (offset + _bleChunk < data.length)
            ? offset + _bleChunk
            : data.length;
        await writeChar.write(
          Uint8List.sublistView(data, offset, end),
          withoutResponse: withoutResponse,
        );
        if (end < data.length) {
          await Future<void>.delayed(_bleChunkDelay);
        }
      }
    } on PrinterException {
      rethrow;
    } on Object {
      throw const PrinterException(
        'Lost connection to the printer while printing. Keep it on and in '
        'range, then print again.',
      );
    }
  }
}
