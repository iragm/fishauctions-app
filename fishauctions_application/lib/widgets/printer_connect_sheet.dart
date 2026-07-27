import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/printer_device_info.dart';
import '../models/printer_profile.dart';
import '../providers/printer_provider.dart';
import '../services/bluetooth_service.dart';
import '../services/label_prefs_service.dart';
import '../services/label_raster.dart';
import '../services/printer_characterization.dart';
import '../services/printer_probe.dart';
import '../services/printer_profile_driver.dart';
import '../services/printer_profile_service.dart';
import '../services/printer_report_service.dart';
import '../services/printer_test_label.dart';
import 'printer_characterize_sheet.dart';

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

/// One row in the "available devices" list.
///
/// A BLE scan in an auction hall returns everything in the room — phones,
/// earbuds, a car — and Android's bonded list adds every device the phone has
/// ever paired with. So the list needs enough information to *rank* itself,
/// not just render: [named] separates a device the user can recognise from a
/// bare MAC address, and [bonded] flags the entries that came from the OS's
/// pairing list rather than from the air.
class _DeviceEntry {
  const _DeviceEntry({
    required this.device,
    required this.name,
    required this.named,
    required this.bonded,
  });

  final BluetoothDevice device;
  final String name;

  /// The device advertised a name; false means [name] is its MAC address.
  final bool named;

  /// Came from the OS's already-paired list. Worth saying out loud: on Android
  /// that list is mostly *classic* (BR/EDR) pairings, and a label printer
  /// paired in Settings lands there — where a BLE connect can only ever time
  /// out. Telling the user which entries those are beats explaining it in an
  /// error message 15 seconds later.
  final bool bonded;
}

class _PrinterConnectSheetState extends ConsumerState<PrinterConnectSheet> {
  // Discovered + known printers, keyed by BLE remote id (de-dups scan repeats).
  // `named` records whether the device actually advertised a name, because a
  // row showing a MAC address is a row the user cannot recognise; `bonded` is
  // the OS's already-paired list, which on Android includes classic pairings
  // this app can't print over (see [_DeviceEntry]).
  final Map<String, _DeviceEntry> _devices = {};
  List<PrinterProfile> _profiles = const [];
  bool _scanning = false;
  bool _connecting = false;
  // Connected, but still asking the device what it is (see _connect).
  bool _identifying = false;
  String? _error;
  // Non-error feedback (test print sent, etc).
  String? _notice;
  bool _testing = false;
  // When set, the error has a concrete fix the user can take from here.
  bool _needsBluetoothOn = false;
  bool _needsSettings = false;

  // What the last connect learned about the printer, kept so the guided
  // capture can report the same identity the pairing did rather than re-read
  // it (and so it works for a printer matched on its BLE name, where nothing
  // read the device at all).
  PrinterDeviceInfo? _lastInfo;
  ProfileMatch _lastMatch = ProfileMatch.bleName;

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
      _addDevice(d, d.platformName, bonded: true);
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

  void _addDevice(BluetoothDevice device, String name, {bool bonded = false}) {
    final id = device.remoteId.str;
    // A scan repeat can carry the name an earlier, nameless advertisement
    // lacked — keep the better of the two rather than the latest.
    final existing = _devices[id];
    if (existing != null && existing.named && name.isEmpty) {
      return;
    }
    _devices[id] = _DeviceEntry(
      device: device,
      name: name.isNotEmpty ? name : id,
      named: name.isNotEmpty,
      bonded: bonded || (existing?.bonded ?? false),
    );
  }

