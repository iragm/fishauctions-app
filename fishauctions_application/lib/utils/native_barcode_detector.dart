import 'dart:convert' show base64Decode;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'platform_bridge.dart';

/// Gives the WebView a fast `window.BarcodeDetector` where it has none.
///
/// **This is the lot queue's scanning speed on an iPhone.** The site's shared
/// scanner (`camera_scanner.js`, used by the lot queue, quick check-in and
/// quick checkout) prefers the browser's own `BarcodeDetector` and otherwise
/// falls back to ZXing in JavaScript. WKWebView has never shipped
/// `BarcodeDetector`, so every iPhone took the fallback: a full 720p frame
/// decoded synchronously on the page's main thread with `TRY_HARDER`, then a
/// 120 ms pause, so a label was read a few times a second at best and an
/// angled or glare-y one often not at all — while the same phone has Apple's
/// Vision barcode reader sitting idle.
///
/// The script below defines a spec-shaped `BarcodeDetector` whose `detect()`
/// snapshots the frame to a canvas, hands the JPEG to the app over the
/// `barcodeDetect` bridge handler, and resolves with what Vision (iOS) or
/// ML Kit (Android) found. The page needs no change: its feature test finds
/// a detector, takes its native path, and loops as fast as answers come back.
///
/// Installed only where the engine has no `BarcodeDetector` of its own, so
/// an Android WebView that ships the real one (Chromium's, backed by the same
/// ML Kit) keeps it and pays no bridge round trip.
class NativeBarcodeDetector {
  const NativeBarcodeDetector._();

  /// Name of the JS bridge handler the script calls.
  static const handlerName = 'barcodeDetect';

  /// Formats the native readers can decode, in the Shape Detection API's
  /// spelling. Both platforms' mappings live next to their readers
  /// (`AppDelegate.swift`, `MainActivity.kt`).
  static const supportedFormats = [
    'aztec',
    'codabar',
    'code_128',
    'code_39',
    'code_93',
    'data_matrix',
    'ean_13',
    'ean_8',
    'itf',
    'pdf417',
    'qr_code',
    'upc_a',
    'upc_e',
  ];

  /// The longest edge a frame is scaled to before it crosses the bridge.
  /// 1280 resolves a lot label's QR at arm's length (the page's own ZXing
  /// path settled on 720p for the same reason) while keeping the JPEG near
  /// 100 KB, which is what each round trip costs.
  static const maxEdgePx = 1280;

  /// Refuses an image larger than this (base64 characters) rather than
  /// decoding it — a 1280-px JPEG is a small fraction of it.
  static const maxImageChars = 8 * 1024 * 1024;

  /// Main frame only: the scanner pages run there, and nothing an embedded
  /// frame does needs a barcode reader.
  static final userScript = UserScript(
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    source: _script,
  );

  /// The `barcodeDetect` handler. **Never throws** (see `_firstArg` in the
  /// shell): a rejected promise would surface in the page as a failed frame on
  /// every frame. A failure resolves with an empty list and an `error`.
  static Future<Map<String, Object?>> handle(List<dynamic> args) async {
    try {
      final request = args.isEmpty ? null : args.first;
      if (request is! Map) {
        return _empty('no request');
      }
      final image = request['image'];
      if (image is! String || image.isEmpty) {
        return _empty('no image');
      }
      if (image.length > maxImageChars) {
        return _empty('image too large');
      }
      final formats = [
        for (final f in (request['formats'] as List? ?? const []))
          if (f is String && supportedFormats.contains(f)) f,
      ];
      final found = await PlatformBridge.detectBarcodes(
        base64Decode(image),
        formats,
      );
      return {'barcodes': found};
    } on Object catch (e) {
      debugPrint('barcodeDetect failed: $e');
      return _empty('$e');
    }
  }

  static Map<String, Object?> _empty(String error) => {
    'barcodes': const <Object>[],
    'error': error,
  };

