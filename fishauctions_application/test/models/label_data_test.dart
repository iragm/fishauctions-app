import 'package:fishauctions_application/models/label_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LabelData.fromResponse', () {
    test('parses a full response', () {
      final data = LabelData.fromResponse({
        'label_data': {
          'lot_number': 'A-12',
          'title': 'Pair of Angelfish',
          'quantity': 2,
          'minimum_bid': '5.00',
          'buy_now_price': '20.00',
          'seller': 'jdoe',
          'auction': 'Spring Auction',
          'category': 'Cichlids',
          'i_bred_this_fish': true,
          'custom_field_1': 'tank 4',
        },
        'metadata': {'lot_pk': 42},
      });

      expect(data.lotPk, 42);
      expect(data.lotNumber, 'A-12');
      expect(data.title, 'Pair of Angelfish');
      expect(data.quantity, '2');
      expect(data.minimumBid, '5.00');
      expect(data.seller, 'jdoe');
      expect(data.iBredThisFish, isTrue);
      expect(data.customField1, 'tank 4');
    });

    test('coerces mixed/loose types from the backend', () {
      final data = LabelData.fromResponse({
        'label_data': {
          'lot_number': 7, // int, not string
          'i_bred_this_fish': 1, // truthy int
          'minimum_bid': 5, // numeric
        },
      });

      expect(data.lotNumber, '7');
      expect(data.iBredThisFish, isTrue);
      expect(data.minimumBid, '5');
      // Absent fields default to empty / false.
      expect(data.title, '');
      expect(data.iBredThisFish, isTrue);
      expect(data.lotPk, isNull);
    });

    test('treats string/zero falsey values correctly', () {
      final data = LabelData.fromResponse({
        'label_data': {'i_bred_this_fish': 'false'},
      });
      expect(data.iBredThisFish, isFalse);
    });

    test('throws when label_data is missing', () {
      expect(
        () => LabelData.fromResponse({'metadata': {}}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
