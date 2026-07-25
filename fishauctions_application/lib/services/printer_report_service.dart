import 'package:dio/dio.dart';
import 'package:logger/logger.dart';

import '../models/printer_device_info.dart';
import '../models/printer_profile.dart';
import 'api_service.dart';

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

  Future<void> report(
    PrinterDeviceInfo info, {
    required PrinterProfile? profile,
    required ProfileMatch match,
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
          'matched_by': match.name,
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
