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
    this.retryLots,
  });

  final LabelPrintStatus status;

  /// The failure to show ([LabelPrintStatus.failed]), or a soft warning from an
  /// otherwise-good job (the printer never acked, say). Null when there is
  /// nothing worth interrupting the user for — the normal case, since a
  /// successful print needs no confirmation.
  final String? message;

  /// Labels that came out, and how many were asked for.
  final int printed;
  final int total;

  /// The failure can only be fixed in the OS settings (a permanently denied
  /// permission), so a "Retry" action would be a dead end.
  final bool fixInSettings;

  /// What a Retry should send, in the order the job asked for them: the
  /// labels that didn't come out and the ones never reached — without the
  /// lots the server refused, which it would only refuse again. Null when the
  /// job stopped before sending anything, so everything is the retry.
  final List<int>? retryLots;
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
/// with one connect; [cancel] stops it after the label in flight. The images
/// come from `labels/batch/` a chunk ahead of the printer ([_LabelSource]),
/// and what came out is judged from the printer's own status
/// ([PrintRunLedger]) rather than from the bytes having been written.
class LabelPrintService {
  LabelPrintService._();
  static final LabelPrintService instance = LabelPrintService._();

  /// How long to let the printer finish the last label before reading the
  /// status that decides whether it came out. A label takes a second or two
  /// at thermal speeds; past this, a printer still reporting "printing" is
  /// treated as one that can't say.
  static const _settleLimit = Duration(seconds: 4);
  static const _settlePoll = Duration(milliseconds: 250);

  /// Live progress, or null when nothing is printing.
  final ValueNotifier<LabelPrintProgress?> progress = ValueNotifier(null);

  bool _busy = false;
  bool _cancelled = false;
  bool _reportAvailable = true;

  /// The [BluetoothService.linkId] of a connection whose printer never
  /// answered a status query. See [_status].
  int? _silentLink;

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
    final source = _LabelSource(
      lotPks,
      widthPx: raster?.widthPx,
      heightPx: raster?.heightPx,
      dpi: raster == null ? null : profile.dpi,
    );
    final ledger = PrintRunLedger();
    final timing = _RunTiming();

    // A label wider than the printhead prints cropped, and nothing about the
    // print itself will say so — this used to be a warning on the preview
    // screen, which no longer exists. It outranks any driver warning: it
    // explains a label the user is holding and can see is wrong.
    var warning = raster != null && raster.exceedsHead
        ? 'Your label size is wider than this printer can print, so labels '
              'come out cut off. Pick a label size that fits on the Label '
              'printing page.'
        : null;
    String? failure;
    var fixInSettings = false;
    int? lotInHand;
    try {
      while (!_cancelled) {
        progress.value = LabelPrintProgress(
          done: ledger.attempted + source.skipped.length,
          total: lotPks.length,
        );
        final label = await timing.fetching(source.next);
        if (label == null) {
          break;
        }
        lotInHand = label.lot;
        // The pre-flight doubles as the verdict on what went before: a printer
        // that is jammed now was fine when the previous label started.
        final blocker = ledger.observe(
          await timing.querying(() => _status(driver)),
        );
        if (blocker != null) {
          failure = blocker.message;
          break;
        }
        // Resize to the raster we asked for, not to the full printhead width —
        // a label narrower than the head should print narrow, not be stretched
        // across every element.
        final bitmap = LabelRaster.fromPng(
          label.png,
          targetWidth: raster?.widthPx ?? profile.printWidthPx,
        );
        ledger.sending(label.lot);
        // Keep the first soft problem: on a batch, twenty copies of "the
        // printer didn't confirm the print finished" is one piece of news.
        final soft = await timing.sending(
          () => driver.printLabel(
            bitmap,
            labelWidthMm: size?.$1,
            labelHeightMm: size?.$2,
            preflight: false,
          ),
        );
        warning ??= soft;
        ledger.sent();
      }
    } on Object catch (e) {
      ledger.stopped();
      failure = _failureMessage(e, lotInHand);
      fixInSettings = e is PrinterException && e.fixInSettings;
    }

    // The last label has left the phone and nothing has said it came out.
    // Letting the printer finish and asking once more is the only way to
    // catch a jam on the final label of a run — which is exactly the jam that
    // used to be reported as a successful print.
    if (ledger.hasUnconfirmed) {
      final blocker = ledger.observe(
        BluetoothService.instance.isConnected
            ? await timing.querying(() => _settle(driver))
            : null,
      );
      failure ??= blocker?.message;
      ledger.close();
    }

