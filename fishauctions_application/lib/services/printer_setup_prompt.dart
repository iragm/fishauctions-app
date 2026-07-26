import '../utils/secure_storage.dart';

const _keyPrompted = 'printer_setup_prompted';

/// Whether a print with no printer paired should walk the user to the
/// `/printing/` page — once, the first time it happens.
///
/// The first time someone taps print on the Bluetooth method with nothing
/// paired, "no printer is set up" is not news they can act on from where they
/// are: the printer is paired on the printing page, so take them there. Every
/// time after that they've seen the page and chose not to finish, so a nudge
/// with a way back is enough — a print button that keeps yanking the user off
/// the page they were on is worse than no printer.
///
/// Deliberately **device-local**, not a `UserLabelPrefs` flag: what it tracks
/// is whether *this phone* has been shown the pairing page, and a printer is
/// paired per device. The same account on a second phone gets its own first
/// run, which is the point.
class PrinterSetupPrompt {
  PrinterSetupPrompt._();
  static final PrinterSetupPrompt instance = PrinterSetupPrompt._();

  static const _storage = secureStorage;

  /// True exactly once per install: the caller should navigate to the printing
  /// page. Subsequent calls return false (offer it, don't force it).
  Future<bool> consumeFirstRun() async {
    if (await _storage.read(key: _keyPrompted) != null) {
      return false;
    }
    await _storage.write(key: _keyPrompted, value: '1');
    return true;
  }

  /// Puts the next no-printer print back to first-run behavior. Called when a
  /// printer is unpaired — the user is starting over, so the automatic trip to
  /// the printing page is useful again.
  Future<void> reset() => _storage.delete(key: _keyPrompted);
}
