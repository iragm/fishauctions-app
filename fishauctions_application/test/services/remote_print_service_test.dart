import 'package:fishauctions_application/services/label_print_service.dart';
import 'package:fishauctions_application/services/remote_print_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLots', () {
    test('reads the comma string FCM data values are limited to', () {
      expect(RemotePrintService.parseLots('12,13,14'), [12, 13, 14]);
    });

    test('keeps the page order and drops duplicates', () {
      expect(RemotePrintService.parseLots('14, 12,14, 13'), [14, 12, 13]);
    });

    test('drops junk rather than failing the whole job', () {
      // Printing the labels we can read beats printing none of them.
      expect(RemotePrintService.parseLots('12,,x,-3,0,13'), [12, 13]);
    });

    test('an absent or empty list is empty, not an error', () {
      expect(RemotePrintService.parseLots(null), isEmpty);
      expect(RemotePrintService.parseLots(''), isEmpty);
      expect(RemotePrintService.parseLots('abc'), isEmpty);
    });
  });

  group('resultBody', () {
    test('a clean batch reports printed with its counts', () {
      final body = RemotePrintService.resultBody(
        const LabelPrintResult(LabelPrintStatus.sent, printed: 12, total: 12),
        12,
      );
      expect(body['status'], 'printed');
      expect(body['printed'], 12);
      expect(body['total'], 12);
      expect(body.containsKey('message'), isFalse);
    });

    test('a soft warning rides along on a success', () {
      // The labels exist; the person at the computer is the one who can fix
      // the label-size setting that made them come out cropped.
      final body = RemotePrintService.resultBody(
        const LabelPrintResult(
          LabelPrintStatus.sent,
          printed: 3,
          total: 3,
          message: 'Your label size is wider than this printer can print.',
        ),
        3,
      );
      expect(body['status'], 'printed');
      expect(body['message'], contains('wider than'));
    });

    test('a cancelled batch is still printed, with the partial count', () {
      final body = RemotePrintService.resultBody(
        const LabelPrintResult(LabelPrintStatus.sent, printed: 4, total: 12),
        12,
      );
      expect(body['status'], 'printed');
      expect(body['printed'], 4);
      expect(body['total'], 12);
    });

    test("the app's own failure text passes through unedited", () {
      const detail =
          "Couldn't connect to the printer. Make sure it's on and in range.";
      final body = RemotePrintService.resultBody(
        const LabelPrintResult(
          LabelPrintStatus.failed,
          printed: 2,
          total: 9,
          message: detail,
        ),
        9,
      );
      expect(body['status'], 'failed');
      expect(body['message'], detail);
      // How far it got decides which labels to re-print.
      expect(body['printed'], 2);
      expect(body['total'], 9);
    });

    test('a failure with no message still says something actionable', () {
      final body = RemotePrintService.resultBody(
        const LabelPrintResult(LabelPrintStatus.failed, total: 1),
        1,
      );
      expect(body['status'], 'failed');
      expect(body['message'], isNotEmpty);
    });

    test('no printer paired is addressed to the reader at the computer', () {
      final body = RemotePrintService.resultBody(
        const LabelPrintResult(LabelPrintStatus.noPrinter),
        5,
      );
      expect(body['status'], 'failed');
      expect(body['message'], contains('phone'));
      expect(body['total'], 5);
    });

    test('busy is a failure the computer can retry', () {
      final body = RemotePrintService.resultBody(
        const LabelPrintResult(LabelPrintStatus.busy),
        5,
      );
      expect(body['status'], 'failed');
      expect(body['message'], contains('Try again'));
    });

    test('a result with no counts falls back to the job size', () {
      // LabelPrintResult defaults total to 0 for the statuses that never
      // reached the printer; the page still has to render "of N".
      final body = RemotePrintService.resultBody(
        const LabelPrintResult(LabelPrintStatus.failed, message: 'nope'),
        7,
      );
      expect(body['total'], 7);
    });
  });
}
