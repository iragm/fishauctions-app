import 'package:fishauctions_application/models/printer_profile.dart';
import 'package:fishauctions_application/services/bundled_printer_profiles.dart';
import 'package:fishauctions_application/services/printer_test_label.dart';
import 'package:flutter_test/flutter_test.dart';

PrinterProfile _profile(String slug) =>
    bundledPrinterProfiles().firstWhere((p) => p.slug == slug);

/// Fraction of dots the bitmap asks the printhead to burn.
double _inkCoverage(List<int> data) {
  var set = 0;
  for (final byte in data) {
    set += byte.toRadixString(2).replaceAll('0', '').length;
  }
  return set / (data.length * 8);
}

void main() {
  group('PrinterTestLabel', () {
    test('is mostly white — a few percent ink, not a solid block', () {
      // The first version of this built a 1-channel grayscale canvas and
      // filled it with an RGB colour. The fill silently did nothing, the
      // zero-initialised (black) canvas went to the printer, and a TSPL
      // printer — which burns on a 0 bit — turned the whole thing solid
      // black. On a roll of labels that is not a subtle failure.
      final bitmap = PrinterTestLabel.build(
        _profile('tspl-raster'),
        widthPx: 609,
        heightPx: 406,
      );
      final coverage = _inkCoverage(bitmap.data);
      expect(coverage, greaterThan(0.001), reason: 'nothing was drawn');
      expect(coverage, lessThan(0.25), reason: 'label is nearly solid ink');
    });

    test('fills the raster it was asked for', () {
      final bitmap = PrinterTestLabel.build(
        _profile('tspl-raster'),
        widthPx: 609,
        heightPx: 406,
      );
      expect(bitmap.rows, 406);
      // 609 dots packs into ceil(609/8) = 77 bytes per row.
      expect(bitmap.bytesPerRow, 77);
      expect(bitmap.data.length, 77 * 406);
    });

    test('renders on a narrow printhead without overflowing it', () {
      // A 96 px D11s strip has to fall back to the small font and still
      // produce a valid, mostly-white bitmap.
      final bitmap = PrinterTestLabel.build(
        _profile('d11s-aiyin'),
        widthPx: 96,
        heightPx: 320,
      );
      expect(bitmap.bytesPerRow, 12);
      expect(bitmap.rows, 320);
      expect(_inkCoverage(bitmap.data), lessThan(0.25));
    });
  });
}
