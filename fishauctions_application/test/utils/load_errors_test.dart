import 'package:fishauctions_application/utils/load_errors.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WebResourceError error(int code, String description) => WebResourceError(
    type:
        WebResourceErrorType.fromNativeValue(code) ??
        WebResourceErrorType.UNKNOWN,
    description: description,
  );

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('a superseded iOS load (-999) is not a failure', () {
    expect(
      classifyLoadError(error(-999, 'cancelled')),
      LoadErrorKind.superseded,
    );
  });

  test('WebKit policy interruptions are not failures', () {
    // The plugin's own wording for a non-URLError (InAppWebView.swift).
    expect(
      classifyLoadError(
        error(-1, 'domain=WebKitErrorDomain, code=102, Frame load interrupted'),
      ),
      LoadErrorKind.interrupted,
    );
    expect(
      classifyLoadError(
        error(-1, 'domain=WebKitErrorDomain, code=204, Plug-in handled load'),
      ),
      LoadErrorKind.interrupted,
    );
  });

  test('real network failures still are', () {
    expect(
      classifyLoadError(
        error(-1009, 'The Internet connection appears to be offline.'),
      ),
      LoadErrorKind.failed,
    );
    expect(
      classifyLoadError(
        error(-1, 'domain=WebKitErrorDomain, code=1020, something else'),
      ),
      LoadErrorKind.failed,
    );
  });
}
