import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/label_bitmap.dart';

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
