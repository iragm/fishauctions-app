import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

// flutter_blue_plus exports its own `BluetoothService` (a GATT service); hide
// it so it doesn't clash with this class. We still consume those service
// objects via type inference from `device.servicesList`.
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:permission_handler/permission_handler.dart';

import '../models/printer_model.dart';
import '../models/printer_profile.dart';
import '../utils/platform_bridge.dart';
import 'printer_exception.dart';
import 'printer_transport.dart';

export 'printer_exception.dart';

/// Wraps flutter_blue_plus (BLE) for thermal label printing on iOS + Android,
/// and implements [PrinterTransport] so `PrinterProfileDriver` stays
/// hardware-agnostic and testable.
///
/// BLE — not classic SPP — so iOS works without MFi. This is the transport
/// only: which bytes to send comes from the printer's [PrinterProfile], which
/// also names the GATT service/characteristics to use (falling back to the
/// first writable characteristic when it doesn't) and sets the write pacing.
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

  // Write pacing, set per-connection from the printer's profile (thermal
  // printers drop data sent faster than their link can take). The defaults
  // match the most conservative profile in use.
  int _chunkSize = 200;
  Duration _chunkDelay = const Duration(milliseconds: 20);
  bool _preferWriteWithResponse = true;
  // When the previous chunk finished, so pacing spans write() calls — a
  // command sent right after a raster stream must not tailgate its last chunk.
  DateTime _lastChunkAt = DateTime.fromMillisecondsSinceEpoch(0);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothPrinter? _connectedPrinter;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  final StreamController<Uint8List> _notifyController =
      StreamController<Uint8List>.broadcast();

  BluetoothPrinter? get connectedPrinter => _connectedPrinter;

  /// True only with a live link AND a resolved write characteristic — both are
  /// needed to actually print.
  @override
  bool get isConnected =>
      _device != null && _device!.isConnected && _writeChar != null;

  @override
  Stream<Uint8List> get notifications => _notifyController.stream;

  // ── Permissions ───────────────────────────────────────────────────────────

  /// Android 12 (API 31) — where the Bluetooth permission model changed from
  /// one install-time permission to the runtime CONNECT/SCAN pair.
  static const _androidS = 31;

  /// The runtime permission that gates *connecting* on this platform and OS
  /// release, or null when there's nothing to request.
  ///
  /// This has to be resolved per-release rather than asked for as a fixed set:
  /// permission_handler resolves every group against the *effective* manifest
  /// and reports a group that isn't in it as plain `denied` — never prompting,
  /// never grantable. Each of the Bluetooth groups is missing somewhere:
  ///
  ///  * **Android 12+** — legacy `BLUETOOTH` is declared `maxSdkVersion="30"`
  ///    (per Google's guidance), so the package manager strips it from the
  ///    installed package and `Permission.bluetooth` is permanently `denied`.
  ///  * **Android 11 and below** — `BLUETOOTH_CONNECT` doesn't exist yet, and
  ///    permission_handler denies it rather than treating it as unnecessary.
  ///    Legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` are install-time, so there is no
  ///    runtime request to make at all.
  ///  * **iOS** — `bluetoothConnect`/`bluetoothScan` are Android-only groups
  ///    and fall through to permission_handler's "unknown" strategy, which
  ///    also denies. CoreBluetooth prompts on first use instead, and a refusal
  ///    surfaces as [BluetoothAdapterState.unauthorized] (see
  ///    [isAdapterUnauthorized]) — a more reliable signal than the plugin's.
  ///
  /// Demanding *all* of them (which this used to) is therefore unsatisfiable
  /// on every platform: that's what the "Bluetooth permission is required"
  /// dead end was.
  Future<Permission?> _connectPermission() async {
    if (!Platform.isAndroid) {
      return null;
    }
    return await PlatformBridge.sdkInt() >= _androidS
        ? Permission.bluetoothConnect
        : null;
  }

  /// Minimum permission to connect to a known printer. True when the OS needs
  /// none at runtime (see [_connectPermission]).
  Future<bool> requestConnectPermissions() async {
    final permission = await _connectPermission();
    if (permission == null) {
      return true;
    }
    return (await permission.request()).isGranted;
  }

  /// Extra permission to *discover* new printers. Android 12+ uses
  /// BLUETOOTH_SCAN (declared neverForLocation, so no location prompt); Android
  /// 11 and below have no such permission and instead need runtime location,
  /// which is what makes the OS return BLE scan results there. iOS needs
  /// neither — the CoreBluetooth authorization covers scanning.
  Future<bool> requestScanPermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }
    final permission = await PlatformBridge.sdkInt() >= _androidS
        ? Permission.bluetoothScan
        : Permission.locationWhenInUse;
    return (await permission.request()).isGranted;
  }

  /// True once the user has permanently denied the connect permission ("Don't
  /// ask again"): the prompt can't reappear, so the only fix is OS settings.
  Future<bool> isPermissionPermanentlyDenied() async =>
      await (await _connectPermission())?.isPermanentlyDenied ?? false;

  /// Opens this app's OS settings page so the user can grant a permission they
  /// previously denied permanently.
  Future<void> openSettings() => openAppSettings();

  // ── Adapter state ─────────────────────────────────────────────────────────

  /// How long to wait for the platform's first adapter-state answer before
  /// giving up — only hit if the channel is wedged.
  static const _adapterStateTimeout = Duration(seconds: 5);

  /// The radio's real state, fetching it from the platform when nobody has yet.
  ///
  /// `adapterStateNow` is only a *cache*: it reads `unknown` until something
  /// has actually asked the platform, and nothing does at startup (Android's
  /// side listens for state *changes*, iOS won't have built its central
  /// manager). Awaiting the stream's first value is what performs that fetch.
  /// Reading the cache directly on a cold process therefore reports a radio
  /// that's on as off.
  Future<BluetoothAdapterState> adapterState() async {
    final cached = FlutterBluePlus.adapterStateNow;
    if (cached != BluetoothAdapterState.unknown) {
      return cached;
    }
    try {
      return await FlutterBluePlus.adapterState.first.timeout(
        _adapterStateTimeout,
      );
    } on Object {
      return FlutterBluePlus.adapterStateNow;
    }
  }

  /// Whether the phone's Bluetooth radio is on. Scans and connections fail
  /// confusingly when it's off, so check this first and show a clear prompt.
  Future<bool> isAdapterOn() async =>
      await adapterState() == BluetoothAdapterState.on;

  /// The adapter is unusable *because the OS is refusing this app Bluetooth*,
  /// not because the radio is switched off — so "turn Bluetooth on" would be
  /// the wrong thing to tell the user; only OS settings can fix it. This is
  /// how a declined CoreBluetooth prompt shows up on iOS, and how a revoked
  /// BLUETOOTH_CONNECT can show up on Android.
  ///
  /// Reads the cache deliberately: it's only meaningful right after an
  /// [isAdapterOn] / [adapterState] call has populated it.
  bool get isAdapterUnauthorized =>
      FlutterBluePlus.adapterStateNow == BluetoothAdapterState.unauthorized;

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

  /// Connects to a freshly discovered [device], targeting [profile]'s GATT
  /// ids and adopting its write pacing (generic discovery + defaults when the
  /// profile doesn't specify). Returns the printer to remember.
  Future<BluetoothPrinter> connect(
    BluetoothDevice device, {
    String? name,
    PrinterProfile? profile,
  }) async {
    final write = await _openLink(
      device,
      preferredService: profile?.serviceUuid,
      preferredChar: profile?.writeCharacteristicUuid,
      profile: profile,
    );
    _connectedPrinter = BluetoothPrinter(
      address: device.remoteId.str,
      name: (name != null && name.isNotEmpty)
          ? name
          : (device.platformName.isNotEmpty
                ? device.platformName
                : device.remoteId.str),
      serviceUuid: write.serviceUuid.str,
      characteristicUuid: write.characteristicUuid.str,
      profileSlug: profile?.slug,
      connected: true,
    );
    return _connectedPrinter!;
  }

  /// Re-opens the link to a [saved] printer (e.g. after an app restart),
  /// targeting its remembered characteristic so it doesn't re-sniff the
  /// device. [profile] restores the pacing/notify setup (resolved from
  /// `saved.profileSlug` by the caller).
  Future<BluetoothPrinter> reconnect(
    BluetoothPrinter saved, {
    PrinterProfile? profile,
  }) async {
    final device = BluetoothDevice.fromId(saved.address);
    final write = await _openLink(
      device,
      preferredService: saved.serviceUuid,
      preferredChar: saved.characteristicUuid,
      profile: profile,
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
    PrinterProfile? profile,
  }) async {
    await disconnect();
    _chunkSize = profile?.chunkSize ?? 200;
    _chunkDelay = Duration(milliseconds: profile?.chunkDelayMs ?? 20);
    _preferWriteWithResponse = profile?.preferWriteWithResponse ?? true;
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
    await _subscribeNotify(device, profile: profile);
    return write;
  }

  /// Picks the characteristic to print through: the preferred one (the
  /// profile's write characteristic, or the remembered one on reconnect),
  /// else the first writable characteristic (profiles with no GATT ids),
  /// preferring write-with-response.
  BluetoothCharacteristic? _resolveWrite(
    BluetoothDevice device, {
    String? preferredService,
    String? preferredChar,
  }) {
    if (preferredChar != null && preferredChar.isNotEmpty) {
      final c = _findChar(
        device,
        preferredChar,
        service: (preferredService?.isEmpty ?? true) ? null : preferredService,
      );
      if (c != null && _isWritable(c)) {
        return c;
      }
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

  /// Subscribes to the printer's notify characteristic (the profile's, else
  /// the first notify/indicate characteristic) and forwards its bytes to
  /// [notifications]. Best-effort: raw printers may have none, and printing
  /// still works without status — we just can't read paper/cover/battery.
  Future<void> _subscribeNotify(
    BluetoothDevice device, {
    PrinterProfile? profile,
  }) async {
    final notifyUuid = profile?.notifyCharacteristicUuid ?? '';
    final serviceUuid = profile?.serviceUuid ?? '';
    final notify = notifyUuid.isEmpty
        ? _firstNotify(device)
        : (_findChar(
                device,
                notifyUuid,
                service: serviceUuid.isEmpty ? null : serviceUuid,
              ) ??
              _firstNotify(device));
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

  /// [PrinterTransport.write] — sends [bytes] to the printer, chunked and
  /// paced per the connected printer's profile. Throws a [PrinterException]
  /// when the link is missing or drops.
  @override
  Future<void> write(List<int> bytes) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final device = _device;
    final writeChar = _writeChar;
    if (device == null || writeChar == null || device.isDisconnected) {
      throw const PrinterException(
        'The printer connection dropped. Reconnect the printer and try again.',
      );
    }
    // Acknowledged writes are more reliable for print jobs (a dropped chunk
    // silently truncates the label), so they're the default; a profile can
    // opt for write-without-response where the printer prefers it, and a
    // characteristic that only supports one kind gets that kind.
    final withoutResponse =
        writeChar.properties.writeWithoutResponse &&
        (!_preferWriteWithResponse || !writeChar.properties.write);
    try {
      for (var offset = 0; offset < data.length; offset += _chunkSize) {
        final end = (offset + _chunkSize < data.length)
            ? offset + _chunkSize
            : data.length;
        // Pacing spans write() calls: the printer sees one byte stream, so a
        // command following a raster must keep the same inter-chunk gap.
        final sinceLast = DateTime.now().difference(_lastChunkAt);
        if (sinceLast < _chunkDelay) {
          await Future<void>.delayed(_chunkDelay - sinceLast);
        }
        await writeChar.write(
          Uint8List.sublistView(data, offset, end),
          withoutResponse: withoutResponse,
        );
        _lastChunkAt = DateTime.now();
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
