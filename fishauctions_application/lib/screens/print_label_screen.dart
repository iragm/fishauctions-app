import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../models/label_prefs.dart';
import '../models/printer_profile.dart';
import '../providers/printer_provider.dart';
import '../services/bluetooth_service.dart';
import '../services/label_prefs_service.dart';
import '../services/label_raster.dart';
import '../services/label_service.dart';
import '../services/printer_profile_driver.dart';
import '../services/printer_profile_service.dart';
import '../widgets/printer_connect_sheet.dart';

/// Prints a single lot's label. This one screen backs every web "print" action
/// — self lots, single lots, and auction lot lists all deep-link to
/// `fishauctions://print/<lot_pk>`, which routes here.
///
/// The user's print method (the `/printing/` page dropdown) picks the path:
///  • Bluetooth — fetch the label PNG at the printer's exact raster size,
///    preview it, and drive the printer's profile program over BLE.
///  • PDF / System printer — fetch the single-lot PDF (rendered with the
///    user's label prefs, identical to the website's print buttons) and show
///    it with print + share actions.
class PrintLabelScreen extends ConsumerStatefulWidget {
  const PrintLabelScreen({required this.lotPk, super.key});

  final int lotPk;

  @override
  ConsumerState<PrintLabelScreen> createState() => _PrintLabelScreenState();
}

enum _Phase { loading, ready, connecting, printing, success, error, noPrinter }

