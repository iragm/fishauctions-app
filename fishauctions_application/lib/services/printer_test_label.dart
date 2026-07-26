import 'package:image/image.dart' as img;

import '../models/label_bitmap.dart';
import '../models/printer_profile.dart';
import 'label_raster.dart';

/// Builds the "is this printer set up correctly?" test label.
///
/// Deliberately rendered **on-device** rather than by the backend, which is the
/// opposite of the rule for everything else in this app. The reasons are
/// specific to what this label is for:
///
///  * It has to work at the moment a printer is being paired — which is before
///    the user has picked a lot, may be offline in an auction hall, and is
///    exactly when the server round trip is the least reliable part.
///  * It is hardware diagnostics, not product display. Nothing here is a
///    business decision anyone would want to change from Django: it is a ruler,
///    an orientation arrow, and the profile's own numbers printed back.
///
/// What it proves, in one 5-second loop:
///  * ink came out at all → the profile's command language is right;
///  * the border is a rectangle with all four sides → width and height are
///    right, and the raster isn't skewed by a wrong `width_bytes`;
///  * text is black-on-white, not white-on-black → `invert` is right;
///  * the arrow points up → `DIRECTION` is right.
class PrinterTestLabel {
  const PrinterTestLabel._();

  /// Renders a test label [widthPx] × [heightPx] describing [profile].
  static LabelBitmap build(
    PrinterProfile profile, {
    required int widthPx,
    required int heightPx,
  }) {
    // RGB, white background — the same shape as the server-rendered label
    // PNGs, so this goes down an identical path through LabelRaster. The
    // profile's `invert` is applied downstream by the driver, so this is
    // always drawn the "normal" way round: black ink on white.
    //
    // Deliberately *not* a 1-channel grayscale image. `img.Image` is
    // zero-initialised, i.e. black, and filling a 1-channel image with an RGB
    // colour silently does nothing — leaving an all-black canvas that inverts
    // into "paint every dot" and hands the user a solid black label.
    final image = img.Image(width: widthPx, height: heightPx);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    final black = img.ColorRgb8(0, 0, 0);

    // A border proves the full raster reached the head: a wrong width_bytes
    // shears it into a diagonal, and a wrong height truncates the bottom edge.
    img.drawRect(
      image,
      x1: 0,
      y1: 0,
      x2: widthPx - 1,
      y2: heightPx - 1,
      color: black,
      thickness: 2,
    );

    // Pick a font that suits the head. A 96 px D11s strip can't carry arial24.
    final font = widthPx >= 384 ? img.arial24 : img.arial14;
    final lineHeight = widthPx >= 384 ? 28 : 16;
    var y = widthPx >= 384 ? 14 : 8;

    void line(String text) {
      if (y + lineHeight < heightPx - 4) {
        img.drawString(image, text, font: font, x: 8, y: y, color: black);
      }
      y += lineHeight;
    }

    line('TEST LABEL - OK');
    line(profile.name);
    line('${widthPx}x$heightPx px @ ${profile.dpi}dpi');
    line(
      'head ${profile.printWidthPx}px'
      '${profile.invertRaster ? ' inverted' : ''}',
    );

    // "This edge came out of the printer first." If it prints at the bottom or
    // mirrored, DIRECTION (TSPL) or the row order is wrong.
    y += 4;
    _drawUpArrow(image, x: widthPx ~/ 2, y: y, size: lineHeight, color: black);
    y += lineHeight + 6;

    // A dot ruler: ticks every 1 mm, longer every 5 mm. If the spacing is
    // visibly uneven, or the ruler doesn't span the label, the raster is being
    // rescaled somewhere it shouldn't be.
    _drawRuler(
      image,
      y: y,
      dpi: profile.dpi,
      widthPx: widthPx,
      height: lineHeight,
      color: black,
    );

    return LabelRaster.fromImage(image);
  }

  static void _drawUpArrow(
    img.Image image, {
    required int x,
    required int y,
    required int size,
    required img.Color color,
  }) {
    final half = size ~/ 2;
    for (var i = 0; i < half; i++) {
      img.drawLine(
        image,
        x1: x - i,
        y1: y + i,
        x2: x + i,
        y2: y + i,
        color: color,
      );
    }
    img.drawLine(
      image,
      x1: x,
      y1: y,
      x2: x,
      y2: y + size,
      color: color,
      thickness: 2,
    );
  }

  static void _drawRuler(
    img.Image image, {
    required int y,
    required int dpi,
    required int widthPx,
    required int height,
    required img.Color color,
  }) {
    if (y + height >= image.height) {
      return;
    }
    final dotsPerMm = dpi / 25.4;
    for (var mm = 0; ; mm++) {
      final x = (mm * dotsPerMm).round();
      if (x >= widthPx - 2) {
        break;
      }
      final tick = mm % 5 == 0 ? height : height ~/ 2;
      img.drawLine(image, x1: x, y1: y, x2: x, y2: y + tick, color: color);
    }
  }
}
