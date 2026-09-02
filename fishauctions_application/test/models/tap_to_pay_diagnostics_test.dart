import 'package:fishauctions_application/models/tap_to_pay_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

TapToPayDiagnostics _diag({
  List<TapToPayReaderLine> readers = const [],
  List<String> errors = const [],
  String? lastUnavailableReason,
  String? applicationId,
  bool? cardProcessingActivated,
  String? eligibilityMessage,
}) => TapToPayDiagnostics(
  capturedAt: DateTime.utc(2026, 9, 2, 13, 25),
  platform: 'ios',
  osVersion: '26.6.1',
  readers: readers,
  errors: errors,
  applicationId: applicationId,
  cardProcessingActivated: cardProcessingActivated,
  eligibilityMessage: eligibilityMessage,
  lastUnavailableReason: lastUnavailableReason,
);

const _tapToPayReady = TapToPayReaderLine(model: 'tapToPay', status: 'ready');

void main() {
  group('describeUnavailableReason', () {
    test('explains the reasons that have an action behind them', () {
      expect(
        describeUnavailableReason('tapToPayIsNotLinked'),
        contains('Apple Account'),
      );
      expect(
        describeUnavailableReason('deviceDeveloperMode'),
        contains('Developer options'),
      );
      expect(
        describeUnavailableReason('merchantNotActivated'),
        contains('card-processing'),
      );
    });

    test('points secureConnectionToSquareFailure at the attestation', () {
      // Square reports this when it will not vouch for the app, which is
      // where a rejected App Attest assertion or an unregistered application
      // signature lands. Naming that is the whole point of the mapping.
      final text = describeUnavailableReason('secureConnectionToSquareFailure');
      expect(text, contains('attestation'));
      expect(text, contains('application signature'));
    });

    test('names App Attest under internalError', () {
      expect(describeUnavailableReason('internalError'), contains('Attest'));
    });

    test('still says something useful for a reason it has never seen', () {
      // The SDK enum gains cases faster than this app ships, so an unknown
      // name must not degrade to an empty string.
      expect(
        describeUnavailableReason('someFutureReason'),
        'Square reported "someFutureReason".',
      );
    });
  });

  group('headline', () {
    test('is null when a Tap to Pay reader is present and not complaining', () {
      expect(_diag(readers: const [_tapToPayReady]).headline, isNull);
    });

    test('reports an empty reader list as its own distinct failure', () {
      final headline = _diag().headline;
      expect(headline, isNotNull);
      expect(headline, contains('has not created a Tap to Pay reader'));
    });

    test('distinguishes "no Tap to Pay reader" from "no readers at all"', () {
      final headline = _diag(
        readers: const [
          TapToPayReaderLine(model: 'contactlessAndChip', status: 'ready'),
        ],
      ).headline;
      expect(headline, contains('not a Tap to Pay one'));
    });

    test('a live reason outranks the absence of a reader', () {
      // An empty list plus a remembered reason means the callback saw the
      // refusal; the reason is the more specific answer, so it wins.
      expect(
        _diag(lastUnavailableReason: 'tapToPayIsNotLinked').headline,
        contains('Apple Account'),
      );
    });

    test('the live reader beats a stale remembered reason', () {
      final d = _diag(
        readers: const [
          TapToPayReaderLine(
            model: 'tapToPay',
            status: 'readerUnavailable',
            unavailableReason: 'notConnectedToInternet',
          ),
        ],
        lastUnavailableReason: 'tapToPayIsNotLinked',
      );
      expect(d.effectiveReason, 'notConnectedToInternet');
      expect(d.headline, contains('internet'));
    });
  });

  group('toReport', () {
    test('always carries the raw reason, not only the explanation', () {
      // The sentence is for the cashier; the enum name is what gets pasted
      // into a bug report and matched against Square's docs.
      final report = _diag(
        readers: const [
          TapToPayReaderLine(
            model: 'tapToPay',
            status: 'readerUnavailable',
            unavailableReason: 'hostIdMismatch',
            id: 'r1',
            name: 'Tap to Pay',
          ),
        ],
      ).toReport();
      expect(report, contains('hostIdMismatch'));
      expect(report, contains('r1'));
    });

    test('prints absent values rather than omitting the line', () {
      // A missing app id is evidence. A report that silently drops the row
      // reads as though the question was never asked.
      final report = _diag().toReport();
      expect(report, contains('square app id: —'));
      expect(report, contains('card processing activated: —'));
      expect(report, contains('readers (0):'));
      expect(report, contains('(none)'));
    });

    test('includes values that were collected', () {
      final report = _diag(
        applicationId: 'sq0idp-abc',
        cardProcessingActivated: true,
        eligibilityMessage: 'Connect Square first',
      ).toReport();
      expect(report, contains('square app id: sq0idp-abc'));
      expect(report, contains('card processing activated: true'));
      expect(report, contains('backend message: Connect Square first'));
    });

    test('reports collection failures instead of hiding a partial probe', () {
      final report = _diag(
        errors: const ['getReaders: PlatformException'],
      ).toReport();
      expect(report, contains('errors while collecting:'));
      expect(report, contains('getReaders: PlatformException'));
    });

    test('omits the backend message line when there is none', () {
      expect(_diag().toReport(), isNot(contains('backend message:')));
    });
  });

  group('TapToPayReaderLine', () {
    test('identifies the Tap to Pay reader by model', () {
      expect(_tapToPayReady.isTapToPay, isTrue);
      expect(
        const TapToPayReaderLine(
          model: 'magstripe',
          status: 'ready',
        ).isTapToPay,
        isFalse,
      );
    });

    test(
      'renders reason and identity when present, and skips them when not',
      () {
        expect(_tapToPayReady.toString(), 'tapToPay · ready');
        expect(
          const TapToPayReaderLine(
            model: 'tapToPay',
            status: 'readerUnavailable',
            unavailableReason: 'internalError',
            name: 'Tap to Pay',
            id: 'abc',
          ).toString(),
          'tapToPay · readerUnavailable · reason=internalError · '
          'name=Tap to Pay · id=abc',
        );
      },
    );
  });
}
