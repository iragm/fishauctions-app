import 'package:fishauctions_application/models/tap_to_pay_status.dart';
import 'package:fishauctions_application/services/tap_to_pay_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// `TapToPayService`'s reader-status plumbing, on an SDK that was never
/// initialized — the state every process starts in, and the one that ends the
/// Android process if anything reaches the plugin (see
/// `square_payment_service_test.dart` for the mechanism). No mock channel
/// handler is installed here on purpose: a call that reached the channel would
/// throw `MissingPluginException` and fail the test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = TapToPayService.instance;

  test('the reader status starts unknown, which renders as busy', () {
    expect(service.status.value, TapToPayReaderStatus.unknown);
    expect(service.status.value.isBusy, isTrue);
    expect(service.status.value.isReady, isFalse);
  });

  test('syncing from the reader list is safe before initialization', () async {
    // It reads `getReaders()`, which answers an empty list rather than touching
    // the plugin. An empty list is "nothing to report", not "unavailable" — the
    // charge path must not be told the reader is broken because the SDK simply
    // isn't up yet.
    await expectLater(service.syncStatusFromReaders(), completes);
    expect(service.status.value, TapToPayReaderStatus.unknown);
    expect(service.lastUnavailableReason, isNull);
  });

  test('subscribing to the reader is declined, not attempted', () {
    // Nothing to subscribe to, and the seeding read it now performs must not
    // change that.
    service.listenToReader();
    expect(service.status.value, TapToPayReaderStatus.unknown);
  });
}