  static final String _script =
      '''
(function () {
  if ('BarcodeDetector' in window) { return; }
  var SUPPORTED = ${_jsArray(supportedFormats)};
  var MAX_EDGE = $maxEdgePx;
  var canvas = null;

  function sourceSize(source) {
    if (!source) { return [0, 0]; }
    if (typeof HTMLVideoElement !== 'undefined' && source instanceof HTMLVideoElement) {
      return [source.videoWidth, source.videoHeight];
    }
    if (typeof HTMLImageElement !== 'undefined' && source instanceof HTMLImageElement) {
      return [source.naturalWidth, source.naturalHeight];
    }
    return [source.width || 0, source.height || 0];
  }

  function snapshot(source, w, h) {
    var scale = Math.min(1, MAX_EDGE / Math.max(w, h));
    var cw = Math.max(1, Math.round(w * scale));
    var ch = Math.max(1, Math.round(h * scale));
    canvas = canvas || document.createElement('canvas');
    canvas.width = cw;
    canvas.height = ch;
    var ctx = canvas.getContext('2d');
    if (typeof ImageData !== 'undefined' && source instanceof ImageData) {
      var tmp = document.createElement('canvas');
      tmp.width = w;
      tmp.height = h;
      tmp.getContext('2d').putImageData(source, 0, 0);
      source = tmp;
    }
    ctx.drawImage(source, 0, 0, cw, ch);
    // toBlob encodes off the main thread; toDataURL would stall the preview.
    return new Promise(function (resolve, reject) {
      canvas.toBlob(function (blob) {
        if (!blob) { reject(new Error('Could not capture the camera frame.')); return; }
        var reader = new FileReader();
        reader.onload = function () {
          var url = String(reader.result || '');
          resolve({ image: url.slice(url.indexOf(',') + 1) });
        };
        reader.onerror = function () { reject(reader.error); };
        reader.readAsDataURL(blob);
      }, 'image/jpeg', 0.85);
    });
  }

  function rect(x, y, width, height) {
    if (typeof DOMRectReadOnly === 'function') {
      return new DOMRectReadOnly(x, y, width, height);
    }
    return { x: x, y: y, width: width, height: height, top: y, left: x,
             right: x + width, bottom: y + height };
  }

  function BarcodeDetector(options) {
    var formats = (options && options.formats) || SUPPORTED;
    if (!Array.isArray(formats) || formats.length === 0) {
      throw new TypeError('BarcodeDetector: formats must be a non-empty list.');
    }
    formats.forEach(function (f) {
      if (SUPPORTED.indexOf(f) === -1) {
        throw new TypeError('BarcodeDetector: unsupported format ' + f);
      }
    });
    this._formats = formats.slice();
  }

  BarcodeDetector.getSupportedFormats = function () {
    return Promise.resolve(SUPPORTED.slice());
  };

  BarcodeDetector.prototype.detect = function (source) {
    var formats = this._formats;
    var size = sourceSize(source);
    var w = size[0], h = size[1];
    var bridge = window.flutter_inappwebview;
    // No frame yet, or the bridge isn't up: "nothing in this frame" is the
    // honest answer and keeps the page's loop going.
    if (!w || !h || !bridge || !bridge.callHandler) { return Promise.resolve([]); }
    return snapshot(source, w, h).then(function (shot) {
      return bridge.callHandler('$handlerName', { image: shot.image, formats: formats })
        .then(function (answer) {
          var found = (answer && answer.barcodes) || [];
          // Corners come back normalized (0..1, top-left origin), so they map
          // straight onto the source's own pixels whatever it was scaled to.
          return found.map(function (b) {
            var pts = (b.corners || []).map(function (p) {
              return { x: p[0] * w, y: p[1] * h };
            });
            var xs = pts.map(function (p) { return p.x; });
            var ys = pts.map(function (p) { return p.y; });
            var minX = xs.length ? Math.min.apply(null, xs) : 0;
            var minY = ys.length ? Math.min.apply(null, ys) : 0;
            var maxX = xs.length ? Math.max.apply(null, xs) : 0;
            var maxY = ys.length ? Math.max.apply(null, ys) : 0;
            return {
              rawValue: b.rawValue || '',
              format: b.format || 'unknown',
              cornerPoints: pts,
              boundingBox: rect(minX, minY, maxX - minX, maxY - minY),
            };
          }).filter(function (b) { return b.rawValue; });
        });
    });
  };

  try {
    Object.defineProperty(window, 'BarcodeDetector', {
      value: BarcodeDetector, configurable: true, writable: true,
    });
  } catch (e) {
    window.BarcodeDetector = BarcodeDetector;
  }
})();
''';

  static String _jsArray(List<String> values) =>
      '[${values.map((v) => "'$v'").join(', ')}]';
}
