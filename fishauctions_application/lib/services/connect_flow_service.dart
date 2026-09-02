import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../utils/connect_flows.dart';
import 'auth_service.dart';

/// How a connect round trip ended.
enum ConnectFlowOutcome {
  /// The authentication session closed on its own, because the page redirected
  /// to [ConnectFlowService.callbackScheme]. Only Square does this today.
  redirected,

  /// The session closed because the user tapped Done (or swiped it away).
  ///
  /// **This is a normal ending, not a failure, and must never be reported as
  /// one.** Mailchimp, PayPal and Google Calendar all *succeed* and then leave
  /// the user on one of our web pages with the sheet still open; the only way
  /// out is Done, which the platform reports to us as a user cancellation.
  /// From here a genuine mid-flow dismissal and a completed connection are
  /// indistinguishable, and both mean the same thing — the user came back and
  /// the server is now the only thing that knows whether it worked. So the
  /// caller re-reads the connection state (reload the page, re-warm the
  /// reader) and says nothing.
  dismissed,

  /// The session could not be started at all — an older platform, a build
  /// without the plugin. The caller falls back to a plain browser view.
  unavailable,
}

/// Opens [url] in the platform's authentication session, resolving with the
/// callback URL or throwing a [PlatformException] with code `CANCELED`.
typedef ConnectAuthenticator =
    Future<String> Function({
      required String url,
      required String callbackScheme,
    });

/// Mints a single-use web-session handoff URL landing on [next].
typedef ConnectHandoffMinter = Future<String?> Function({String? next});

Future<String> _authenticate({
  required String url,
  required String callbackScheme,
}) => FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: callbackScheme);

Future<String?> _mintHandoff({String? next}) =>
    AuthService.instance.createWebSessionHandoffUrl(next: next);

/// Runs a third-party connect flow (Square, PayPal, Mailchimp, Google
/// Calendar, Discord) in an authentication session that has a Django session
/// already established inside it.
///
/// See `utils/connect_flows.dart` for why that session has to be minted rather
/// than inherited. The rule this class exists to enforce is the timing one:
///
/// **Mint immediately before opening, and mint again on every retry.** The
/// handoff token is 256-bit, single-use (burned atomically) and lives 300
/// seconds. Minting one when a screen builds, or reusing one after a failed
/// attempt, replays a consumed or expired token — and the consume view answers
/// that by redirecting to `/login/`, which is the exact symptom this whole
/// change exists to remove. A token is therefore never stored, never cached
/// and never retried: it is created inside [run] and used in the next
/// statement.
class ConnectFlowService {
  ConnectFlowService._();

  static final ConnectFlowService instance = ConnectFlowService._();

  /// The scheme whose appearance dismisses the authentication session.
  ///
  /// Deliberately **not** `fishauctions://`. That scheme is intentionally
  /// unregistered with the OS — its links only ever appear inside our own
  /// pages and are caught by `shouldOverrideUrlLoading`, so registering it
  /// would let any app, or any web page in any browser, drive the shell's
  /// native flows. A separate scheme keeps that property while giving the auth
  /// session something to match on. On Android the plugin uses Chrome's Auth
  /// Tab, which returns its result to the launching activity rather than
  /// through an intent filter, so this is registered nowhere either.
  static const String callbackScheme = 'fishauctions-oauth';

  /// Test seam for the platform authentication session.
  @visibleForTesting
  ConnectAuthenticator authenticate = _authenticate;

  /// Test seam for the handoff mint.
  @visibleForTesting
  ConnectHandoffMinter mintHandoff = _mintHandoff;

  /// Opens [url] in an authentication session, bridging the app's session into
  /// it first when [url] is one of ours.
  ///
  /// Never throws, and never signs anybody out: a handoff that could not be
  /// minted (offline, endpoint missing, a briefly stale access token) falls
  /// through to the bare URL, which is no worse than the behaviour before this
  /// existed, and a failure to open falls through to the caller's browser
  /// view.
  Future<ConnectFlowOutcome> run(Uri url) async =>
      openResolved(await resolve(url));

  /// Opens an already-[resolve]d URL in the authentication session.
  ///
  /// Split from [run] so the caller can reuse the same minted handoff for the
  /// browser-view fallback when [ConnectFlowOutcome.unavailable] comes back.
  /// Minting a second one there would burn a token for nothing — and would be
  /// the one place the "always mint fresh" rule is wrong, since the first
  /// token was never consumed.
  Future<ConnectFlowOutcome> openResolved(Uri target) async {
    try {
      await authenticate(
        url: target.toString(),
        callbackScheme: callbackScheme,
      );
      return ConnectFlowOutcome.redirected;
    } on PlatformException catch (e) {
      // The plugin reports a dismissal as CANCELED; anything else means the
      // session never ran.
      return e.code == 'CANCELED'
          ? ConnectFlowOutcome.dismissed
          : ConnectFlowOutcome.unavailable;
    } on Object catch (e) {
      debugPrint('Connect flow could not start: $e');
      return ConnectFlowOutcome.unavailable;
    }
  }

  /// The URL to actually open: a freshly minted handoff wrapping [url] when it
  /// is a connect path on our host, [url] itself otherwise.
  ///
  /// Separate from [openResolved] so the caller can reuse one minted token
  /// across the authentication session *and* the browser-view fallback, and so
  /// a test can assert what gets opened without a browser.
  ///
  /// The failure path is explicit: a null handoff means the original URL,
  /// never an error and never an aborted flow. The user may still be shown a
  /// login page in that case — but they were before this change too, and
  /// refusing to open anything at all would be strictly worse.
  Future<Uri> resolve(Uri url) async {
    if (!needsWebSessionHandoff(url)) {
      return url;
    }
    try {
      final handoff = await mintHandoff(next: connectNextPath(url));
      if (handoff != null && handoff.isNotEmpty) {
        final parsed = Uri.tryParse(handoff);
        if (parsed != null) {
          return parsed;
        }
      }
    } on Object catch (e) {
      debugPrint('Web-session handoff for a connect flow failed: $e');
    }
    return url;
  }
}
