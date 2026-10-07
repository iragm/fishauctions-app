import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// How a failed main-frame load should be treated by the WebViews.
enum LoadErrorKind {
  /// A real failure — no connection, DNS, TLS, a timeout. Say so.
  failed,

  /// The load was replaced by another one before it finished: the user tapped
  /// a second link, a page script navigated during load. The replacement
  /// reports its own start and stop, so this one is simply forgotten.
  superseded,

  /// The load was stopped on purpose — our own navigation policy cancelling a
  /// redirect (an off-site hop handed to the browser, a connect flow), or the
  /// response becoming a download. Nothing else will report a stop for it, so
  /// the progress bar has to be cleared, but there is nothing to tell anyone.
  interrupted,
}

/// Sorts a main-frame [error] into a [LoadErrorKind].
///
/// **WKWebView reports every abandoned provisional load as a failure**, and
/// `flutter_inappwebview` forwards each one to `onReceivedError` unfiltered:
/// `NSURLErrorCancelled` (-999) whenever a navigation is superseded, and
/// WebKit's own code 102 ("Frame load interrupted") whenever a decision
/// handler cancels a load already in flight — which this app does on purpose
/// for every off-site redirect it sends to the browser. Treating those as
/// "Can't reach the server" put the offline banner over a page that was
/// working, and marked it failed so the next resume reloaded it.
///
/// The WebKit codes arrive with no type of their own (the plugin only maps
/// `URLError`s), so they're recognized from the description it composes:
/// `domain=WebKitErrorDomain, code=102, …`. 204 is "plug-in handled load",
/// the same non-failure for media.
LoadErrorKind classifyLoadError(WebResourceError error) {
  if (error.type == WebResourceErrorType.CANCELLED) {
    return LoadErrorKind.superseded;
  }
  if (_webKitInterrupted.hasMatch(error.description)) {
    return LoadErrorKind.interrupted;
  }
  return LoadErrorKind.failed;
}

final _webKitInterrupted = RegExp(r'WebKitErrorDomain, code=(102|204)\b');
