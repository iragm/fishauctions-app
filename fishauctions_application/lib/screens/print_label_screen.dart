import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/printer_provider.dart';
import '../services/bluetooth_service.dart';
import '../services/d11s_driver.dart';
import '../services/label_raster.dart';
import '../services/label_service.dart';

/// Prints a single lot's label. This one screen backs every web "print" action
/// — self lots, single lots, and auction lot lists all deep-link to
/// `fishauctions://print/<lot_pk>`, which routes here.
///
/// Flow: fetch the label PNG from the backend → preview it → on Print,
/// reconnect the saved printer if needed → resize to the printer's width and
/// pack to 1-bit → drive the D11s protocol over Bluetooth.
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
  Uint8List? _png;

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
    try {
      final png = await LabelService.instance.fetchLabelPng(widget.lotPk);
      if (!mounted) {
        return;
      }
      setState(() {
        _png = png;
        _phase = _Phase.ready;
      });
    } on DioException catch (e) {
      _fail(_loadErrorFor(e));
    }
  }

  Future<void> _print() async {
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
      final bitmap = LabelRaster.fromPng(
        png,
        targetWidth: D11sDriver.printWidthPx,
      );
      await D11sDriver(BluetoothService.instance).printLabel(bitmap);
      if (!mounted) {
        return;
      }
      setState(() => _phase = _Phase.success);
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

  /// Maps a failed label fetch to a clear message. The error body is raw PNG-
  /// or JSON-bytes (we request bytes), so we key off the status code.
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Print Label')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (_phase) {
          _Phase.loading => const Center(child: CircularProgressIndicator()),
          _Phase.ready => _LabelPreview(png: _png!, onPrint: _print),
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
              const Icon(Icons.check_circle, size: 80, color: Colors.green),
              const SizedBox(height: 16),
              const Text('Label sent.'),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => context.pop(),
                child: const Text('Done'),
              ),
              TextButton(onPressed: _print, child: const Text('Print again')),
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
                onPressed: () async {
                  await context.push('/settings/printer');
                  if (mounted) {
                    setState(() => _phase = _Phase.ready);
                  }
                },
                child: const Text('Set up printer'),
              ),
            ],
          ),
          _Phase.error => _Centered(
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
                onPressed: _png == null ? _load : _print,
                child: const Text('Try Again'),
              ),
            ],
          ),
        },
      ),
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
          // The label as the printer will render it — true WYSIWYG.
          child: Image.memory(png, fit: BoxFit.contain),
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