class _PrintLabelScreenState extends ConsumerState<PrintLabelScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  String? _warning;
  PrintMethod _method = PrintMethod.pdf;
  LabelPrefs? _prefs;
  Uint8List? _png;
  Uint8List? _pdf;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    _prefs = await LabelPrefsService.instance.fetch();
    _method = _prefs?.printMethod ?? PrintMethod.pdf;
    try {
      if (_method == PrintMethod.bluetooth) {
        _png = await _fetchPngForPrinter();
      } else {
        _pdf = await LabelService.instance.fetchLabelPdf(widget.lotPk);
      }
      if (!mounted) {
        return;
      }
      setState(() => _phase = _Phase.ready);
    } on DioException catch (e) {
      _fail(_loadErrorFor(e));
    }
  }

  /// The label PNG at the printer's native raster: the profile's printhead
  /// width, the height from the label prefs' aspect ratio, the profile's dpi —
  /// so barcodes render crisp instead of being downscaled on-device. Without a
  /// resolvable profile/size the server default is fetched and resized later.
  Future<Uint8List> _fetchPngForPrinter() async {
    final profile = await _profile();
    final size = _prefs?.sizeMm;
    if (profile == null || size == null) {
      return LabelService.instance.fetchLabelPng(widget.lotPk);
    }
    final (widthMm, heightMm) = size;
    return LabelService.instance.fetchLabelPng(
      widget.lotPk,
      widthPx: profile.printWidthPx,
      heightPx: (profile.printWidthPx * heightMm / widthMm).round(),
      dpi: profile.dpi,
    );
  }

  /// The saved printer's profile (pre-profile saves resolve to the D11s).
  Future<PrinterProfile?> _profile() async {
    final saved = ref.read(printerProvider).valueOrNull;
    if (saved == null) {
      return null;
    }
    return PrinterProfileService.instance.bySlug(saved.profileSlug);
  }

  Future<void> _printBluetooth() async {
    final png = _png;
    if (png == null) {
      return;
    }
    if (ref.read(printerProvider).valueOrNull == null) {
      setState(() => _phase = _Phase.noPrinter);
      return;
    }

    setState(() {
      _phase = _Phase.connecting;
      _error = null;
      _warning = null;
    });

    try {
      await ref.read(printerProvider.notifier).ensureConnected();
    } on PrinterException catch (e) {
      _fail(e.message);
      return;
    } on Object {
      _fail(
        "Couldn't connect to the printer. Make sure it's on and in range, "
        'then try again.',
      );
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() => _phase = _Phase.printing);

    try {
      final profile = await _profile();
      if (profile == null) {
        _fail(
          "This printer's profile is no longer available. Unpair it on the "
          'Label printing page and connect it again.',
        );
        return;
      }
      final bitmap = LabelRaster.fromPng(
        png,
        targetWidth: profile.printWidthPx,
      );
      final size = _prefs?.sizeMm;
      final warning = await PrinterProfileDriver(
        BluetoothService.instance,
        profile,
      ).printLabel(bitmap, labelWidthMm: size?.$1, labelHeightMm: size?.$2);
      if (!mounted) {
        return;
      }
      setState(() {
        _warning = warning;
        _phase = _Phase.success;
      });
    } on PrinterException catch (e) {
      _fail(e.message);
    } on FormatException {
      _fail('The label image was invalid. Please try loading it again.');
    } on Object {
      _fail('Printing failed. Check the printer and try again.');
    }
  }

  void _fail(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _error = message;
      _phase = _Phase.error;
    });
  }

  /// Maps a failed label fetch to a clear message. The error body is raw
  /// bytes (PNG/PDF requested), so we key off the status code.
  String _loadErrorFor(DioException e) {
    switch (e.response?.statusCode) {
      case 401:
      case 403:
        return "You don't have permission to print this lot's label.";
      case 404:
        return 'That lot could not be found. It may have been removed.';
      case 429:
        return 'Too many requests right now. Wait a moment and try again.';
      default:
        return 'Could not load the label. Please try again.';
    }
  }

  Future<void> _openConnectSheet() async {
    await PrinterConnectSheet.show(context);
    if (mounted) {
      setState(() => _phase = _Phase.ready);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Print Label')),
    body: SafeArea(
      child: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        // PDF / System printer: PdfPreview owns the print + share actions
        // (the OS dialog is the "system printer" path; sharing covers the
        // plain PDF method), so both non-Bluetooth methods share this view.
        _Phase.ready when _method != PrintMethod.bluetooth => PdfPreview(
          build: (_) async => _pdf!,
          canChangePageFormat: false,
          canChangeOrientation: false,
          canDebug: false,
          pdfFileName: 'label_${widget.lotPk}.pdf',
        ),
        _ => Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_phase) {
            _Phase.ready => _LabelPreview(png: _png!, onPrint: _printBluetooth),
            _Phase.connecting => const _Centered(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Connecting to printer…'),
              ],
            ),
            _Phase.printing => const _Centered(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Printing…'),
              ],
            ),
            _Phase.success => _Centered(
              children: [
                Icon(
                  _warning == null ? Icons.check_circle : Icons.info_outline,
                  size: 80,
                  color: _warning == null ? Colors.green : Colors.amber,
                ),
                const SizedBox(height: 16),
                Text(_warning ?? 'Label sent.', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => context.pop(),
                  child: const Text('Done'),
                ),
                TextButton(
                  onPressed: _printBluetooth,
                  child: const Text('Print again'),
                ),
              ],
            ),
            _Phase.noPrinter => _Centered(
              children: [
                const Icon(Icons.print_disabled, size: 64),
                const SizedBox(height: 16),
                const Text(
                  'No printer is set up yet.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _openConnectSheet,
                  child: const Text('Connect a printer'),
                ),
              ],
            ),
            _ => _Centered(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  _error ?? 'Something went wrong.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: (_png == null && _pdf == null)
                      ? _load
                      : _printBluetooth,
                  child: const Text('Try Again'),
                ),
              ],
            ),
          },
        ),
      },
    ),
  );
}

class _LabelPreview extends StatelessWidget {
  const _LabelPreview({required this.png, required this.onPrint});

  final Uint8List png;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(12),
          // The label at the printer's own raster — true WYSIWYG (upscaled
          // pixels and all; what you see is what the printhead gets).
          child: Image.memory(
            png,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.none,
          ),
        ),
      ),
      const Spacer(),
      FilledButton.icon(
        onPressed: onPrint,
        icon: const Icon(Icons.print),
        label: const Text('Print'),
      ),
    ],
  );
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: children,
    ),
  );
}
