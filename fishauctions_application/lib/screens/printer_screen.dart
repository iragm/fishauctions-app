import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/printer_provider.dart';
import '../services/bluetooth_service.dart';

class PrinterScreen extends ConsumerStatefulWidget {
  const PrinterScreen({super.key});

  @override
  ConsumerState<PrinterScreen> createState() => _PrinterScreenState();
}

class _PrinterScreenState extends ConsumerState<PrinterScreen> {
  List<BluetoothDevice> _discovered = [];
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndScan();
  }

  Future<void> _checkPermissionsAndScan() async {
    final canConnect = await BluetoothService.instance
        .requestConnectPermissions();
    if (!mounted) {
      return;
    }
    if (!canConnect) {
      setState(
        () => _error =
            'Bluetooth permission is required to use a '
            'printer.',
      );
      return;
    }
    await _scan();
  }

  Future<void> _scan() async {
    if (_scanning) {
      return;
    }
    setState(() {
      _scanning = true;
      _discovered = [];
      _error = null;
    });

    // Paired devices first — instant, and enough to reconnect a known printer.
    try {
      final paired = await BluetoothService.instance.getPairedDevices();
      if (!mounted) {
        return;
      }
      setState(() => _discovered = paired);
    } on Exception {
      if (!mounted) {
        return;
      }
      setState(
        () => _error =
            'Could not read paired devices. Is Bluetooth '
            'turned on?',
      );
    }

    // Discovering *new* (unpaired) devices needs scan/location permission.
    // Without it we still show the paired list above rather than dead-ending.
    final canScan = await BluetoothService.instance.requestScanPermissions();
    if (!mounted) {
      return;
    }
    if (!canScan) {
      setState(() {
        _scanning = false;
        _error =
            'Allow nearby-device scanning to find new printers. '
            'Paired printers above still work.';
      });
      return;
    }

    await BluetoothService.instance.cancelDiscovery();
    final stream = BluetoothService.instance.startDiscovery();
    await for (final result in stream) {
      if (!mounted) {
        break;
      }
      final device = result.device;
      if (!_discovered.any((d) => d.address == device.address)) {
        setState(() => _discovered = [..._discovered, device]);
      }
    }

    if (mounted) {
      setState(() => _scanning = false);
    }
  }

  Future<void> _disconnect() async {
    await ref.read(printerProvider.notifier).disconnect();
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
    } on Exception {
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

  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _error = null);
    await ref.read(printerProvider.notifier).connect(device);
    if (!mounted) {
      return;
    }

    final result = ref.read(printerProvider);
    if (result.hasError) {
      setState(() {
        _error =
            'Could not connect to ${device.name ?? device.address}. '
            'Make sure it is powered on and in range.';
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connected to ${device.name ?? device.address}'),
        ),
      );
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
    BluetoothService.instance.cancelDiscovery();
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
              onPressed: _scan,
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
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const _SectionHeader('Available devices'),
          if (_discovered.isEmpty && !_scanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No devices found. Make sure the printer is on.'),
            ),
          ..._discovered.map(
            (device) => ListTile(
              leading: const Icon(Icons.bluetooth),
              title: Text(device.name ?? 'Unknown device'),
              subtitle: Text(device.address),
              onTap: () => _connect(device),
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
