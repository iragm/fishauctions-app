import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../models/label_prefs.dart';
import '../providers/printer_provider.dart';
import 'api_service.dart';
import 'bluetooth_service.dart';
import 'label_prefs_service.dart';
import 'label_raster.dart';
import 'label_service.dart';
import 'printer_profile_driver.dart';
import 'printer_profile_service.dart';

final _log = Logger();

/// The lot pks a `fishauctions://print/…` deep link asks for, in the order the
/// page listed them and without duplicates.
///
///  * `fishauctions://print/<pk>` — one lot (the per-lot print button).
///  * `fishauctions://print/?lots=12,13,14` — a batch, emitted by the bulk
///    label buttons when the user's print method is Bluetooth (a thermal
///    printer can't be fed the PDF sheet those buttons otherwise produce).
///
/// Repeated `?lots=` params are accepted too, so a template that builds the
/// query with a loop rather than a `join` still works. Junk segments are
/// dropped rather than failing the whole link — a malformed link that prints
/// the lots it *could* parse beats one that silently does nothing.
List<int> lotPksFromPrintLink(Uri uri) {
  final pks = <int>[];
  void collect(String raw) {
    for (final part in raw.split(',')) {
      final pk = int.tryParse(part.trim());
      if (pk != null && pk > 0 && !pks.contains(pk)) {
        pks.add(pk);
      }
    }
  }

  uri.pathSegments.forEach(collect);
  (uri.queryParametersAll['lots'] ?? const <String>[]).forEach(collect);
  return pks;
}

/// How a print job ended.
enum LabelPrintStatus {
  /// Every label the job got through went out to the printer. A `printed`
  /// count below `total` means the user cancelled the rest.
  sent,

  /// No printer has been paired yet — the caller decides whether to walk the
  /// user to the printing page (see `PrinterSetupPrompt`).
  noPrinter,

  /// Stopped on an error; [LabelPrintResult.message] says what to do about it.
  failed,

  /// Another job is already running on the one BLE link. Nothing happened.
  busy,
}

@immutable
class LabelPrintResult {
  const LabelPrintResult(
    this.status, {
    this.message,
    this.printed = 0,
    this.total = 0,
    this.fixInSettings = false,
  });

  final LabelPrintStatus status;

  /// The failure to show ([LabelPrintStatus.failed]), or a soft warning from an
  /// otherwise-good job (the printer never acked, say). Null when there is
  /// nothing worth interrupting the user for — the normal case, since a
  /// successful print needs no confirmation.
  final String? message;

  /// Labels actually sent, and how many were asked for.
  final int printed;
  final int total;

  /// The failure can only be fixed in the OS settings (a permanently denied
  /// permission), so a "Retry" action would be a dead end.
  final bool fixInSettings;
}

/// Progress of the running job, for a non-blocking "printing…" message.
@immutable
class LabelPrintProgress {
  const LabelPrintProgress({required this.done, required this.total});

  final int done;
  final int total;

  /// Counts the label currently going out, not the ones finished — the message
  /// is read while a label is printing, so "3 of 12" should be the one in the
  /// printer.
  String get message => total > 1
      ? 'Printing label ${(done + 1).clamp(1, total)} of $total…'
      : 'Printing label…';
}

/// Prints lot labels on a Bluetooth thermal printer, headlessly.
///
/// There is deliberately **no print screen** on this path: the user tapped
/// print, so the app connects, renders and sends, and the only thing that ever
/// reaches the screen is a non-blocking progress message — plus an error if
/// something actually went wrong. (The PDF/System methods still get
/// `PrintLabelScreen`, because there the preview *is* the deliverable.)
///
/// Labels go out one at a time over the single BLE link, so a batch is a loop
/// with one connect; [cancel] stops it after the label in flight.
class LabelPrintService {
  LabelPrintService._();
  static final LabelPrintService instance = LabelPrintService._();

  /// Live progress, or null when nothing is printing.
  final ValueNotifier<LabelPrintProgress?> progress = ValueNotifier(null);

  bool _busy = false;
  bool _cancelled = false;
  bool _markPrintedAvailable = true;

  bool get isBusy => _busy;

  /// Stops a batch after the label currently going out. Labels already sent
  /// stay sent — there is no un-printing a label.
  void cancel() {
    if (_busy) {
      _cancelled = true;
    }
  }

  /// Prints [lotPks] in order. [prefs] is the caller's already-fetched label
  /// prefs (the shell has them from deciding this is the Bluetooth path);
  /// omitted, they're fetched here.
  Future<LabelPrintResult> printLots(
    List<int> lotPks, {
    required WidgetRef ref,
    LabelPrefs? prefs,
  }) async {
    if (_busy) {
      return const LabelPrintResult(LabelPrintStatus.busy);
    }
    if (lotPks.isEmpty) {
      return const LabelPrintResult(LabelPrintStatus.sent);
    }
    _busy = true;
    _cancelled = false;
    progress.value = LabelPrintProgress(done: 0, total: lotPks.length);
    try {
      return await _run(lotPks, ref, prefs);
    } on Object catch (e) {
      // Nothing may escape: this is started fire-and-forget from a navigation
      // callback, so an unexpected throw (the shell unmounting mid-job takes
      // `ref` with it, say) would surface as an unhandled async error instead
      // of a message the user can act on.
      _log.w('Print job failed unexpectedly: $e');
      return LabelPrintResult(
        LabelPrintStatus.failed,
        total: lotPks.length,
        message: 'Printing failed. Check the printer and try again.',
      );
    } finally {
      _busy = false;
      _cancelled = false;
      progress.value = null;
    }
  }

