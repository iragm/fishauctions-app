import 'dart:typed_data';

import 'package:fishauctions_application/services/label_raster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image _white(int w, int h) => img.fill(
  img.Image(width: w, height: h),
  color: img.ColorRgb8(255, 255, 255),
);

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
}
