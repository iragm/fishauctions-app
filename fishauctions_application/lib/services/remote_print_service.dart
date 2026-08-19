import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/label_prefs.dart';
import '../providers/printer_provider.dart';
import '../utils/device_identity.dart';
import 'api_service.dart';
import 'label_prefs_service.dart';
import 'label_print_service.dart';
import 'printer_profile_service.dart';

/// Printing from a computer to the phone's Bluetooth printer
/// (`BACKEND_SPEC.md` Part R).
///
/// **The phone cannot be summoned, and that is the design.** Android forbids
/// starting an Activity from the background, iOS silent push is best-effort and
/// dead against a force-quit app, and this app's BLE link lives in a UI-scoped
/// Riverpod provider a headless isolate doesn't have. So the contract is "the
/// app is open on the phone", and this service exists to *measure* that
/// honestly — a heartbeat the website reads — rather than to fire a push into
/// the void and let the user watch a spinner time out.
///
/// Two halves:
///
///  * [beat] tells the backend this phone is awake and whether it could print
///    right now. `print_ready` is a fact about the hardware — a printer paired
///    *and* a profile that can drive it — not about the account's
///    `print_method`, because a user can have Bluetooth selected on an account
///    whose phone has nothing paired, and the website must not offer a switch
///    with nothing behind it.
///  * [handlePushData] runs a job the backend pushed and reports what happened,
///    including the failure text verbatim: the person reading it is at the
///    computer, and the app's own vocabulary already distinguishes the cases
///    they need (nothing paired, couldn't connect, link lost mid-batch, label
///    wider than the printhead).
///
/// Self-disabling: a 404 from the heartbeat means a deployment without Part R,
/// so the whole feature switches off for the process. The website then never
/// sees a `print_ready` device, never offers the checkbox, and nothing changes
/// anywhere — which is exactly today's behaviour.
class RemotePrintService {
  RemotePrintService._();
  static final RemotePrintService instance = RemotePrintService._();

  /// Slack in the backend's reachability rule is one missed beat (Part R1
  /// defines reachable as a heartbeat inside six minutes), so beating every
  /// five leaves the window closed while the app is genuinely up.
  static const Duration heartbeatInterval = Duration(minutes: 5);

  /// At most one progress post per label, and never two inside this window —
  /// a fifty-label batch on a phone with bad hall wifi must spend its time
  /// printing, not retrying telemetry.
  static const Duration progressThrottle = Duration(seconds: 1);

  Timer? _timer;
  bool _available = true;
  bool _beating = false;
  DateTime? _lastProgressPost;

  /// The job currently printing, or null. Guards against the backend (or a
  /// re-delivered push — FCM delivers at least once) starting the same job
  /// twice on the one BLE link.
  String? _activeJob;

  @visibleForTesting
  String? get activeJob => _activeJob;

  /// True while this deployment looks like it has Part R.
  bool get isAvailable => _available;

