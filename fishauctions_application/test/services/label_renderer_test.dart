import 'dart:convert';

import 'package:fishauctions_application/models/label_data.dart';
import 'package:fishauctions_application/services/label_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

LabelData _label({
  String lotNumber = 'A-12',
  String title = 'Angelfish',
  String quantity = '1',
  String minimumBid = '5.00',
  String buyNowPrice = '20.00',
  String seller = 'jdoe',
  String auction = 'Spring',
  String category = 'Cichlids',
  bool iBredThisFish = false,
  String customField1 = '',
}) => LabelData(
  lotPk: 1,
  lotNumber: lotNumber,
  title: title,
  quantity: quantity,
  minimumBid: minimumBid,
  buyNowPrice: buyNowPrice,
  seller: seller,
  auction: auction,
  category: category,
  iBredThisFish: iBredThisFish,
  customField1: customField1,
);

String _render(LabelData d) => latin1.decode(LabelRenderer.renderTspl(d));

void main() {
  group('LabelRenderer.renderTspl', () {
    test('emits a well-formed TSPL document', () {
      final out = _render(_label());
      expect(out, contains('SIZE 3,2'));
      expect(out, contains('CLS'));
      expect(out, contains('PRINT 1,1'));
      expect(out, endsWith('\r\n'));
      // TSPL commands are CRLF-separated.
      expect(out.contains('\r\n'), isTrue);
    });

    test('prints the lot number and a scannable barcode of it', () {
      final out = _render(_label(lotNumber: 'Z-99'));
      expect(out, contains('"Z-99"'));
      expect(out, contains('BARCODE 16,286,"128",90,1,0,2,4,"Z-99"'));
    });

    test('omits the barcode when there is no lot number', () {
      final out = _render(_label(lotNumber: ''));
      expect(out, isNot(contains('BARCODE')));
    });

    test('omits empty / zero-value fields', () {
      final out = _render(
        _label(seller: '', buyNowPrice: '0.00', category: ''),
      );
      expect(out, isNot(contains('Seller:')));
      expect(out, isNot(contains('BNP')));
      expect(out, contains(r'Min $5.00'));
    });

    test('marks bred fish', () {
      expect(_render(_label(iBredThisFish: true)), contains('BRED'));
      expect(_render(_label()), isNot(contains('BRED')));
    });

    test('neutralises quotes so they cannot break the TSPL string', () {
      final out = _render(_label(title: 'The "Best" Fish'));
      // The embedded double quotes must be gone (replaced with single quotes)
      // so they can't terminate the quoted TSPL string early.
      expect(out, contains("The 'Best' Fish"));
      expect(out, isNot(contains('"Best"')));
    });

    test('replaces characters outside latin1', () {
      final out = _render(_label(title: 'Béta 🐟 fish'));
      // latin1-safe accented char survives; the emoji becomes '?'.
      expect(out, contains('Béta ? fish'));
    });

    test('truncates overly long fields', () {
      final longTitle = 'x' * 100;
      final out = _render(_label(title: longTitle));
      expect(out, isNot(contains('x' * 29))); // capped below 29 chars
      expect(out, contains('x' * 28));
    });
  });
}
