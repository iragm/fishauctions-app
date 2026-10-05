import 'package:fishauctions_application/config/environment.dart';
import 'package:fishauctions_application/utils/web_microphone.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uri site(String pathAndQuery) =>
      Uri.parse('${EnvironmentConfig.webBaseUrl}$pathAndQuery');

  test('set lot winners may open the microphone', () {
    expect(
      allowsWebMicrophone(site('/auctions/spring-26/lots/set-winners/')),
      isTrue,
    );
    expect(
      allowsWebMicrophone(site('/auctions/spring-26/lots/set-winners')),
      isTrue,
    );
    // A query string doesn't change which page it is.
    expect(
      allowsWebMicrophone(site('/auctions/spring-26/lots/set-winners/?x=1')),
      isTrue,
    );
  });

  test('no other page may', () {
    for (final path in [
      '/',
      '/lots/123/',
      '/auctions/spring-26/',
      '/auctions/spring-26/lots/set-winners/voice-log/',
      '/auctions/spring-26/lots/set-winners/undo/',
      '/auctions/a/b/lots/set-winners/',
    ]) {
      expect(allowsWebMicrophone(site(path)), isFalse, reason: path);
    }
  });

  test('another host may not, even on the same path', () {
    expect(
      allowsWebMicrophone(
        Uri.parse('https://example.com/auctions/x/lots/set-winners/'),
      ),
      isFalse,
    );
    expect(allowsWebMicrophone(null), isFalse);
    expect(
      allowsWebMicrophone(Uri.parse('data:text/html,set-winners')),
      isFalse,
    );
  });
}
