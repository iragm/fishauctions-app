import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/printer_profile.dart';
import '../providers/printer_provider.dart';
import '../services/bluetooth_service.dart';
import '../services/printer_profile_service.dart';

/// The native "connect a Bluetooth printer" flow, shown as a modal bottom
/// sheet *over* the current page — the `/printing/` web page stays the one
/// place printing is configured, and its Bluetooth card opens this sheet via
/// the `printerConnect` JS handler (the print screen also opens it when no
/// printer is set up yet).
///
/// Flow: connect permission → (Android ≤11: location permission) → scan →
/// pick a device → profile match by BLE name, or a manual profile pick when
/// nothing matches → connect. Resolves when the sheet closes; callers read
/// the outcome from [printerProvider].
class PrinterConnectSheet extends ConsumerStatefulWidget {
  const PrinterConnectSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const PrinterConnectSheet(),
  );

  @override
  ConsumerState<PrinterConnectSheet> createState() =>
      _PrinterConnectSheetState();
}

class _PrinterConnectSheetState extends ConsumerState<PrinterConnectSheet> {
  // Discovered + known printers, keyed by BLE remote id (de-dups scan repeats).
  final Map<String, ({BluetoothDevice device, String name})> _devices = {};
  List<PrinterProfile> _profiles = const [];
  bool _scanning = false;
  bool _connecting = false;
  String? _error;
  // When set, the error has a concrete fix the user can take from here.
  bool _needsBluetoothOn = false;
  bool _needsSettings = false;

  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  StreamSubscription<bool>? _scanStateSub;

  @override
  void initState() {
    super.initState();
    // Keep the spinner in sync with the real scan state (it auto-stops on
    // timeout).
    _scanStateSub = BluetoothService.instance.isScanningStream.listen((on) {
      if (mounted) {
        setState(() => _scanning = on);
      }
    });
    unawaited(_loadProfiles());
    unawaited(_checkPermissionsAndScan());
  }

  Future<void> _loadProfiles() async {
    final profiles = await PrinterProfileService.instance.getProfiles();
    if (mounted) {
      setState(() => _profiles = profiles);
    }
  }