  /// The device list in the order worth showing it.
  ///
  /// Ranked, not filtered: filtering by name or service UUID would hide
  /// exactly the unknown printers this flow exists to onboard. So everything
  /// stays visible and the ones the user is most likely to want float up —
  /// recognised printers first, then anything with a name, then the bare MAC
  /// addresses that are almost never a printer. Ties keep discovery order, so
  /// the list doesn't reshuffle under the user's finger mid-scan.
  List<_DeviceEntry> get _sortedDevices {
    // Bucketed rather than sorted: concatenating preserves insertion order
    // within each rank for free (bonded first, then the order the scan found
    // them), where a comparator sort would need an explicit tiebreak to stop
    // the list reshuffling under the user's finger mid-scan.
    final recognised = <_DeviceEntry>[];
    final named = <_DeviceEntry>[];
    final unnamed = <_DeviceEntry>[];
    for (final entry in _devices.values) {
      if (_matchProfile(entry.name) != null) {
        recognised.add(entry);
      } else if (entry.named) {
        named.add(entry);
      } else {
        unnamed.add(entry);
      }
    }
    return [...recognised, ...named, ...unnamed];
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

  /// The human name of the profile driving the saved printer. Falls back to
  /// the raw slug — an unrecognized one is worth showing, not hiding, since it
  /// means the server dropped a profile the printer was paired with.
  String _profileName(String? slug) {
    for (final profile in _profiles) {
      if (profile.slug == slug) {
        return profile.name;
      }
    }
    return slug ?? '';
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
      } else {
        // Last automatic step before giving up and asking: the printer's DIS
        // is often its radio module (a Y486BT reports "Feasycom FSC-BT986"),
        // but its *print engine* will still answer a status query in whatever
        // language it speaks. One profile for that language is a safe match;
        // several is genuinely ambiguous and falls through to the user.
        final byLanguage = await PrinterProfileService.instance.matchByLanguage(
          PrinterProbe.languageFrom(BluetoothService.instance.lastProbeReplies),
        );
        if (byLanguage != null) {
          profile = byLanguage;
          match = ProfileMatch.probe;
        }
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

    // Non-null from here: every path above either resolved a profile or
    // returned.
    final resolved = profile;
    await ref
        .read(printerProvider.notifier)
        .connect(device, name: name, profile: resolved);
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
      // Remember how this printer was resolved: it decides whether the guided
      // capture is worth offering, and it is what the report says.
      _lastInfo = info;
      _lastMatch = match;
      unawaited(_report(info, name: name, profile: resolved, match: match));
      // Deliberately does *not* close the sheet on success. A connection only
      // proves the link is open, not that the profile drives this printer —
      // and the profile may well have been a guess the user just made in
      // _pickProfile. Staying here puts "Print test label" one tap away, at
      // the only moment the user is holding the printer and expecting to fuss
      // with it.
      setState(() {
        _notice = match == ProfileMatch.manual
            // Nothing recognised this printer, so the profile is the user's
            // own guess. Say so, and point at the two things that fix it:
            // proving the guess, and telling us enough to add a real profile.
            ? 'Connected using the "${resolved.name}" profile — we didn\'t '
                  'recognise this printer, so that was a guess. Print a test '
                  'label to check it, and tap "Improve support" to send us '
                  'what it is.'
            : 'Connected with the "${resolved.name}" profile. Print a test '
                  'label to confirm it works before you need it.';
      });
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
      probeReplies: BluetoothService.instance.lastProbeReplies,
    );
  }

  /// Last resort: the printer's name matched nothing and it either wouldn't
  /// say what it is or said something we have no profile for. Show whatever it
  /// did report — that's the thing worth copying into a bug report, and it's
  /// how a profile gets added for it.
  Future<PrinterProfile?> _pickProfile(
    String deviceName,
    PrinterDeviceInfo? info,
  ) {
    // Everything automatic has already failed, so lead with what we *did*
    // learn. A user who can't answer "what protocol is this?" can usually
    // answer "which of these is my printer", and the detected language at
    // least narrows the list to the ones that can work at all.
    final language = PrinterProbe.languageFrom(
      BluetoothService.instance.lastProbeReplies,
    );
    final likely = [
      for (final p in _profiles)
        if (language != null && p.inferredLanguage == language) p,
    ];
    final rest = [
      for (final p in _profiles)
        if (!likely.contains(p)) p,
    ];
    return showDialog<PrinterProfile>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Which printer is "$deviceName"?'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              likely.isEmpty
                  ? "This printer didn't identify itself. Pick the closest "
                        'match, then print a test label to check it — you can '
                        'change it if nothing comes out.'
                  : 'It answered as a $language printer. The likely matches '
                        'are listed first; print a test label to confirm.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ),
          for (final profile in [...likely, ...rest])
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(profile),
              child: Text(profile.name),
            ),
          const Divider(),
          if (info != null && !info.isEmpty)
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
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

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

  PrinterProfile? _profileBySlug(String? slug) {
    for (final profile in _profiles) {
      if (profile.slug == slug) {
        return profile;
      }
    }
    return null;
  }

  /// Opens the guided capture that turns this printer into a support request.
  ///
  /// Makes sure the link is up and the probe sweep has run first: a printer
  /// matched on its BLE name was never asked anything, and the capture's whole
  /// value is the *comparison* between a known-good reading and the ones the
  /// user induces, which needs to be in the same language.
  Future<void> _characterize() async {
    setState(() {
      _error = null;
      _notice = null;
    });
    try {
      final notifier = ref.read(printerProvider.notifier);
      final printer = await notifier.ensureConnected();
      if (BluetoothService.instance.lastProbeReplies.isEmpty) {
        await BluetoothService.instance.probe();
      }
      final info =
          _lastInfo ??
          await BluetoothService.instance.readDeviceInfo(name: printer.name);
      if (!mounted) {
        return;
      }
      await PrinterCharacterizeSheet.show(
        context,
        info: info,
        profile: _profileBySlug(printer.profileSlug),
        match: _lastMatch,
      );
    } on PrinterException catch (e) {
      _failTest(e.message);
    } on Object catch (e) {
      _failTest('Could not reach the printer ($e). Make sure it is on.');
    }
  }