  Future<LabelPrintResult> _run(
    List<int> lotPks,
    WidgetRef ref,
    LabelPrefs? prefs,
  ) async {
    // Awaited, not read as a snapshot: `printerProvider` loads the saved
    // printer from secure storage, so the first read of a process is still
    // AsyncLoading and `.value` is null — indistinguishable from "no printer".
    final saved = await ref.read(printerProvider.future);
    if (saved == null) {
      return LabelPrintResult(LabelPrintStatus.noPrinter, total: lotPks.length);
    }
    final profile = await PrinterProfileService.instance.bySlug(
      saved.profileSlug,
    );
    if (profile == null) {
      return LabelPrintResult(
        LabelPrintStatus.failed,
        total: lotPks.length,
        message:
            "This printer's profile is no longer available. Unpair it on "
            'the Label printing page and connect it again.',
      );
    }

    try {
      await ref.read(printerProvider.notifier).ensureConnected();
    } on PrinterException catch (e) {
      return LabelPrintResult(
        LabelPrintStatus.failed,
        total: lotPks.length,
        message: e.message,
        fixInSettings: e.fixInSettings,
      );
    } on Object catch (e) {
      _log.w('Printer connect failed: $e');
      return LabelPrintResult(
        LabelPrintStatus.failed,
        total: lotPks.length,
        message:
            "Couldn't connect to the printer. Make sure it's on and in "
            'range, then try again.',
      );
    }

    final resolved = prefs ?? await LabelPrefsService.instance.fetch();
    final size = resolved?.sizeMm;
    // The label PNG at the printer's native raster, so barcodes and text
    // render crisp at the printhead's own dot pitch instead of being
    // downscaled on-device. Without a resolvable label size the server default
    // is fetched and resized to the printhead instead.
    final raster = size == null ? null : LabelRasterSpec.of(profile, size);
    final driver = PrinterProfileDriver(BluetoothService.instance, profile);

    var printed = 0;
    // A label wider than the printhead prints cropped, and nothing about the
    // print itself will say so — this used to be a warning on the preview
    // screen, which no longer exists. It outranks any driver warning: it
    // explains a label the user is holding and can see is wrong.
    var warning = raster != null && raster.exceedsHead
        ? 'Your label size is wider than this printer can print, so labels '
              'come out cut off. Pick a label size that fits on the Label '
              'printing page.'
        : null;
    for (final lotPk in lotPks) {
      if (_cancelled) {
        break;
      }
      progress.value = LabelPrintProgress(done: printed, total: lotPks.length);
      try {
        final png = await LabelService.instance.fetchLabelPng(
          lotPk,
          widthPx: raster?.widthPx,
          heightPx: raster?.heightPx,
          dpi: raster == null ? null : profile.dpi,
        );
        // Resize to the raster we asked for, not to the full printhead width —
        // a label narrower than the head should print narrow, not be stretched
        // across every element.
        final bitmap = LabelRaster.fromPng(
          png,
          targetWidth: raster?.widthPx ?? profile.printWidthPx,
        );
        // Keep the first soft problem: on a batch, twenty copies of "the
        // printer didn't confirm the print finished" is one piece of news.
        warning ??= await driver.printLabel(
          bitmap,
          labelWidthMm: size?.$1,
          labelHeightMm: size?.$2,
        );
        printed++;
      } on Object catch (e) {
        unawaited(markPrinted(lotPks.take(printed).toList()));
        return LabelPrintResult(
          LabelPrintStatus.failed,
          printed: printed,
          total: lotPks.length,
          message: _failureMessage(e, lotPk),
          fixInSettings: e is PrinterException && e.fixInSettings,
        );
      }
    }

    progress.value = LabelPrintProgress(done: printed, total: lotPks.length);
    unawaited(markPrinted(lotPks.take(printed).toList()));
    return LabelPrintResult(
      LabelPrintStatus.sent,
      printed: printed,
      total: lotPks.length,
      message: warning,
    );
  }

  String _failureMessage(Object error, int lotPk) {
    switch (error) {
      case DioException():
        return labelFetchErrorMessage(error);
      case PrinterException():
        return error.message;
      case FormatException():
        return 'The label image was invalid. Please try again.';
      default:
        _log.w('Label print failed for lot $lotPk: $error');
        return 'Printing failed. Check the printer and try again.';
    }
  }

  /// Tells the backend these labels have been printed, so the website's
  /// unprinted-label flows behave the same whether a label came off a thermal
  /// printer or the PDF views (which set `label_printed` as they render).
  ///
  /// Fire-and-forget, and self-disabling: a 404 (a deployment without the
  /// endpoint — BACKEND_SPEC.md Part W) turns it off for the process. Worst
  /// case the web keeps offering to print labels that are already on the box,
  /// which is exactly today's behavior.
  Future<void> markPrinted(List<int> lotPks) async {
    if (lotPks.isEmpty || !_markPrintedAvailable) {
      return;
    }
    try {
      await ApiService.instance.dio.post<void>(
        'labels/printed/',
        data: {'lots': lotPks},
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _markPrintedAvailable = false;
        debugPrint(
          'labels/printed/ missing — native prints will keep showing as '
          'unprinted on the website.',
        );
      }
    }
  }
}
