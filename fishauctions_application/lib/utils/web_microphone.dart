import '../config/environment.dart';

/// Set lot winners, the one page whose own microphone the shell lets through.
final RegExp _setWinnersPath = RegExp(r'^/auctions/[^/]+/lots/set-winners/?$');

/// Whether the page at [page] may have the WebView's microphone
/// (`getUserMedia({audio: true})`).
///
/// **One page, on our own host, and nothing else.** Set lot winners can
/// listen through OpenAI, streaming its microphone over WebRTC — a real
/// alternative to the app's recognizer, and the only thing on the site that
/// needs the page to hear. Everything else is denied as before: this shell
/// renders user-authored HTML (lot descriptions, reference links), and a
/// microphone that any page could open is not a thing to hand out because one
/// page wants it.
///
/// Matched on the page's *URL*, not the request's origin: the origin says
/// which site is asking, not which page. Both are checked by the caller.
bool allowsWebMicrophone(Uri? page) {
  final site = Uri.parse(EnvironmentConfig.webBaseUrl);
  if (page == null || page.scheme != site.scheme || page.host != site.host) {
    return false;
  }
  return _setWinnersPath.hasMatch(page.path);
}
