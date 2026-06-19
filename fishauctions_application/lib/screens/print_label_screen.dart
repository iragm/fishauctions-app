import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/label_data.dart';
import '../providers/printer_provider.dart';
import '../services/bluetooth_service.dart';
import '../services/label_renderer.dart';
import '../services/label_service.dart';

/// Prints a single lot's label. This one screen backs every web "print" action
/// — self lots, single lots, and auction lot lists all deep-link to
/// `fishauctions://print/<lot_pk>`, which routes here.
///
/// Flow: fetch label data → show a preview → on Print, reconnect the saved
/// printer if needed → render to TSPL → send over Bluetooth.
class PrintLabelScreen extends ConsumerStatefulWidget {
  const PrintLabelScreen({required this.lotPk, super.key});

  final int lotPk;

  @override
  ConsumerState<PrintLabelScreen> createState() => _PrintLabelScreenState();
}

enum _Phase { loading, ready, printing, success, error, noPrinter }

class _PrintLabelScreenState extends ConsumerState<PrintLabelScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  LabelData? _label;

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
      final label = await LabelService.instance.fetchLabel(widget.lotPk);
      if (!mounted) {
        return;
      }
      setState(() {
        _label = label;
        _phase = _Phase.ready;
      });
    } on DioException catch (e) {
      _fail(_detail(e) ?? 'Could not load the label. Please try again.');
    } on FormatException catch (e) {
      _fail('Unexpected label data from the server: ${e.message}');
    }
  }

  Future<void> _print() async {
    final label = _label;
    if (label == null) {
      return;
    }
    if (ref.read(printerProvider).valueOrNull == null) {
      setState(() => _phase = _Phase.noPrinter);
      return;
    }

    setState(() {
      _phase = _Phase.printing;
      _error = null;
    });

    try {
      await ref.read(printerProvider.notifier).ensureConnected();
    } on Exception {
      _fail(
        'Could not connect to the printer. Make sure it is on and in '
        'range.',
      );
      return;
    }

    try {
      final bytes = LabelRenderer.renderTspl(label);
      await BluetoothService.instance.sendBytes(bytes);
      if (!mounted) {
        return;
      }
      setState(() => _phase = _Phase.success);
    } on Exception {
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

  String? _detail(DioException e) {
    final data = e.response?.data;
    return data is Map ? data['detail'] as String? : null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Print Label')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (_phase) {
          _Phase.loading => const Center(child: CircularProgressIndicator()),
          _Phase.ready => _LabelPreview(label: _label!, onPrint: _print),
          _Phase.printing => const _Centered(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Sending to printer…'),
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
                onPressed: _label == null ? _load : _print,
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
  const _LabelPreview({required this.label, required this.onPrint});

  final LabelData label;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.lotNumber.isEmpty ? 'Lot' : label.lotNumber,
                  style: theme.textTheme.headlineSmall,
                ),
                if (label.title.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(label.title, style: theme.textTheme.titleMedium),
                ],
                const SizedBox(height: 8),
                if (label.seller.isNotEmpty) Text('Seller: ${label.seller}'),
                if (label.auction.isNotEmpty) Text(label.auction),
                if (label.category.isNotEmpty) Text(label.category),
              ],
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
