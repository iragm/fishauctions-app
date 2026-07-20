import 'package:fishauctions_application/models/checkin_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CheckinAction', () {
    test('parses each known action type', () {
      final join = CheckinAction.tryParse(const {
        'type': 'join_offer',
        'auction': 'spring-auction',
        'title': 'Spring Auction',
        'message': 'Welcome to the Spring Auction.',
        'rules_url': '/auctions/spring-auction/',
      })!;
      expect(join.type, CheckinActionType.joinOffer);
      expect(join.auctionSlug, 'spring-auction');
      expect(join.rulesUrl, '/auctions/spring-auction/');

      final checked = CheckinAction.tryParse(const {
        'type': 'checked_in',
        'auction': 'spring-auction',
        'message': "Welcome to Spring Auction — you're all checked in!",
      })!;
      expect(checked.type, CheckinActionType.checkedIn);
      expect(checked.title, '');
      expect(checked.rulesUrl, isNull);

      final setLocation = CheckinAction.tryParse(const {
        'type': 'set_location_offer',
        'auction': 'spring-auction',
        'title': 'Spring Auction',
      })!;
      expect(setLocation.type, CheckinActionType.setLocationOffer);
      expect(setLocation.message, '');
    });

    test('skips unknown types and malformed entries', () {
      // A newer backend's action type must be ignored, not crash the batch.
      expect(
        CheckinAction.tryParse(const {'type': 'raffle_offer', 'auction': 'x'}),
        isNull,
      );
      expect(CheckinAction.tryParse(const {'type': 'join_offer'}), isNull);
      expect(CheckinAction.tryParse('junk'), isNull);
      expect(
        CheckinAction.tryParse(const {'type': 'join_offer', 'auction': ''}),
        isNull,
      );
    });

    test('dedupe key is per type and auction', () {
      final a = CheckinAction.tryParse(const {
        'type': 'join_offer',
        'auction': 'spring',
      })!;
      final b = CheckinAction.tryParse(const {
        'type': 'checked_in',
        'auction': 'spring',
      })!;
      expect(a.key, isNot(b.key));
      expect(a.key, 'joinOffer:spring');
    });
  });

  group('CheckinJoinResult', () {
    test('parses defensively', () {
      final result = CheckinJoinResult.fromJson(const {
        'joined': true,
        'checked_in': true,
        'rules_url': '/auctions/spring/',
      });
      expect(result.joined, isTrue);
      expect(result.checkedIn, isTrue);
      expect(result.rulesUrl, '/auctions/spring/');

      final empty = CheckinJoinResult.fromJson(const {});
      expect(empty.joined, isFalse);
      expect(empty.checkedIn, isFalse);
      expect(empty.rulesUrl, isNull);
    });
  });
}
