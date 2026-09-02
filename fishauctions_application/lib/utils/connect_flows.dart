/// The third-party accounts a club or seller can connect from inside the app,
/// and the URL rules that keep those round trips in one browsing context.
///
/// **All five break the same way, for the same reason.** A connect link opens
/// in an authentication session (`ASWebAuthenticationSession` on iOS, Chrome's
/// Auth Tab on Android) because that is the only surface that can run a
/// provider's own login — Google and Square SSO both refuse an embedded
/// WebView, and Apple's Tap to Pay review guide requires onboarding to finish
/// without leaving the app. That surface carries **Safari's cookie jar, not
/// the shell WebView's**, so it arrives at our host with no Django session:
/// every connect view is `LoginRequiredMixin`, so it 302s to `/login/` and the
/// user is shown a sign-in page inside an app they are already signed in to.
///
/// Signing in again there does not help either. Each of these flows stashes
/// its OAuth state — the club slug, a CSRF nonce — in the Django session
/// before redirecting to the provider, so a callback landing in a *different*
/// session dies on "your connection session expired" no matter who is signed
/// in to it. The two halves of the round trip have to share one session, which
/// means the session has to exist before the first hop.
///
/// `ConnectFlowService` is what supplies it: mint a single-use web-session
/// handoff and open *that*, with the connect path as `next`. This file is the
/// pure half — which URLs are connect flows, and what `next` should say — kept
/// separate so it can be tested without a browser.
library;

import '../config/environment.dart';

/// Where a URL sits in a connect round trip.
enum ConnectFlowRole {
  /// A path on our host whose entire job is to stash OAuth state and redirect
  /// to the provider. Reaching one of these in the shell WebView is already
  /// the bug: the state would be written to the shell's session and the
  /// callback would land in the auth session's. They are diverted out of the
  /// shell before they navigate.
  launcher,

  /// A page on our host that is part of a connect flow but is also an ordinary
  /// page — the Discord settings page, which carries the bot-invite link and
  /// is where that flow returns. It renders in the shell normally; it needs a
  /// handoff only when something opens it *outside* the shell.
  page,

  /// The provider's own domain (Square, PayPal, Mailchimp, Google, Discord).
  /// Needs no handoff — our session means nothing there — but must stay in the
  /// same authentication session rather than being ejected to the system
  /// browser mid-OAuth.
  provider,
}

/// Our host's connect launchers, in the order they appear in `auctions/urls.py`.
///
/// Anchored and slug-shaped rather than a loose `startsWith`, so a lot titled
/// "square/connect" or a stray query can't push a page out of the shell.
final List<RegExp> _launcherPaths = [
  RegExp(r'^/square/connect/?$'),
  RegExp(r'^/paypal/connect/?$'),
  RegExp(r'^/mailchimp/connect/[^/]+/?$'),
  RegExp(r'^/google-calendar/connect/[^/]+/?$'),
];

/// The Discord settings page (`/clubs/<slug>/discord/`), which carries the
/// bot-invite link. Not a launcher: it is a real page with forms on it and
/// belongs in the shell. It is here so that if it is ever opened in the
/// authentication session — the invite returns to it, and a future flow may
/// redirect there — it arrives with a session instead of at `/login/`.
final RegExp _connectPagePath = RegExp(r'^/clubs/[^/]+/discord/?$');

/// Provider domains a connect round trip legitimately passes through.
///
/// Host-matched rather than path-matched: an OAuth flow changes host several
/// times (a consent screen, an SSO hop, a login), and one of those hops being
/// ejected to the system browser is exactly the failure this exists to stop.
const Set<String> _providerHosts = {
  'squareup.com',
  'squareupsandbox.com',
  'paypal.com',
  'paypalobjects.com',
  'mailchimp.com',
  'accounts.google.com',
  'discord.com',
};

/// True when [uri] is on one of the provider domains (or a subdomain of one) —
/// `connect.squareup.com`, `login.mailchimp.com`, `www.paypal.com`, and so on.
bool isConnectProviderHost(Uri uri) {
  final host = uri.host.toLowerCase();
  return _providerHosts.any((h) => host == h || host.endsWith('.$h'));
}

/// The site's own host, as configured for this flavor.
String get _webHost => Uri.parse(EnvironmentConfig.webBaseUrl).host;

/// What part [uri] plays in a connect flow, or null if it plays none.
ConnectFlowRole? connectFlowRole(Uri uri) {
  if (uri.host.toLowerCase() == _webHost.toLowerCase()) {
    if (_launcherPaths.any((p) => p.hasMatch(uri.path))) {
      return ConnectFlowRole.launcher;
    }
    if (_connectPagePath.hasMatch(uri.path)) {
      return ConnectFlowRole.page;
    }
    return null;
  }
  return isConnectProviderHost(uri) ? ConnectFlowRole.provider : null;
}

/// Whether a navigation to [uri] should be pulled out of the shell WebView and
/// run in the authentication session instead.
///
/// Only launchers: they exist purely to redirect, so nothing is lost by never
/// rendering them, and letting one run in the shell splits the round trip
/// across two sessions. The Discord settings page and the provider domains are
/// deliberately excluded — the first belongs in the shell, and the second is
/// only ever reached from inside a session that is already running.
bool startsConnectFlowInShell(Uri uri) =>
    connectFlowRole(uri) == ConnectFlowRole.launcher;

/// Whether opening [uri] in the authentication session needs a Django session
/// minted for it first — i.e. it is on our host and `LoginRequiredMixin` is
/// waiting.
bool needsWebSessionHandoff(Uri uri) {
  final role = connectFlowRole(uri);
  return role == ConnectFlowRole.launcher || role == ConnectFlowRole.page;
}

/// Whether [uri] should run in the authentication session rather than the
/// system browser: any leg of a connect round trip, ours or the provider's.
bool runsInAuthSession(Uri uri) => connectFlowRole(uri) != null;

/// The `next=` value for a connect URL on our host: its path and query, with
/// `return_to_app=1` added.
///
/// **Query strings are load-bearing** — `/square/connect/?club=<slug>` is how
/// the club membership page connects a club rather than a user — so the
/// existing query is preserved verbatim and the marker is merged in beside it.
///
/// `return_to_app=1` is very nearly redundant now: consuming a handoff marks
/// the session as app-originated server-side, which is the same switch that
/// turns on the Square callback's closing page and its
/// `fishauctions-oauth://square-connected` redirect. It is still sent because
/// it costs one query parameter and it keeps working on the path where the
/// handoff itself failed and we fell through to the bare URL.
String connectNextPath(Uri uri) {
  final params = Map<String, String>.from(uri.queryParameters)
    ..['return_to_app'] = '1';
  final path = uri.path.isEmpty ? '/' : uri.path;
  return Uri(path: path, queryParameters: params).toString();
}
