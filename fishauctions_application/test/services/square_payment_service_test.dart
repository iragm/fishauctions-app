import 'package:fishauctions_application/services/square_payment_service.dart';
import 'package:fishauctions_application/utils/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards on `SquarePaymentService` that exist to stop the app calling Square
/// before `MobilePaymentsSdk.initialize()`.
///
/// This is not a style preference and cannot be replaced by a `try`/`catch`.
/// Every Square plugin module on Android holds its manager in a
/// `companion object` property, so the first call made before initialization
/// throws inside a static initializer; the JVM rewraps that as
/// `ExceptionInInitializerError`, which is an `Error`, and Flutter's
/// `MethodChannel` handler catches only `RuntimeException`. It reaches the
/// Android main thread and ends the process with nothing crossing the channel
/// for Dart to catch. The only defence is not making the call — so what these
/// tests actually assert is that **no platform channel is touched**, which is
/// why they pass with no mock handler installed at all: a call that reached the
/// channel would throw `MissingPluginException` here and fail the test.
///
/// The bug that prompted them: the website's command palette offers
/// `fishauctions://tap-to-pay` to Android too, the shell pushed the iOS-only
/// setup screen, and the screen asked for the authorization state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final square = SquarePaymentService.instance;

  test('starts uninitialized, since nothing has called initializeSquare', () {
    expect(PlatformBridge.squareInitialized, isFalse);
    expect(square.isInitialized, isFalse);
  });

  test('an uninitialized SDK holds no authorization', () async {
    await expectLater(square.isAuthorized, completion(isFalse));
  });

  test('an uninitialized SDK reports no readers and no location', () async {
    await expectLater(square.readers(), completion(isEmpty));
    await expectLater(square.authorizedLocation(), completion(isNull));
  });

  test('an uninitialized SDK has no environment to report', () async {
    await expectLater(square.environment(), completion(isNull));
  });

  test('a reader subscription is refused rather than attempted', () {
    expect(square.onReaderChanged((_) {}), isNull);
  });

  test('deauthorize is a no-op — this is the sign-out path', () async {
    // AuthService releases the Square authorization on every logout, inside a
    // `try`/`catch` that could never have caught the crash above. On a
    // deployment serving no Square application id that made signing out on
    // Android fatal.
    await expectLater(square.deauthorize(), completes);
  });

  test('the mock reader overlay is not driven before initialization', () async {
    await expectLater(square.showMockReaderUI(), completes);
    await expectLater(square.hideMockReaderUI(), completes);
  });
}
