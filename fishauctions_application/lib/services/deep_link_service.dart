import 'package:flutter/foundation.dart';

import '../config/environment.dart';

/// An `https://auction.fish/...` link the OS handed us — an Android App Link
/// or an iOS Universal Link — on its way to the WebView shell.
///
/// The app claims its own deployment's https links and nothing else (see the
/// intent filter in `AndroidManifest.xml`), so every link that reaches here is
/// a page on the site: the shell's job is to load it. There is no native route
/// to map onto — the app is a WebView shell, and inventing an app-route table
/// that shadowed the website's URLs would need updating every time the site
/// grew a page.
///
/// Same shape as `ShortcutService`: the link is parked in [pending] and stays
/// there until a consumer [consume]s it, so exactly one navigation happens and
/// a link tapped while signed out survives the login trap and lands after
/// sign-in rather than being thrown away.
///
/// The link arrives as a **go_router exception**, which is not the hack it
/// looks like. Both platforms deliver a deep link as an absolute URL pushed
/// into the app's router; go_router has no route for `/lots/123/` and never
/// will, so the miss *is* the signal. Handling it in `onException` also fixes
/// the case that existed before there were any deep links at all — an
/// unmatched location used to render go_router's default error page.
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  /// Web path requested by the most recent deep link, until consumed.
  final ValueNotifier<String?> pending = ValueNotifier(null);

  /// Records [uri] as the next destination if it is a page on this
  /// deployment's site. Returns whether it was taken.
  bool offer(Uri uri) {
    final path = webPathFor(uri);
    if (path == null) {
      return false;
    }
    pending.value = path;
    return true;
  }

  /// The site-relative path [uri] names, or null if it isn't one of ours.
  ///
  /// The host must be present and must match [EnvironmentConfig.webBaseUrl].
  /// Requiring it deliberately excludes bare in-app paths: a deep link always
  /// carries the full URL on both platforms, so a host-less location reaching
  /// the exception handler is a mistaken `context.push('/typo')`, and turning
  /// that into a silent web page load would hide the bug rather than surface
  /// it. A cross-host URL is refused outright — the app can only sign in to
  /// one deployment, so opening another one's page in the shell would render a
  /// signed-out site inside a signed-in app.
  static String? webPathFor(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }
    if (uri.host.toLowerCase() !=
        Uri.parse(EnvironmentConfig.webBaseUrl).host.toLowerCase()) {
      return null;
    }
    final path = uri.path.isEmpty ? '/' : uri.path;
    if (!path.startsWith('/') || path.startsWith('//')) {
      return null;
    }
    // Query and fragment ride along: the site uses both (`?locate=<pk>` on a
    // lot page is how "Locate with AR" is linked, and shared links carry
    // filters).
    return Uri(
      path: path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.fragment.isEmpty ? null : uri.fragment,
    ).toString();
  }

  /// Takes the pending path and clears it, so exactly one consumer navigates.
  String? consume() {
    final path = pending.value;
    pending.value = null;
    return path;
  }
}
