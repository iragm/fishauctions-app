import 'dart:convert';
import 'dart:typed_data';

import 'package:fishauctions_application/services/label_print_service.dart';
import 'package:fishauctions_application/services/label_service.dart';
import 'package:fishauctions_application/services/printer_profile_driver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLabelBatch', () {
    test('reads labels, remaining and skipped', () {
      final batch = parseLabelBatch({
        'labels': [
          {
            'lot': 12,
            'content_type': 'image/png',
            'png': base64Encode([1, 2, 3]),
          },
        ],
        'remaining': [13, 14],
        'skipped': [
          {'lot': 99, 'detail': 'Lot not found.'},
        ],
        'resolution': '600x400',
        'dpi': 203,
      });
      expect(batch.labels.single.lot, 12);
      expect(batch.labels.single.png, [1, 2, 3]);
      expect(batch.remaining, [13, 14]);
      expect(batch.skipped.single.lot, 99);
      expect(batch.skipped.single.detail, 'Lot not found.');
    });

    test('accepts the body as a string', () {
      final batch = parseLabelBatch(
        jsonEncode({
          'labels': [
            {
              'lot': 5,
              'png': base64Encode([9]),
            },
          ],
        }),
      );
      expect(batch.labels.single.lot, 5);
      expect(batch.remaining, isEmpty);
      expect(batch.skipped, isEmpty);
    });

    // A shape this build doesn't understand falls back to one GET per label
    // rather than printing from a guess.
    test('refuses what it cannot read', () {
      expect(() => parseLabelBatch('not json'), throwsFormatException);
      expect(() => parseLabelBatch([1, 2]), throwsFormatException);
      expect(() => parseLabelBatch({'labels': 'x'}), throwsFormatException);
      expect(
        () => parseLabelBatch({
          'labels': [
            {'lot': '12', 'png': ''},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('LabelChunk.fromBatch', () {
    final png = Uint8List.fromList([1]);

    test('prints in the order asked, whatever order the answer used', () {
      final chunk = LabelChunk.fromBatch(
        const [1, 2, 3],
        LabelBatch(
          labels: [(lot: 2, png: png), (lot: 1, png: png)],
          remaining: const [3],
        ),
      );
      expect(chunk.labels.map((label) => label.lot), [1, 2]);
      expect(chunk.unrendered, [3]);
    });

    // `remaining` forgetting lot 3 and naming a lot nobody asked for must
    // neither lose a label nor print a stranger's.
    test('the window, not remaining, decides what is asked for again', () {
      final chunk = LabelChunk.fromBatch(const [
        1,
        2,
        3,
      ], LabelBatch(labels: [(lot: 1, png: png)], remaining: const [2, 77]));
      expect(chunk.unrendered, [2, 3]);
    });

    test('a refused lot is skipped, not asked for again', () {
      final chunk = LabelChunk.fromBatch(
        const [1, 2],
        LabelBatch(
          labels: [(lot: 2, png: png)],
          skipped: const [(lot: 1, detail: 'Lot not found.')],
        ),
      );
      expect(chunk.labels.single.lot, 2);
      expect(chunk.skipped.single.lot, 1);
      expect(chunk.unrendered, isEmpty);
    });

    // Asking again after an answer that got nowhere would never end.
    test('an answer that makes no progress is refused', () {
      expect(
        () => LabelChunk.fromBatch(const [
          1,
          2,
        ], const LabelBatch(labels: [], remaining: [1, 2])),
        throwsFormatException,
      );
    });
  });

  group('PrintRunLedger', () {
    const clear = ProfilePrinterStatus.ready;
    const busy = ProfilePrinterStatus({'printing'});
    const jammed = ProfilePrinterStatus({'paper_jam'});

    void send(PrintRunLedger ledger, int lot) {
      ledger
        ..sending(lot)
        ..sent();
    }

    test('a label counts once the printer is next seen idle', () {
      final ledger = PrintRunLedger();
      send(ledger, 1);
      expect(ledger.observe(busy), isNull);
      expect(ledger.printed, isEmpty);
      expect(ledger.observe(clear), isNull);
      expect(ledger.printed, [1]);
    });

    // The paper-jam report: a jam used to be a successful print because the
    // bytes had been written.
    test('a jam fails what was in the printer, and says why', () {
      final ledger = PrintRunLedger();
      send(ledger, 1);
      ledger.observe(clear);
      send(ledger, 2);
      ledger.observe(busy);
      send(ledger, 3);
      final blocker = ledger.observe(jammed);
      expect(blocker?.message, contains('jam'));
      expect(ledger.printed, [1]);
      expect(ledger.failed, [2, 3]);
      expect(ledger.conditions, {'paper_jam'});
    });

    test('a printer that cannot say leaves what it was sent as printed', () {
      final ledger = PrintRunLedger();
      send(ledger, 1);
      expect(ledger.observe(null), isNull);
      ledger.close();
      expect(ledger.printed, [1]);
      expect(ledger.failed, isEmpty);
    });

    test('a label cut off mid-send failed; one never started did not', () {
      final cut = PrintRunLedger()
        ..sending(1)
        ..stopped();
      expect(cut.failed, [1]);
      expect(cut.wasAttempted(1), isTrue);

      final untouched = PrintRunLedger()..stopped();
      expect(untouched.failed, isEmpty);
    });

    test('a printer blocked before anything was sent fails nothing', () {
      final ledger = PrintRunLedger();
      expect(
        ledger.observe(const ProfilePrinterStatus({'cover_open'})),
        isNotNull,
      );
      expect(ledger.failed, isEmpty);
      expect(ledger.conditions, {'cover_open'});
    });
  });
}
