import 'package:fishauctions_application/models/tap_to_pay_status.dart';
import 'package:fishauctions_application/services/tap_to_pay_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:square_mobile_payments_sdk/square_mobile_payments_sdk.dart';

void main() {
  group('TapToPayReaderStatus.fromSquare', () {
    test('ready maps to ready', () {
      expect(
        TapToPayReaderStatus.fromSquare(ReaderStatusInfoStatus.ready, null),
        TapToPayReaderStatus.ready,
      );
    });

    test('both connecting states are the configuration progress', () {
      // Apple's 3.9.1 wants a progress indicator while the reader configures;
      // Square splits that into connecting-to-device and connecting-to-Square,
      // and the UI must not treat either as a failure.
      for (final status in [
        ReaderStatusInfoStatus.connectingToDevice,
        ReaderStatusInfoStatus.connectingToSquare,
      ]) {
        expect(
          TapToPayReaderStatus.fromSquare(status, null),
          TapToPayReaderStatus.preparing,
          reason: '$status should read as still preparing',
        );
      }
    });

    test('unavailable and faulty map to unavailable', () {
      expect(
        TapToPayReaderStatus.fromSquare(
          ReaderStatusInfoStatus.readerUnavailable,
          ReaderStatusInfoUnavailableReason.tapToPayIsNotLinked,
        ),
        TapToPayReaderStatus.unavailable,
      );
      expect(
        TapToPayReaderStatus.fromSquare(ReaderStatusInfoStatus.faulty, null),
        TapToPayReaderStatus.unavailable,
      );
    });

    test('no status yet is unknown, and unknown still shows a spinner', () {
      // At launch nothing has reported. Rendering that as a failure would
      // accuse a perfectly good reader of being broken.
      expect(
        TapToPayReaderStatus.fromSquare(null, null),
        TapToPayReaderStatus.unknown,
      );
      expect(TapToPayReaderStatus.unknown.isBusy, isTrue);
      expect(TapToPayReaderStatus.unknown.isReady, isFalse);
      expect(TapToPayReaderStatus.unavailable.isBusy, isFalse);
      expect(TapToPayReaderStatus.ready.isBusy, isFalse);
    });
  });

  group('TapToPayEligibility.fromJson', () {
    test('parses a full merchant payload', () {
      final e = TapToPayEligibility.fromJson(const {
        'eligible': true,
        'can_accept_terms': true,
        'access_token': 'tok',
        'location_id': 'LOC1',
        'seller_name': 'Fish Club',
      });
      expect(e.eligible, isTrue);
      expect(e.canAcceptTerms, isTrue);
      expect(e.sellerName, 'Fish Club');
      expect(e.canCharge, isTrue);
    });

    test('an eligible user with no credentials cannot warm the reader', () {
      // The backend may say "yes, a merchant" while declining to issue a
      // token. That must not be mistaken for something we can authorize with.
      final e = TapToPayEligibility.fromJson(const {
        'eligible': true,
        'can_accept_terms': true,
      });
      expect(e.eligible, isTrue);
      expect(e.canCharge, isFalse);
    });

    test('empty credential strings count as absent', () {
      final e = TapToPayEligibility.fromJson(const {
        'eligible': true,
        'can_accept_terms': true,
        'access_token': '',
        'location_id': 'LOC1',
      });
      expect(e.accessToken, isNull);
      expect(e.canCharge, isFalse);
    });

    test('missing flags default to not eligible', () {
      final e = TapToPayEligibility.fromJson(const {});
      expect(e.eligible, isFalse);
      expect(e.canAcceptTerms, isFalse);
      expect(e.canCharge, isFalse);
      expect(e.message, isNull);
    });

    test('a non-admin gets the server-authored explanation', () {
      // Requirement 3.8.1 — the copy is the server's so it can change without
      // an app release.
      final e = TapToPayEligibility.fromJson(const {
        'eligible': false,
        'can_accept_terms': false,
        'message': 'Ask Dave to connect Square.',
      });
      expect(e.canAcceptTerms, isFalse);
      expect(e.message, 'Ask Dave to connect Square.');
    });
  });

  group('TapToPayService.isBelowOsFloor', () {
    test('versions below 17.6 are treated as needing an iOS update', () {
      // Requirement 1.4 names 17.6 as the boundary.
      for (final v in ['16.0', '16.4', '17.0', '17.5', '17.5.1', '15.7.2']) {
        expect(
          TapToPayService.isBelowOsFloor(v),
          isTrue,
          reason: '$v should be below the floor',
        );
      }
    });

    test('17.6 and later are not an OS problem', () {
      for (final v in ['17.6', '17.6.1', '18.0', '26.1']) {
        expect(
          TapToPayService.isBelowOsFloor(v),
          isFalse,
          reason: '$v should be at or above the floor',
        );
      }
    });

    test('17.10 is above 17.6, not below it', () {
      // The regression a `double.parse("17.10") == 17.1` comparison causes:
      // a current iPhone told to go and update itself.
      expect(TapToPayService.isBelowOsFloor('17.10'), isFalse);
    });

    test('an unreadable version blames the device, not the OS', () {
      // With no evidence the OS is at fault, "update iOS" would be a guess
      // that sends the user somewhere that cannot help them.
      for (final v in ['', 'unknown', 'x.y']) {
        expect(TapToPayService.isBelowOsFloor(v), isFalse);
      }
    });
  });
}