  /// How tall a test label to print when the user's label size is unknown —
  /// enough to carry the text block and ruler on any printhead.
  static const _testLabelHeightMm = 40.0;

  /// Prints the diagnostic label from [PrinterTestLabel].
  ///
  /// This is what makes picking a profile a *decision* rather than a guess.
  /// The profile determines every byte sent to the printer, and the app cannot
  /// tell a right guess from a wrong one — a printer driven by the wrong
  /// command language typically just sits there. Before this, the user found
  /// out at the counter with a queue behind them; now the answer is one tap
  /// and five seconds away, right where the profile was chosen.
  Future<void> _testPrint() async {
    setState(() {
      _testing = true;
      _error = null;
      _notice = null;
    });
    try {
      final notifier = ref.read(printerProvider.notifier);
      final printer = await notifier.ensureConnected();
      final profile = await PrinterProfileService.instance.bySlug(
        printer.profileSlug,
      );
      if (profile == null) {
        throw const PrinterException(
          "This printer's profile is no longer available. Unpair it and "
          'connect it again.',
        );
      }
      // Print at the user's real label size when we know it, so the test also
      // proves the size is right — not just that the printer responds.
      final size = (await LabelPrefsService.instance.fetch())?.sizeMm;
      final spec = size == null ? null : LabelRasterSpec.of(profile, size);
      final bitmap = PrinterTestLabel.build(
        profile,
        widthPx: spec?.widthPx ?? profile.printWidthPx,
        heightPx:
            spec?.heightPx ?? (_testLabelHeightMm * profile.dpi / 25.4).round(),
      );
      final warning = await PrinterProfileDriver(
        BluetoothService.instance,
        profile,
      ).printLabel(bitmap, labelWidthMm: size?.$1, labelHeightMm: size?.$2);
      if (!mounted) {
        return;
      }
      setState(() {
        _testing = false;
        _notice =
            warning ??
            'Test label sent. If it printed cleanly, this printer is set up '
                'correctly. If nothing came out, unpair and pick a different '
                'printer type.';
      });
    } on PrinterException catch (e) {
      _failTest(e.message);
    } on Object catch (e) {
      _failTest(
        'The test label failed to print ($e). Check that the printer is on, '
        'has labels loaded, and try again.',
      );
    }
  }

  void _failTest(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _testing = false;
      _error = message;
    });
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
                    // Name the profile: it's the setting most likely to be
                    // wrong, and the user can't otherwise see what was picked.
                    subtitle: Text(
                      '${saved.connected ? "Connected" : "Saved — reconnects "
                                "when you print"}'
                      '${saved.profileSlug == null ? "" : "\n"
                                "${_profileName(saved.profileSlug)}"}',
                    ),
                    isThreeLine: saved.profileSlug != null,
                  ),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _testing ? null : _unpair,
                        child: const Text('Unpair'),
                      ),
                      // Only when it would teach us something: a printer whose
                      // profile already decodes its status has no codes left
                      // to collect, and offering a diagnostics wizard to a
                      // user who is simply printing labels is noise.
                      if (PrinterCharacterization.isUseful(
                        _profileBySlug(saved.profileSlug),
                      ))
                        TextButton(
                          onPressed: _testing ? null : _characterize,
                          child: const Text('Improve support'),
                        ),
                      TextButton(
                        onPressed: _testing ? null : _testPrint,
                        child: Text(
                          _testing ? 'Printing…' : 'Print test label',
                        ),
                      ),
                      FilledButton(
                        onPressed: _testing
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                  const Divider(),
                ],
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          size: 18,
                          color: Colors.green,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_notice!)),
                      ],
                    ),
                  ),
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
                ..._sortedDevices.map((entry) {
                  final match = _matchProfile(entry.name);
                  return ListTile(
                    leading: Icon(
                      match != null ? Icons.print : Icons.bluetooth,
                      color: match != null
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    title: Text(entry.name),
                    subtitle: Text(
                      [
                        if (match != null) match.name,
                        if (entry.bonded) 'Already paired with this phone',
                        if (match == null && entry.named)
                          entry.device.remoteId.str,
                      ].join(' · '),
                    ),
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
