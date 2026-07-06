import 'dart:typed_data';

import 'package:printing/printing.dart';

/// Hands a PDF to the OS print path (Android print framework / AirPrint) —
/// the "System printer" print method. The OS dialog owns printer selection,
/// paper size, and copies; we just supply the bytes.
class SystemPrintService {
  SystemPrintService._();
  static final SystemPrintService instance = SystemPrintService._();

  /// Opens the system print dialog for [pdf]. Resolves true when the user
  /// sent the job, false when they dismissed the dialog.
  Future<bool> printPdf(Uint8List pdf, {String jobName = 'label'}) =>
      Printing.layoutPdf(onLayout: (_) async => pdf, name: jobName);
}
