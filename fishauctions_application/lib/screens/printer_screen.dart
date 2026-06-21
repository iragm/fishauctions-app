import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/printer_provider.dart';
import '../services/bluetooth_service.dart';

class PrinterScreen extends ConsumerStatefulWidget {
  const PrinterScreen({super.key});

  @override
  ConsumerState<PrinterScreen> createState() => _PrinterScreenState();
}

class _PrinterScreenState extends ConsumerState<PrinterScreen> {
  // Discovered + known printers, keyed by BLE remote id (de-dups scan repeats).
  final Map<String, ({BluetoothDevice device, String name})> _devices = {};
  bool _scanning = false;
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
    _checkPermissionsAndScan();
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

    // Discovering *new* printers needs scan/location permission. Without it we
    // still show the known list above rather than dead-ending.
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

  Future<void> _disconnect() async {
    await ref.read(printerProvider.notifier).disconnect();
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

  Future<void> _openSettings() async {
    await BluetoothService.instance.openSettings();
  }

  Future<void> _reconnect() async {
    setState(() => _error = null);
    try {
      await ref.read(printerProvider.notifier).ensureConnected();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Reconnected')));
    } on PrinterException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _error = e.message);
    } on Object {
      if (!mounted) {
        return;
      }
      setState(
        () => _error =
            'Could not reconnect. Make sure the printer is '
            'on and in range.',
      );
    }
  }

  Future<void> _connect(BluetoothDevice device, String name) async {
    setState(() => _error = null);
    await BluetoothService.instance.stopScan();
    await ref.read(printerProvider.notifier).connect(device, name: name);
    if (!mounted) {
      return;
    }

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connected to $name')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _forget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget printer?'),
        content: const Text(
          'The saved printer will be removed. You can re-pair it any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(printerProvider.notifier).forget();
    }
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
    final printerState = ref.watch(printerProvider);
    final savedPrinter = printerState.valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth Printer'),
        actions: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.all(16),
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
      body: ListView(
        children: [
          if (savedPrinter != null) ...[
            const _SectionHeader('Connected printer'),
            ListTile(
              leading: Icon(
                Icons.print,
                color: savedPrinter.connected ? Colors.green : Colors.grey,
              ),
              title: Text(savedPrinter.name),
              subtitle: Text(
                savedPrinter.connected ? 'Connected' : 'Saved (not connected)',
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'connect':
                      _reconnect();
                    case 'disconnect':
                      _disconnect();
                    case 'forget':
                      _forget();
                  }
                },
                itemBuilder: (_) => [
                  if (savedPrinter.connected)
                    const PopupMenuItem(
                      value: 'disconnect',
                      child: Text('Disconnect'),
                    )
                  else
                    const PopupMenuItem(
                      value: 'connect',
                      child: Text('Connect'),
                    ),
                  const PopupMenuItem(value: 'forget', child: Text('Forget')),
                ],
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
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('Open settings'),
                      ),
                    ),
                ],
              ),
            ),
          const _SectionHeader('Available devices'),
          if (_devices.isEmpty && !_scanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No devices found. Make sure the printer is on.'),
            ),
          ..._devices.values.map(
            (entry) => ListTile(
              leading: const Icon(Icons.bluetooth),
              title: Text(entry.name),
              subtitle: Text(entry.device.remoteId.str),
              onTap: () => _connect(entry.device, entry.name),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
