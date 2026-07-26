import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/label_bitmap.dart';
import '../models/printer_profile.dart';

/// The exact pixel raster to ask the server to render, derived from the
/// label's physical size and the printer's dot pitch.
///
/// A thermal printhead has a fixed number of heating elements at a fixed dpi,
/// so the *only* correct raster is `millimetres × dpi / 25.4`, capped at the
/// head's element count. Sizing off the printhead width and the label's aspect
/// ratio instead (which is what this used to do) silently rescales the label:
/// a 76 × 51 mm label on a 96-dot head came out as a 96 × 64 px image — 32
/// effective dpi, with every glyph a few pixels tall. That is what made the
/// preview unreadable, and it prints exactly as badly as it looks.
class LabelRasterSpec {
  const LabelRasterSpec({
    required this.widthPx,
    required this.heightPx,
    required this.dpi,
    required this.headWidthMm,
    required this.labelWidthMm,
    required this.labelHeightMm,
  });

  factory LabelRasterSpec.of(
    PrinterProfile profile,
    (double widthMm, double heightMm) labelSizeMm,
  ) {
    final (widthMm, heightMm) = labelSizeMm;
    final dotsPerMm = profile.dpi / 25.4;
    return LabelRasterSpec(
      // The head can't print wider than it is, however wide the label is.
      widthPx: _clampPx(
        (widthMm * dotsPerMm).round().clamp(1, profile.printWidthPx),
      ),
      heightPx: _clampPx((heightMm * dotsPerMm).round()),
      dpi: profile.dpi,
      headWidthMm: profile.printWidthPx / dotsPerMm,
      labelWidthMm: widthMm,
      labelHeightMm: heightMm,
    );
  }

  /// The renderer's own bounds (`MIN_DIMENSION`/`MAX_DIMENSION` in the
  /// backend's `labels.py`); outside them the request is a 400, not a label.
  static int _clampPx(int px) => px.clamp(16, 4000);

  final int widthPx;
  final int heightPx;
  final int dpi;
  final double headWidthMm;
  final double labelWidthMm;
  final double labelHeightMm;

  /// True when the label is wider than the printer can physically print, so
  /// the raster had to be cropped to the head. Nothing the app can do fixes
  /// this — the label size and the printer genuinely disagree.
  bool get exceedsHead => labelWidthMm > headWidthMm + 0.5;

  /// One line of what the app actually asked for, for the debug preview.
  String get summary =>
      '$widthPx×$heightPx px @ $dpi dpi · '
      '${_mm(labelWidthMm)}×${_mm(labelHeightMm)} mm label, '
      '${_mm(headWidthMm)} mm printhead';

  static String _mm(double v) => v.toStringAsFixed(v >= 10 ? 0 : 1);
}

/// Turns a server-rendered label image into the printer's 1-bit raster.
///
/// The backend renders the label as a 1-bit (or grayscale) PNG at the printer's
/// exact width — 96 px for the D11s. This only re-packs pixels into the
/// printer's row format; it does no layout, so label design stays on the
/// server.
class LabelRaster {
  const LabelRaster._();

  /// Decodes a label [png] and packs it. If [targetWidth] is given, the image
  /// is scaled to that width first (preserving aspect) — the server renders a
  /// generic label, so each printer resizes to its own printhead width before
  /// packing. Pixels darker than [threshold] (0.0–1.0 luminance) become black
  /// (bit = 1).
  static LabelBitmap fromPng(
    Uint8List png, {
    int? targetWidth,
    double threshold = 0.5,
  }) {
    final image = img.decodePng(png);
    if (image == null) {
      throw const FormatException('label image is not a valid PNG');
    }
    return fromImage(image, targetWidth: targetWidth, threshold: threshold);
  }

  static LabelBitmap fromImage(
    img.Image source, {
    int? targetWidth,
    double threshold = 0.5,
  }) {
    final image = (targetWidth != null && targetWidth != source.width)
        ? img.copyResize(source, width: targetWidth)
        : source;
    final width = image.width;
    final rows = image.height;
    final bytesPerRow = (width + 7) >> 3;
    final data = Uint8List(bytesPerRow * rows);
    for (var y = 0; y < rows; y++) {
      final rowBase = y * bytesPerRow;
      for (var x = 0; x < width; x++) {
        // MSB = leftmost pixel; dark pixel → black (heater on).
        if (image.getPixel(x, y).luminanceNormalized < threshold) {
          data[rowBase + (x >> 3)] |= 0x80 >> (x & 7);
        }
      }
    }
    return LabelBitmap(bytesPerRow: bytesPerRow, rows: rows, data: data);
  }
}