  Future<void> _checkPermissionsAndScan() async {
    setState(() => _needsSettings = false);
    final canConnect = await BluetoothService.instance
        .requestConnectPermissions();
    if (!mounted) {
      return;
    }
    if (!canConnect) {
      // A permanent denial can't be re-prompted — the only fix is OS settings,
      // so point the user there instead of repeating an unactionable message.
      final permanent = await BluetoothService.instance
          .isPermissionPermanentlyDenied();
      if (!mounted) {
        return;
      }
      setState(() {
        _needsSettings = permanent;
        _error = permanent
            ? 'Bluetooth permission is off for this app. Open settings to '
                  'allow it, then come back and scan.'
            : 'Bluetooth permission is required to use a printer.';
      });
      return;
    }
    await _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _error = null;
      _needsBluetoothOn = false;
      _devices.clear();
    });

    // The radio has to be on before anything else; otherwise reads and
    // connections fail with opaque errors. Offer to turn it on right here.
    if (!await BluetoothService.instance.isAdapterOn()) {
      if (!mounted) {
        return;
      }
      setState(() {
        _needsBluetoothOn = true;
        _error = 'Bluetooth is off. Turn it on to find your printer.';
      });
      return;
    }

    // Known/bonded printers first — instant, and enough to reconnect.
    for (final d in await BluetoothService.instance.knownDevices()) {
      _addDevice(d, d.platformName);
    }
    if (!mounted) {
      return;
    }
    setState(() {});

    // Discovering *new* printers needs scan permission — and on Android 11
    // and below, location, which is the OS's requirement for BLE scans.
    final canScan = await BluetoothService.instance.requestScanPermissions();
    if (!mounted) {
      return;
    }
    if (!canScan) {
      setState(() {
        _error =
            'Allow nearby-device scanning to find new printers. '
            'Known printers above still work.';
      });
      return;
    }

    await _scanResultsSub?.cancel();
    _scanResultsSub = BluetoothService.instance.scanResults.listen((results) {
      if (!mounted) {
        return;
      }
      setState(() {
        for (final r in results) {
          final advName = r.advertisementData.advName;
          _addDevice(
            r.device,
            advName.isNotEmpty ? advName : r.device.platformName,
          );
        }
      });
    });

    try {
      await BluetoothService.instance.stopScan();
      await BluetoothService.instance.startScan();
    } on Exception {
      if (!mounted) {
        return;
      }
      setState(
        () => _error = 'Could not start scanning. Make sure Bluetooth is on.',
      );
    }
  }

  void _addDevice(BluetoothDevice device, String name) {
    final id = device.remoteId.str;
    _devices[id] = (device: device, name: name.isNotEmpty ? name : id);
  }

  Future<void> _turnOnBluetooth() async {
    final on = await BluetoothService.instance.requestEnableAdapter();
    if (!mounted) {
      return;
    }
    if (on) {
      await _checkPermissionsAndScan();
    } else {
      setState(
        () => _error =
            'Bluetooth is still off. Turn it on in Quick Settings, then '
            'tap Scan again.',
      );
    }
  }

  PrinterProfile? _matchProfile(String name) {
    for (final profile in _profiles) {
      if (profile.matchesName(name)) {
        return profile;
      }
    }
    return null;
  }

  Future<void> _connect(BluetoothDevice device, String name) async {
    setState(() {
      _error = null;
      _connecting = true;
    });
    await BluetoothService.instance.stopScan();

    // The profile decides every byte the app will send. Auto-match by BLE
    // name; when nothing matches, the user picks (covers renamed units and
    // the raw ESC/POS fallback profile, which never auto-matches).
    var profile = _matchProfile(name);
    if (profile == null && mounted) {
      profile = await _pickProfile(name);
      if (profile == null) {
        setState(() => _connecting = false);
        return; // user cancelled
      }
    }

    await ref
        .read(printerProvider.notifier)
        .connect(device, name: name, profile: profile);
    if (!mounted) {
      return;
    }
    setState(() => _connecting = false);

    final result = ref.read(printerProvider);
    if (result.hasError) {
      final err = result.error;
      setState(() {
        _error = err is PrinterException
            ? err.message
            : 'Could not connect to $name. '
                  'Make sure it is powered on and in range.';
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<PrinterProfile?> _pickProfile(String deviceName) =>
      showDialog<PrinterProfile>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text('What kind of printer is "$deviceName"?'),
          children: [
            for (final profile in _profiles)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(profile),
                child: Text(profile.name),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

  Future<void> _unpair() async {
    await ref.read(printerProvider.notifier).forget();
  }

  @override
  void dispose() {
    _scanResultsSub?.cancel();
    _scanStateSub?.cancel();
    BluetoothService.instance.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(printerProvider).valueOrNull;
    final height = MediaQuery.of(context).size.height * 0.72;

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Bluetooth printer',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (_scanning || _connecting)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Scan again',
                    onPressed: _checkPermissionsAndScan,
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (saved != null) ...[
                  ListTile(
                    leading: Icon(
                      Icons.print,
                      color: saved.connected ? Colors.green : Colors.grey,
                    ),
                    title: Text(saved.name),
                    subtitle: Text(
                      saved.connected ? 'Connected' : 'Saved (not connected)',
                    ),
                    trailing: TextButton(
                      onPressed: _unpair,
                      child: const Text('Unpair'),
                    ),
                  ),
                  const Divider(),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        if (_needsBluetoothOn)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: FilledButton.icon(
                              onPressed: _turnOnBluetooth,
                              icon: const Icon(Icons.bluetooth),
                              label: const Text('Turn on Bluetooth'),
                            ),
                          ),
                        if (_needsSettings)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: FilledButton.icon(
                              onPressed: BluetoothService.instance.openSettings,
                              icon: const Icon(Icons.settings),
                              label: const Text('Open settings'),
                            ),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'AVAILABLE DEVICES',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                if (_devices.isEmpty && !_scanning)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No devices found. Make sure the printer is on.',
                    ),
                  ),
                ..._devices.values.map((entry) {
                  final match = _matchProfile(entry.name);
                  return ListTile(
                    leading: const Icon(Icons.bluetooth),
                    title: Text(entry.name),
                    subtitle: Text(match?.name ?? entry.device.remoteId.str),
                    enabled: !_connecting,
                    onTap: () => _connect(entry.device, entry.name),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