    final failed = ledger.failed;
    if (failure != null && failed.isNotEmpty) {
      final lost = failed.length == 1
          ? "The last label didn't come out."
          : "The last ${failed.length} labels didn't come out.";
      failure = '$failure $lost';
    }
    progress.value = LabelPrintProgress(
      done: ledger.attempted + source.skipped.length,
      total: lotPks.length,
    );
    unawaited(
      reportPrinted(
        ledger.printed,
        failed: failed,
        conditions: ledger.conditions,
        message: failure,
      ),
    );
    _log.i(
      'Label run: ${ledger.printed.length} printed, ${failed.length} failed, '
      '${source.skipped.length} skipped of ${lotPks.length} in $timing',
    );

    if (failure != null) {
      final skipped = source.skippedLots;
      return LabelPrintResult(
        LabelPrintStatus.failed,
        printed: ledger.printed.length,
        total: lotPks.length,
        message: failure,
        fixInSettings: fixInSettings,
        retryLots: [
          for (final lot in lotPks)
            if (failed.contains(lot) ||
                (!ledger.wasAttempted(lot) && !skipped.contains(lot)))
              lot,
        ],
      );
    }
    return LabelPrintResult(
      LabelPrintStatus.sent,
      printed: ledger.printed.length,
      total: lotPks.length,
      message: warning ?? _skippedNote(source.skipped),
    );
  }

  /// The printer's status, or null when it can't say.
  ///
  /// A printer that doesn't answer costs the whole query timeout, and this is
  /// asked before every label — so one silence means stop asking for the rest
  /// of this connection, rather than making every label wait five seconds for
  /// an answer that isn't coming. A reconnect ([BluetoothService.linkId])
  /// gives it another chance.
  Future<ProfilePrinterStatus?> _status(PrinterProfileDriver driver) async {
    final link = BluetoothService.instance.linkId;
    if (!driver.canReadStatus || _silentLink == link) {
      return null;
    }
    try {
      final status = await driver.queryStatus();
      if (status == null) {
        _silentLink = link;
        _log.w(
          "Printer didn't answer its status query; not asking again on this "
          'connection',
        );
      }
      return status;
    } on Object catch (e) {
      // The link dropped under the query. The next write says so properly.
      _log.w('Printer status query failed: $e');
      return null;
    }
  }

  /// [_status] once the printer has stopped printing, or null if it can't say
  /// or is still going at [_settleLimit].
  Future<ProfilePrinterStatus?> _settle(PrinterProfileDriver driver) async {
    final deadline = DateTime.now().add(_settleLimit);
    while (true) {
      final status = await _status(driver);
      if (status == null || !status.printing) {
        return status;
      }
      if (DateTime.now().isAfter(deadline)) {
        return null;
      }
      await Future<void>.delayed(_settlePoll);
    }
  }

  String? _skippedNote(List<({int lot, String detail})> skipped) =>
      switch (skipped.length) {
        0 => null,
        1 => "One label wasn't printed: ${skipped.first.detail}",
        final n => "$n labels weren't printed: ${skipped.first.detail}",
      };

  String _failureMessage(Object error, int? lotPk) {
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

  /// Tells the backend what came out of the printer and what didn't, so the
  /// website's unprinted-label flows behave the same whether a label came off
  /// a thermal printer or the PDF views (which set `label_printed` as they
  /// render). [failed] lots go back to unprinted and are flagged for
  /// reprinting, so "print unprinted labels" after clearing a jam prints
  /// exactly what's missing; [conditions] and [message] ride along only with
  /// a failure, as the server's log of why.
  ///
  /// Fire-and-forget, and self-disabling: a 404 (a deployment without the
  /// endpoint — BACKEND_SPEC.md Part W) turns it off for the process. Worst
  /// case the web keeps offering to print labels that are already on the box,
  /// which is exactly today's behavior. A deployment that predates `failed`
  /// ignores it (DRF drops undeclared keys), which is the old behavior too.
  Future<void> reportPrinted(
    List<int> printed, {
    List<int> failed = const [],
    Set<String> conditions = const {},
    String? message,
  }) async {
    if ((printed.isEmpty && failed.isEmpty) || !_reportAvailable) {
      return;
    }
    try {
      await ApiService.instance.dio.post<void>(
        'labels/printed/',
        data: {
          'lots': printed,
          if (failed.isNotEmpty) ...{
            'failed': failed,
            'conditions': [
              for (final condition in conditions)
                if (ProfilePrinterStatus.reportable.contains(condition))
                  condition,
            ],
            if (message != null)
              'message': message.length > 1000
                  ? message.substring(0, 1000)
                  : message,
          },
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _reportAvailable = false;
        debugPrint(
          'labels/printed/ missing — native prints will keep showing as '
          'unprinted on the website.',
        );
      }
    }
  }
}

/// What a print run can honestly say came out of the printer.
///
/// No printer here acknowledges a label as printed — TSPL has no completion
/// ack at all — and the bytes having been written says nothing about the
/// paper. What a printer with a status program *can* say is its state:
/// jammed, cover open, out of labels, busy, fine. So a label counts as printed
/// once a later read finds the printer idle and clear, and a read that finds
/// it blocked fails everything sent since the last clean one: those are the
/// labels that were in the printer when it stopped. Failing one that did make
/// it costs a duplicate label; the opposite costs a missing one and a guess
/// about where the run stopped.
///
/// A printer that can't be asked teaches nothing, and whatever it was sent is
/// reported printed at [close] — what the app always said, and all it can.
class PrintRunLedger {
  /// Lots confirmed out of the printer (or that nothing contradicted).
  final List<int> printed = [];

  /// Lots that were sent and didn't come out.
  final List<int> failed = [];

  /// What the printer said was wrong when it stopped.
  final Set<String> conditions = {};

  final List<int> _unconfirmed = [];
  final Set<int> _attempted = {};
  int? _inFlight;

  int get attempted => _attempted.length;

  bool wasAttempted(int lot) => _attempted.contains(lot);

  bool get hasUnconfirmed => _unconfirmed.isNotEmpty;

  /// [lot]'s bytes are about to go out.
  void sending(int lot) {
    _inFlight = lot;
    _attempted.add(lot);
  }

  /// …and all of them did.
  void sent() {
    final lot = _inFlight;
    _inFlight = null;
    if (lot != null) {
      _unconfirmed.add(lot);
    }
  }

  /// The run stopped on an error. A label cut off mid-send didn't come out
  /// whole (TSPL prints nothing without its trailing `PRINT`); one never
  /// started simply wasn't printed, and isn't a failure.
  void stopped() {
    final lot = _inFlight;
    _inFlight = null;
    if (lot != null) {
      failed.add(lot);
    }
  }

  /// A status read, null when the printer can't say. Returns what's stopping
  /// the printer, if anything, after booking its verdict on what went before.
  PrinterException? observe(ProfilePrinterStatus? status) {
    if (status == null) {
      return null;
    }
    final blocker = status.blocker;
    if (blocker != null) {
      failed.addAll(_unconfirmed);
      _unconfirmed.clear();
      conditions.addAll(status.reportableConditions);
      return blocker;
    }
    // Still printing: whatever is unconfirmed may be the label in the printer
    // right now, so it stays unconfirmed until a read finds the printer idle.
    if (!status.printing) {
      printed.addAll(_unconfirmed);
      _unconfirmed.clear();
    }
    return null;
  }

  /// Nothing more will be learned: what's unconfirmed went out and nothing
  /// said otherwise.
  void close() {
    printed.addAll(_unconfirmed);
    _unconfirmed.clear();
  }
}

/// One answer from [_LabelSource]: labels to print, lots refused, and lots to
/// ask for again.
@immutable
class LabelChunk {
  const LabelChunk({
    required this.labels,
    this.skipped = const [],
    this.unrendered = const [],
  });

  /// Reads a batch answer against the [window] it answered. Labels come out
  /// in the window's order, and the *window* — not the server's `remaining` —
  /// decides what is asked for again, so no answer can lose a lot or print one
  /// twice. An answer that neither renders nor refuses anything is rejected:
  /// asking again would loop forever.
  factory LabelChunk.fromBatch(List<int> window, LabelBatch batch) {
    final pngs = {for (final label in batch.labels) label.lot: label.png};
    final skipped = [
      for (final entry in batch.skipped)
        if (window.contains(entry.lot) && !pngs.containsKey(entry.lot)) entry,
    ];
    final refused = {for (final entry in skipped) entry.lot};
    final labels = [
      for (final lot in window)
        if (pngs[lot] case final png?) (lot: lot, png: png),
    ];
    if (labels.isEmpty && skipped.isEmpty) {
      throw const FormatException('labels/batch/ made no progress');
    }
    return LabelChunk(
      labels: labels,
      skipped: skipped,
      unrendered: [
        for (final lot in window)
          if (!pngs.containsKey(lot) && !refused.contains(lot)) lot,
      ],
    );
  }

  final List<({int lot, Uint8List png})> labels;
  final List<({int lot, String detail})> skipped;
  final List<int> unrendered;
}

/// Where a run's label images come from, in print order.
///
/// More than one label goes through `labels/batch/`, and the next chunk is
/// requested the moment the current one arrives, so the network works while
/// the printer does. A single label — a reprint — is one `labels/<pk>/` GET,
/// which is what that endpoint is still for. A deployment without the batch
/// endpoint, or an answer this build can't read, falls back to one GET per
/// label for the rest of the process, still one label ahead.
class _LabelSource {
  _LabelSource(List<int> lotPks, {this.widthPx, this.heightPx, this.dpi})
    : _left = List.of(lotPks);

  /// Process-wide, like `labels/printed/`: a deployment without the endpoint
  /// won't grow one mid-session.
  static bool _batchAvailable = true;

  /// The server stops at 25 labels a request; offering it more than a few
  /// chunks' worth only makes the request bigger.
  static const _window = 100;

  final int? widthPx;
  final int? heightPx;
  final int? dpi;
  final List<int> _left;
  final _ready = <({int lot, Uint8List png})>[];
  final skipped = <({int lot, String detail})>[];
  Future<LabelChunk>? _next;

  Set<int> get skippedLots => {for (final entry in skipped) entry.lot};

  /// The next label to print, or null when the run is out of labels.
  Future<({int lot, Uint8List png})?> next() async {
    while (_ready.isEmpty) {
      final pending = _next ?? _request();
      _next = null;
      if (pending == null) {
        return null;
      }
      final chunk = await pending;
      _ready.addAll(chunk.labels);
      skipped.addAll(chunk.skipped);
      _left.insertAll(0, chunk.unrendered);
      _next = _request();
    }
    return _ready.removeAt(0);
  }

  /// Starts on the next chunk, or null when nothing is left. The error path
  /// is claimed here so a failure that lands while the printer is busy isn't
  /// reported as unhandled; [next] still gets it when it arrives there.
  Future<LabelChunk>? _request() {
    if (_left.isEmpty) {
      return null;
    }
    final window = _batchAvailable && _left.length > 1
        ? _left.take(_window).toList()
        : [_left.first];
    _left.removeRange(0, window.length);
    final future = _fetch(window);
    unawaited(future.then((_) {}, onError: (Object _) {}));
    return future;
  }

  Future<LabelChunk> _fetch(List<int> window) async {
    if (window.length > 1 && _batchAvailable) {
      try {
        final batch = await LabelService.instance.fetchLabelBatch(
          window,
          widthPx: widthPx,
          heightPx: heightPx,
          dpi: dpi,
        );
        return LabelChunk.fromBatch(window, batch);
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) {
          rethrow;
        }
        _batchAvailable = false;
        debugPrint('labels/batch/ missing — fetching labels one at a time.');
      } on FormatException catch (e) {
        _batchAvailable = false;
        _log.w(
          'labels/batch/ answered in a shape this build cannot read ($e); '
          'fetching labels one at a time.',
        );
      }
    }
    final lot = window.first;
    final png = await LabelService.instance.fetchLabelPng(
      lot,
      widthPx: widthPx,
      heightPx: heightPx,
      dpi: dpi,
    );
    return LabelChunk(
      labels: [(lot: lot, png: png)],
      unrendered: window.sublist(1),
    );
  }
}

/// Where a run's time went, for the log line at the end of it. "Printing is
/// slow" has three possible owners — the server, the Bluetooth link and the
/// printer's status replies — and without this they look identical.
class _RunTiming {
  final _total = Stopwatch()..start();
  final _fetch = Stopwatch();
  final _send = Stopwatch();
  final _status = Stopwatch();

  Future<T> fetching<T>(Future<T> Function() work) => _timed(_fetch, work);

  Future<T> sending<T>(Future<T> Function() work) => _timed(_send, work);

  Future<T> querying<T>(Future<T> Function() work) => _timed(_status, work);

  static Future<T> _timed<T>(Stopwatch watch, Future<T> Function() work) async {
    watch.start();
    try {
      return await work();
    } finally {
      watch.stop();
    }
  }

  static String _seconds(Stopwatch watch) =>
      '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';

  @override
  String toString() =>
      '${_seconds(_total)} (waiting on the server ${_seconds(_fetch)}, '
      'sending ${_seconds(_send)}, printer status ${_seconds(_status)})';
}
