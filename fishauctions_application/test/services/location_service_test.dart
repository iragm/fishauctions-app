import 'package:fishauctions_application/services/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocationService.isLocationAwarePath', () {
    test('matches the auctions and lots list and detail pages', () {
      expect(LocationService.isLocationAwarePath('/auctions/'), isTrue);
      expect(LocationService.isLocationAwarePath('/auctions/spring/'), isTrue);
      expect(LocationService.isLocationAwarePath('/lots/all/'), isTrue);
      expect(LocationService.isLocationAwarePath('/lots/watched/'), isTrue);
      expect(
        LocationService.isLocationAwarePath('/lots/123/angelfish/'),
        isTrue,
      );
    });

    test('does not match the home page or unrelated screens', () {
      // The home page must never trigger a prompt at app open.
      expect(LocationService.isLocationAwarePath('/'), isFalse);
      expect(LocationService.isLocationAwarePath('/clubs/'), isFalse);
      expect(LocationService.isLocationAwarePath('/selling/'), isFalse);
      expect(LocationService.isLocationAwarePath('/accounts/login/'), isFalse);
    });
  });

  group('LocationService.formatCoordinate', () {
    test('renders a plain decimal string the server can float()', () {
      expect(LocationService.formatCoordinate(45.1234), '45.1234');
      expect(LocationService.formatCoordinate(-73.5), '-73.5');
    });

    test('keeps a whole-number coordinate parseable as a float', () {
      // float("45.0") is valid server-side; a bare "45" would be too.
      expect(double.parse(LocationService.formatCoordinate(45)), 45);
    });

    test('round-trips through a double without quoting or JSON', () {
      const lat = 37.7749295;
      const lng = -122.4194155;
      expect(double.parse(LocationService.formatCoordinate(lat)), lat);
      expect(double.parse(LocationService.formatCoordinate(lng)), lng);
    });
  });
}
