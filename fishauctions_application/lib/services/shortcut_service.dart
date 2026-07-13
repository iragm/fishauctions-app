import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

/// Home-screen quick actions (long-press the launcher icon) that deep-link
/// into web destinations inside the WebView shell.
///
/// The shortcut → path mapping lives here, in one place. Paths are
/// server-relative web pages, per the WebView-first architecture — the app
/// contributes only the OS entry point. "Lots in my last auction" points at
/// `/lots/my-last-auction/`, a backend redirect (BACKEND_SPEC.md Amendments):
/// only the server knows `userdata.last_auction_used`, so it resolves there.
///
/// Flow: the OS tap callback stores the requested path in [pending]. The
/// WebView shell consumes it in two places — its initial-URL logic (cold
/// start; also the post-sign-in mount, so a shortcut tapped while signed out
/// survives the login trap), or a [pending] listener when the shell is
/// already up. The value stays pending until a consumer actually takes it
/// via [consume], which clears it so exactly one navigation happens.
class ShortcutService {
  ShortcutService._();
  static final ShortcutService instance = ShortcutService._();

  static const _items = [
    (
      type: 'lots_last_auction',
      title: 'Lots in my last auction',
      path: '/lots/my-last-auction/',
    ),
    (type: 'selling', title: 'Selling', path: '/selling/'),
    (type: 'invoices', title: 'Invoices', path: '/invoices/'),
  ];

  /// Web path requested by the most recent shortcut tap, until consumed.
  final ValueNotifier<String?> pending = ValueNotifier(null);

  /// Registers the shortcuts and the tap handler with the OS. Called once at
  /// startup; failures are swallowed (shortcuts are polish — never worth
  /// blocking launch, e.g. on an OEM launcher without shortcut support).
  Future<void> init() async {
    const actions = QuickActions();
    try {
      // initialize must precede setShortcutItems: it registers the handler,
      // and on a cold start from a shortcut the OS-buffered tap is delivered
      // to it right after registration.
      await actions.initialize((type) {
        final path = pathForType(type);
        if (path != null) {
          pending.value = path;
        }
      });
      await actions.setShortcutItems([
        for (final item in _items)
          ShortcutItem(type: item.type, localizedTitle: item.title),
      ]);
    } on Object catch (e) {
      debugPrint('Quick actions unavailable: $e');
    }
  }

  /// The web path for a shortcut [type], or null for an unknown type (a
  /// launcher-pinned shortcut from an older build must not navigate anywhere
  /// surprising).
  static String? pathForType(String type) {
    for (final item in _items) {
      if (item.type == type) {
        return item.path;
      }
    }
    return null;
  }

  /// Takes the pending path and clears it, so exactly one consumer navigates.
  String? consume() {
    final path = pending.value;
    pending.value = null;
    return path;
  }
}
