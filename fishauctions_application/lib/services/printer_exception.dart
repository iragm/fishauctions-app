/// A printer failure whose [message] is safe to show the user as-is and, where
/// possible, names the next step. Callers should surface [message] rather than
/// a generic "printing failed".
///
/// It implements [Exception] deliberately: the BLE layer can throw plain
/// `Error`s (e.g. `StateError`) that `on Exception` catches would miss and
/// crash the app, so the printing stack translates failures into a
/// [PrinterException] to guarantee the UI a clean, catchable error.
class PrinterException implements Exception {
  const PrinterException(this.message, {this.fixInSettings = false});

  /// User-facing, already includes a next step.
  final String message;

  /// True when the only fix is in the OS settings (e.g. a permission the user
  /// permanently denied), so the UI can offer an "Open settings" button.
  final bool fixInSettings;

  @override
  String toString() => 'PrinterException: $message';
}
