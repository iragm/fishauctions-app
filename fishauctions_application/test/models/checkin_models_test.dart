import 'package:fishauctions_application/models/checkin_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _bidderNumberTests();
  _notificationPayloadTests();
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

// The bidder number is the single fact a just-arrived bidder needs, and the
// app used to drop it on the floor — the backend has always sent it.
void _bidderNumberTests() {
  group('CheckinJoinResult carries the bidder number', () {
    test('reads it from the join response', () {
      final result = CheckinJoinResult.fromJson({
        'joined': true,
        'checked_in': true,
        'bidder_number': '42',
        'rules_url': '/auctions/spring/',
      });
      expect(result.joined, isTrue);
      expect(result.checkedIn, isTrue);
      expect(result.bidderNumber, '42');
    });

    // AuctionTOS.bidder_number is a CharField and is routinely text.
    test('keeps a non-numeric number as written', () {
      expect(
        CheckinJoinResult.fromJson({
          'joined': true,
          'bidder_number': 'BOB-1',
        }).bidderNumber,
        'BOB-1',
      );
    });

    test('an absent or blank number is null, not an empty string', () {
      expect(CheckinJoinResult.fromJson({'joined': true}).bidderNumber, isNull);
      expect(
        CheckinJoinResult.fromJson({
          'joined': true,
          'bidder_number': '',
        }).bidderNumber,
        isNull,
      );
      expect(
        CheckinJoinResult.fromJson({
          'joined': true,
          'bidder_number': '   ',
        }).bidderNumber,
        isNull,
      );
    });
  });
}

// A nudge is now delivered as a tray notification rather than drawn over
// whatever screen is up, so it has to survive the round trip through the
// payload — including a tap the OS delivers after the process that posted it
// has been killed.
void _notificationPayloadTests() {
  group('CheckinAction notification payload', () {
    const actions = [
      CheckinAction(
        type: CheckinActionType.joinOffer,
        auctionSlug: 'spring-auction',
        title: 'Spring Auction',
        message: 'Welcome to the Spring Auction.',
        rulesUrl: '/auctions/spring-auction/',
      ),
      CheckinAction(
        type: CheckinActionType.checkedIn,
        auctionSlug: 'spring-auction',
        title: 'Spring Auction',
        message: 'You\'re checked in! Your bidder number is BOB-1.',
      ),
      CheckinAction(
        type: CheckinActionType.setLocationOffer,
        auctionSlug: 'spring-auction',
        title: 'Spring Auction',
        message: 'Use this phone\'s position.',
      ),
    ];

    test('round-trips every action type unchanged', () {
      for (final action in actions) {
        final back = CheckinAction.fromNotificationPayload(
          action.notificationPayload,
        );
        expect(back, isNotNull, reason: '${action.type} did not survive');
        expect(back!.type, action.type);
        expect(back.auctionSlug, action.auctionSlug);
        expect(back.title, action.title);
        expect(back.message, action.message);
        expect(back.rulesUrl, action.rulesUrl);
      }
    });

    test('the payload is the server shape, so tryParse reads it directly', () {
      expect(actions.first.toJson()['type'], 'join_offer');
      expect(actions[1].toJson()['type'], 'checked_in');
      expect(actions[2].toJson()['type'], 'set_location_offer');
      // No rules_url on the wire when there isn't one, rather than a null.
      expect(actions[1].toJson().containsKey('rules_url'), isFalse);
    });

    test('junk and unknown types decode to null instead of throwing', () {
      expect(CheckinAction.fromNotificationPayload('not json'), isNull);
      expect(CheckinAction.fromNotificationPayload('[]'), isNull);
      expect(
        CheckinAction.fromNotificationPayload(
          '{"type":"invented_later","auction":"x"}',
        ),
        isNull,
      );
    });

    test('the id is stable, positive, and distinct per action', () {
      for (final action in actions) {
        expect(action.notificationId, greaterThanOrEqualTo(0));
        expect(action.notificationId, action.notificationId);
      }
      // Same auction, different nudge — must not replace each other in the
      // tray: an admin can get a join offer and a location offer at once.
      expect(
        actions.map((a) => a.notificationId).toSet().length,
        actions.length,
      );
    });
  });
}
