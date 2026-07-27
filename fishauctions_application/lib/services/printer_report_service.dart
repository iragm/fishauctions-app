import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

import '../models/printer_device_info.dart';
import '../models/printer_profile.dart';
import 'api_service.dart';
import 'printer_characterization.dart';
import 'printer_probe.dart';

final _log = Logger();

/// Reports what a just-paired printer says it is to
/// `POST /api/mobile/printers/observed/`, so the backend can build the list of
/// printers people actually own — which ones identify themselves usefully,
/// which profile ended up driving them, and which ones nobody has a profile
/// for yet.
///
/// That list is the point: a printer nobody planned for becomes supported by
/// adding a `ThermalPrinterProfile` admin row (with `model_patterns` matching
/// what its DIS reports), not by shipping an app release. Until then the user
/// still picks manually — this just means they're the last person who has to.
///
/// Fire-and-forget by design: pairing must never fail or wait because
/// telemetry didn't go through, and a deployment without the endpoint (404)
/// turns it off for the rest of the process.
class PrinterReportService {
  PrinterReportService._();
  static final PrinterReportService instance = PrinterReportService._();

  bool _unavailable = false;

  /// Test seam — lets a test reset the process-wide disable.
  void resetForTest() => _unavailable = false;

  /// [probeReplies] is what the printer answered to [PrinterProbe]'s queries
  /// (empty when it was identified without probing). It's the difference
  /// between a report saying "some printer called FSC-BT986" and one saying
  /// "answers TSPL `<ESC>!?` with 00, ignores ESC/POS and ZPL" — the latter is
  /// enough to write a working profile without owning the hardware.
  ///
  /// [gatt] is the device's full service/characteristic tree, which is where a
  /// profile's GATT ids come from and is otherwise visible only in a logcat
  /// buffer on the user's phone. [characterization], when the user completed
  /// the guided capture, carries the status byte each physical printer state
  /// produces — i.e. the one thing no amount of querying can discover on its
  /// own, and the input to a profile's `status_flags.values`.
  Future<void> report(
    PrinterDeviceInfo info, {
    required PrinterProfile? profile,
    required ProfileMatch match,
    Map<String, PrinterReply> probeReplies = const {},
    List<Map<String, dynamic>> gatt = const [],
    PrinterCharacterizationResult? characterization,
  }) async {
    if (_unavailable) {
      return;
    }
    try {
      await ApiService.instance.dio.post<Map<String, dynamic>>(
        'printers/observed/',
        data: {
          ...info.toJson(),
          'profile_slug': profile?.slug,
          'matched_by': match.wireName,
          if (probeReplies.isNotEmpty) ...{
            'probe_replies': {
              for (final e in probeReplies.entries)
                e.key: {'hex': e.value.hex, 'ascii': e.value.ascii},
            },
            'probed_language': PrinterProbe.languageFrom(probeReplies),
          },
          if (gatt.isNotEmpty) 'gatt': gatt,
          // Overwrites probe_replies/probed_language with the characterization
          // run's own, which is correct: they came from the same sweep, and it
          // also carries the per-state captures they belong with.
          if (characterization != null) ...characterization.toJson(),
        },
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _unavailable = true;
        _log.i('Printer reporting not available on this deployment.');
        return;
      }
      _log.w('Printer report failed: ${e.message}');
    }
  }
}
