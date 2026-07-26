import 'package:fishauctions_application/services/label_print_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('lotPksFromPrintLink', () {
    test('reads the single-lot form the per-lot button emits', () {
      expect(lotPksFromPrintLink(Uri.parse('fishauctions://print/12')), [12]);
      expect(lotPksFromPrintLink(Uri.parse('fishauctions://print/12/')), [12]);
    });

    // The bulk label buttons on the Bluetooth method: a thermal printer can't
    // be fed the PDF sheet, so the page hands over the lot set instead.
    test('reads the batch form', () {
      expect(
        lotPksFromPrintLink(Uri.parse('fishauctions://print/?lots=12,13,14')),
        [12, 13, 14],
      );
    });

    test('accepts repeated lots params', () {
      expect(
        lotPksFromPrintLink(Uri.parse('fishauctions://print/?lots=3&lots=4')),
        [3, 4],
      );
    });

    test('keeps page order and drops duplicates', () {
      expect(
        lotPksFromPrintLink(Uri.parse('fishauctions://print/?lots=9,4,9,4,7')),
        [9, 4, 7],
      );
    });

    // A malformed link should print the labels it can, not nothing.
    test('drops junk rather than the whole link', () {
      expect(
        lotPksFromPrintLink(
          Uri.parse('fishauctions://print/?lots=5,,x,-2,0,6'),
        ),
        [5, 6],
      );
    });

    // A bare link ("set up printing") — the shell falls back to /printing/.
    test('is empty with no pks', () {
      expect(lotPksFromPrintLink(Uri.parse('fishauctions://print/')), isEmpty);
      expect(lotPksFromPrintLink(Uri.parse('fishauctions://print')), isEmpty);
    });
  });

  group('LabelPrintProgress', () {
    test('counts the label in the printer, not the ones finished', () {
      const progress = LabelPrintProgress(done: 2, total: 12);
      expect(progress.message, 'Printing label 3 of 12…');
    });

    test('does not count a single label', () {
      const progress = LabelPrintProgress(done: 0, total: 1);
      expect(progress.message, 'Printing label…');
    });

    test('never counts past the total on the last label', () {
      const progress = LabelPrintProgress(done: 12, total: 12);
      expect(progress.message, 'Printing label 12 of 12…');
    });
  });
}
