import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/printer_device_info.dart';
import '../models/printer_profile.dart';
import '../providers/printer_provider.dart';
import '../services/bluetooth_service.dart';
import '../services/printer_profile_service.dart';
import '../services/printer_report_service.dart';

/// The native "connect a Bluetooth printer" flow, shown as a modal bottom
/// sheet *over* the current page — the `/printing/` web page stays the one
/// place printing is configured, and its Bluetooth card opens this sheet via
/// the `printerConnect` JS handler (the print screen also opens it when no
/// printer is set up yet).
///
/// Flow: connect permission → (Android ≤11: location permission) → scan →
/// pick a device → resolve its profile → connect. Resolves when the sheet
/// closes; callers read the outcome from [printerProvider].
///
/// Resolving the profile is the interesting part, because it decides every
/// byte the app will send. In order: the advertised BLE name, then what the
/// printer reports about itself over GATT (which survives the user renaming
/// it), and only if both fail does it ask the user — showing what the printer
/// did say, and reporting it so a profile can be added for the next person.
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
  // Connected, but still asking the device what it is (see _connect).
  bool _identifying = false;
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
    // `candidates`, not `getProfiles`: the manual picker has to offer every
    // profile that automatic matching considers — including bundled seeds the
    // server's list is missing, like the raw ESC/POS fallback.
    final profiles = await PrinterProfileService.instance.candidates();
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
      _needsSettings = false;
      _devices.clear();
    });

    // The radio has to be on before anything else; otherwise reads and
    // connections fail with opaque errors. Offer to turn it on right here.
    if (!await BluetoothService.instance.isAdapterOn()) {
      if (!mounted) {
        return;
      }
      // "Unauthorized" isn't a radio the user can switch on — it's the OS
      // refusing this app Bluetooth (a declined iOS prompt, a revoked Android
      // one), so send them to settings instead of Quick Settings.
      final unauthorized = BluetoothService.instance.isAdapterUnauthorized;
      setState(() {
        _needsBluetoothOn = !unauthorized;
        _needsSettings = unauthorized;
        _error = unauthorized
            ? 'Bluetooth is off for this app. Open settings to allow it, then '
                  'come back and scan.'
            : 'Bluetooth is off. Turn it on to find your printer.';
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
      _identifying = false;
    });
    await BluetoothService.instance.stopScan();

    // The profile decides every byte the app will send, so it has to be right.
    // Three tries, cheapest first: the advertised BLE name, then what the
    // printer says it is over GATT, and only then the user.
    var profile = _matchProfile(name);
    var match = ProfileMatch.bleName;
    PrinterDeviceInfo? info;

    if (profile == null) {
      setState(() => _identifying = true);
      try {
        info = await BluetoothService.instance.identify(device, name: name);
      } on PrinterException catch (e) {
        // Couldn't even open the link — asking the user which printer this is
        // wouldn't help, since connecting is about to fail the same way.
        _failConnect(e.message);
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() => _identifying = false);
      final identified = await PrinterProfileService.instance.matchByDeviceInfo(
        info,
      );
      if (identified != null) {
        (profile, match) = identified;
      }
    }

    if (profile == null) {
      if (!mounted) {
        return;
      }
      profile = await _pickProfile(name, info);
      match = ProfileMatch.manual;
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
      unawaited(_report(info, name: name, profile: profile, match: match));
      Navigator.of(context).pop();
    }
  }

  void _failConnect(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _connecting = false;
      _identifying = false;
      _error = message;
    });
  }

  /// Tells the backend what this printer turned out to be. On the BLE-name
  /// fast path nothing has read the device yet, so read it now — the link is
  /// open and it's two GATT reads.
  Future<void> _report(
    PrinterDeviceInfo? info, {
    required String name,
    required PrinterProfile? profile,
    required ProfileMatch match,
  }) async {
    final reported =
        info ?? await BluetoothService.instance.readDeviceInfo(name: name);
    await PrinterReportService.instance.report(
      reported,
      profile: profile,
      match: match,
    );
  }

  /// Last resort: the printer's name matched nothing and it either wouldn't
  /// say what it is or said something we have no profile for. Show whatever it
  /// did report — that's the thing worth copying into a bug report, and it's
  /// how a profile gets added for it.
  Future<PrinterProfile?> _pickProfile(
    String deviceName,
    PrinterDeviceInfo? info,
  ) => showDialog<PrinterProfile>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('What kind of printer is "$deviceName"?'),
      children: [
        if (info != null && !info.isEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'It reports itself as:',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  info.summary,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _copyDetails(info),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy details'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
        ],
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

  Future<void> _copyDetails(PrinterDeviceInfo info) async {
    await Clipboard.setData(ClipboardData(text: info.summary));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Printer details copied.')));
    }
  }

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
    final saved = ref.watch(printerProvider).value;
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Bluetooth printer',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (_connecting)
                        Text(
                          _identifying
                              ? 'Asking the printer what it is…'
                              : 'Connecting…',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
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
