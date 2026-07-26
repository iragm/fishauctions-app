import 'dart:typed_data';

import 'package:fishauctions_application/models/printer_profile.dart';
import 'package:fishauctions_application/services/bundled_printer_profiles.dart';
import 'package:fishauctions_application/services/label_raster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image _white(int w, int h) => img.fill(
  img.Image(width: w, height: h),
  color: img.ColorRgb8(255, 255, 255),
);

PrinterProfile _profile(String slug) =>
    bundledPrinterProfiles().firstWhere((p) => p.slug == slug);

void main() {
  group('LabelRaster.fromImage', () {
    test('packs MSB-first, dark pixel = 1', () {
      final image = _white(8, 1)..setPixelRgb(0, 0, 0, 0, 0); // leftmost black

      final bmp = LabelRaster.fromImage(image);

      expect(bmp.bytesPerRow, 1);
      expect(bmp.rows, 1);
      expect(bmp.widthPx, 8);
      expect(bmp.data[0], 0x80); // only the top bit set
    });

    test('rounds width up to whole bytes (96px → 12 bytes)', () {
      final bmp = LabelRaster.fromImage(_white(96, 3));
      expect(bmp.bytesPerRow, 12);
      expect(bmp.rows, 3);
      expect(bmp.data.length, 36);
      // All white → no bits set.
      expect(bmp.data.every((b) => b == 0), isTrue);
    });

    test('rightmost pixel of a byte is the low bit', () {
      final image = _white(8, 1)..setPixelRgb(7, 0, 0, 0, 0); // rightmost black
      expect(LabelRaster.fromImage(image).data[0], 0x01);
    });

    test('resizes to the target width (600x400 → 96px / 12 bytes)', () {
      final bmp = LabelRaster.fromImage(_white(600, 400), targetWidth: 96);
      expect(bmp.widthPx, 96);
      expect(bmp.bytesPerRow, 12);
      expect(bmp.rows, 64); // 400 * 96/600, aspect preserved
    });
  });

  group('LabelRaster.fromPng', () {
    test('decodes a PNG and packs it', () {
      final image = _white(8, 1)..setPixelRgb(0, 0, 0, 0, 0);
      final png = img.encodePng(image);

      final bmp = LabelRaster.fromPng(png);
      expect(bmp.data[0], 0x80);
    });

    test('throws a FormatException on non-PNG bytes', () {
      expect(
        () => LabelRaster.fromPng(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });
  });

  group('LabelRasterSpec.of', () {
    // The two bundled printhead widths: a 12 mm D11s and a 58 mm ESC/POS,
    // both 203 dpi (8 dots/mm).
    final d11s = _profile('d11s-aiyin');
    final escpos = _profile('escpos-raster');

    test('sizes the raster from millimetres and dpi, not the aspect ratio', () {
      // A 40 × 30 mm label fits the 58 mm head: 40 mm × 8 dots/mm = 320,
      // 30 mm × 8 = 240. The old aspect-ratio math gave 384 × 288 — the label
      // stretched across the whole head regardless of how wide it really was.
      final spec = LabelRasterSpec.of(escpos, (40, 30));

      expect(spec.widthPx, 320);
      expect(spec.heightPx, 240);
      expect(spec.dpi, 203);
      expect(spec.exceedsHead, isFalse);
    });

    test('caps the width at the printhead and flags the mismatch', () {
      // A 76.2 × 50.8 mm (3" × 2") label on a 12 mm head. Height still comes
      // from the label — the old math derived it from the capped width and
      // produced a 96 × 64 px image, i.e. 32 effective dpi.
      final spec = LabelRasterSpec.of(d11s, (76.2, 50.8));

      expect(spec.widthPx, 96, reason: 'clipped to the 96-dot head');
      expect(spec.heightPx, 406, reason: '50.8 mm at 8 dots/mm');
      expect(spec.exceedsHead, isTrue);
      expect(spec.headWidthMm, closeTo(12.0, 0.05));
    });

    test('a label that fits the head exactly is not flagged', () {
      final spec = LabelRasterSpec.of(d11s, (12, 25));

      expect(spec.widthPx, 96);
      expect(spec.heightPx, 200);
      expect(spec.exceedsHead, isFalse);
    });

    test('clamps to the renderer\'s pixel bounds', () {
      // 1 mm ≈ 8 px, under the backend's 16 px minimum.
      expect(LabelRasterSpec.of(d11s, (12, 1)).heightPx, 16);
      // 1 m of label is past the 4000 px ceiling.
      expect(LabelRasterSpec.of(escpos, (48, 1000)).heightPx, 4000);
    });

    test('summary reports what was actually requested', () {
      expect(
        LabelRasterSpec.of(d11s, (76.2, 50.8)).summary,
        '96×406 px @ 203 dpi · 76×51 mm label, 12 mm printhead',
      );
    });
  });
}