  void start(WidgetRef ref) {
    _timer?.cancel();
    _timer = Timer.periodic(heartbeatInterval, (_) => unawaited(beat(ref)));
    unawaited(beat(ref));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void onAppResumed(WidgetRef ref) => unawaited(beat(ref));

  /// Reports presence and print-readiness. Never throws; silent on failure
  /// (the next beat is five minutes away and the website's own "last seen"
  /// line is what tells the user something is wrong).
  Future<void> beat(WidgetRef ref) async {
    if (!_available || _beating) {
      return;
    }
    _beating = true;
    try {
      final printer = await ref.read(printerProvider.future);
      // Paired is not the same as drivable: a printer saved by an older build,
      // or one whose profile the backend has since withdrawn, cannot print and
      // must not be advertised as ready.
      final slug = printer?.profileSlug;
      final profile = slug == null
          ? null
          : await PrinterProfileService.instance.bySlug(slug);
      final prefs = await LabelPrefsService.instance.fetch();
      await ApiService.instance.dio.post<void>(
        'devices/heartbeat/',
        data: {
          'device_uuid': await DeviceIdentity.uuid(),
          'print_ready': printer != null && profile != null,
          'printer_name': printer?.name ?? '',
          'print_method': (prefs?.printMethod ?? PrintMethod.pdf).name,
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _available = false;
        stop();
        debugPrint(
          'devices/heartbeat/ missing — printing from a computer to this '
          'phone is unavailable on this deployment.',
        );
      }
    } on Object catch (e) {
      debugPrint('Heartbeat failed: $e');
    } finally {
      _beating = false;
    }
  }

  /// Handles a data-only push. Returns true when [data] was a print job (and
  /// this service has taken responsibility for it), false for anything else —
  /// the caller then treats the message normally.
  ///
  /// [print] runs the job and is supplied by the shell so the phone still
  /// shows its usual progress snackbar: someone standing next to the printer
  /// should see why it started moving.
  Future<bool> handlePushData(
    Map<String, dynamic> data, {
    required Future<LabelPrintResult> Function(List<int> lotPks) print,
  }) async {
    if (data['type'] != 'print_labels') {
      return false;
    }
    final job = data['job']?.toString() ?? '';
    final lotPks = parseLots(data['lots']);
    if (job.isEmpty || lotPks.isEmpty) {
      debugPrint('Ignoring malformed print_labels push: $data');
      return true;
    }
    if (_activeJob != null) {
      // Already printing. Don't report failure for a re-delivery of the job in
      // flight — that would overwrite a good result with a bad one.
      if (_activeJob != job) {
        await _post(job, 'result', {
          'status': 'failed',
          'printed': 0,
          'total': lotPks.length,
          'message':
              'The phone is already printing something else. Try again in a '
              'moment.',
        });
      }
      return true;
    }
    _activeJob = job;
    void onProgress() {
      final progress = LabelPrintService.instance.progress.value;
      if (progress == null || progress.done == 0) {
        return;
      }
      final last = _lastProgressPost;
      if (last != null &&
          DateTime.now().difference(last) < progressThrottle &&
          progress.done < progress.total) {
        return;
      }
      _lastProgressPost = DateTime.now();
      unawaited(
        _post(job, 'progress', {
          'status': 'printing',
          'printed': progress.done,
          'total': progress.total,
        }),
      );
    }

    LabelPrintService.instance.progress.addListener(onProgress);
    try {
      await _post(job, 'progress', {
        'status': 'printing',
        'printed': 0,
        'total': lotPks.length,
      });
      final result = await print(lotPks);
      await _post(job, 'result', resultBody(result, lotPks.length));
    } on Object catch (e) {
      debugPrint('Remote print job $job failed unexpectedly: $e');
      await _post(job, 'result', {
        'status': 'failed',
        'printed': 0,
        'total': lotPks.length,
        'message':
            'Printing failed on the phone. Check the printer and try '
            'again.',
      });
    } finally {
      LabelPrintService.instance.progress.removeListener(onProgress);
      _lastProgressPost = null;
      _activeJob = null;
    }
    return true;
  }

  /// What the *computer* is told. The app's own failure text passes through
  /// unedited — it already names the cases the person at the computer has to
  /// act on, and a second copy of that vocabulary on the server would drift.
  /// Only the two outcomes the app normally answers with UI rather than words
  /// (nothing paired; already printing) get text written here, and they are
  /// written for the reader at the computer, not the one holding the phone.
  @visibleForTesting
  static Map<String, dynamic> resultBody(LabelPrintResult result, int total) =>
      switch (result.status) {
        LabelPrintStatus.sent => {
          'status': 'printed',
          'printed': result.printed,
          'total': result.total == 0 ? total : result.total,
          // A soft warning (the printer never acked, the label is wider than
          // the printhead) rides along on a success: the labels exist, and the
          // person at the computer is the one who can fix the setting.
          if (result.message != null) 'message': result.message,
        },
        LabelPrintStatus.noPrinter => {
          'status': 'failed',
          'printed': 0,
          'total': total,
          'message':
              'No label printer is paired with the phone. Open the app on it '
              'and connect one on the Label printing page.',
        },
        LabelPrintStatus.busy => {
          'status': 'failed',
          'printed': 0,
          'total': total,
          'message':
              'The phone is already printing something else. Try again in a '
              'moment.',
        },
        LabelPrintStatus.failed => {
          'status': 'failed',
          'printed': result.printed,
          'total': result.total == 0 ? total : result.total,
          'message':
              result.message ??
              'Printing failed on the phone. Check the printer and try again.',
        },
      };

  /// Best-effort, by design. A phone that can print but has momentarily lost
  /// the network must still finish the batch — the page's own 20-second rule
  /// calls that unreachable, which is a survivable wrong answer, while an
  /// abandoned batch is not.
  Future<void> _post(String job, String kind, Map<String, dynamic> body) async {
    try {
      await ApiService.instance.dio.post<void>(
        'printjobs/$job/$kind/',
        data: body,
      );
    } on Object catch (e) {
      debugPrint('Reporting $kind for print job $job failed: $e');
    }
  }

  /// FCM data values are always strings, so the lot list arrives as
  /// `"12,13,14"`. Junk entries are dropped rather than failing the job —
  /// printing the labels we *can* read beats printing none of them.
  @visibleForTesting
  static List<int> parseLots(Object? raw) {
    final pks = <int>[];
    for (final part in (raw?.toString() ?? '').split(',')) {
      final pk = int.tryParse(part.trim());
      if (pk != null && pk > 0 && !pks.contains(pk)) {
        pks.add(pk);
      }
    }
    return pks;
  }

  @visibleForTesting
  void reset() {
    stop();
    _available = true;
    _beating = false;
    _activeJob = null;
    _lastProgressPost = null;
  }
}
