import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logger/logger.dart';
import 'package:printing/printing.dart';

import '../models/label_prefs.dart';
import '../services/label_prefs_service.dart';
import '../services/label_service.dart';
import '../services/system_print_service.dart';

final _log = Logger();

/// The **PDF-based** print methods for a single lot: the label PDF the website
/// itself produces (WeasyPrint, laid out with the user's `UserLabelPrefs`).
///
///  • **System printer** — straight into the OS print dialog, then out of the
///    way. The dialog is the confirmation; a preview in front of it is one
///    more tap to reach the same sheet.
///  • **PDF** — the preview, whose print/share actions are the point.
///
/// Bluetooth labels never come here. That path has no screen at all: the shell
/// prints them in the background with a progress message over whatever page
/// the user was on (`LabelPrintService`). If prefs resolve to Bluetooth after
/// this screen is already up — a stale cached method, since the shell checks
/// before pushing — the PDF is the harmless fallback.
class PrintLabelScreen extends ConsumerStatefulWidget {
  const PrintLabelScreen({required this.lotPk, this.prefs, super.key});

  final int lotPk;

  /// The caller's already-fetched prefs — the shell has them from deciding
  /// this isn't the Bluetooth path, and re-fetching them would delay the
  /// screen by a round trip for nothing. Null when this route was entered
  /// directly, in which case they're fetched here.
  final LabelPrefs? prefs;

  @override
  ConsumerState<PrintLabelScreen> createState() => _PrintLabelScreenState();
}

enum _Phase { loading, ready, error }

class _PrintLabelScreenState extends ConsumerState<PrintLabelScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  late Uint8List _pdf;

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
    final prefs = widget.prefs ?? await LabelPrefsService.instance.fetch();
    try {
      final pdf = _pdf = await LabelService.instance.fetchLabelPdf(
        widget.lotPk,
      );
      if (!mounted) {
        return;
      }
      if (prefs?.printMethod == PrintMethod.system) {
        await _printWithSystemDialog(pdf);
        return;
      }
      setState(() => _phase = _Phase.ready);
    } on DioException catch (e) {
      _fail(labelFetchErrorMessage(e));
    } on Object catch (e) {
      // Anything else (a malformed response, a renderer blowing up) would
      // otherwise leave the screen spinning forever with no way out.
      _log.w('Label load failed: $e');
      _fail('Could not load the label. Please try again.');
    }
  }

  /// Hands the PDF to the OS print dialog and leaves. Whether the user sent
  /// the job or dismissed the dialog, this screen has nothing left to show —
  /// dropping them back where they tapped print is the whole flow.
  Future<void> _printWithSystemDialog(Uint8List pdf) async {
    try {
      await SystemPrintService.instance.printPdf(
        pdf,
        jobName: 'label_${widget.lotPk}',
      );
    } on Object catch (e) {
      _log.w('System print dialog failed: $e');
      _fail(
        "Couldn't open the print dialog. Try again, or switch the print "
        'method on the Label printing page.',
      );
      return;
    }
    if (mounted) {
      context.pop();
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Print Label')),
    body: SafeArea(
      child: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        // PdfPreview owns the print + share actions (the OS dialog and the
        // share sheet), which is the entire PDF method.
        _Phase.ready => PdfPreview(
          build: (_) async => _pdf,
          canChangePageFormat: false,
          canChangeOrientation: false,
          canDebug: false,
          pdfFileName: 'label_${widget.lotPk}.pdf',
        ),
        _Phase.error => Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
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
                FilledButton(onPressed: _load, child: const Text('Try Again')),
              ],
            ),
          ),
        ),
      },
    ),
  );
}
