import 'dart:ui';

import 'package:fishauctions_application/widgets/fallback_scanner_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  const corners = [
    Offset(10, 10),
    Offset(50, 10),
    Offset(50, 50),
    Offset(10, 50),
  ];
  const label = Barcode(
    rawValue: 'https://auction.fish/qr/7/',
    corners: corners,
  );

  test('keeps a portrait frame on a portrait screen', () {
    final batch = toDetectionBatch(
      const BarcodeCapture(barcodes: [label], size: Size(720, 1280)),
      const Size(400, 800),
    );
    expect(batch.imageSize, const Size(720, 1280));
    expect(batch.barcodes.single.rawValue, 'https://auction.fish/qr/7/');
    expect(batch.barcodes.single.corners, corners);
  });

  test('turns the always-portrait size to match a landscape screen', () {
    final batch = toDetectionBatch(
      const BarcodeCapture(barcodes: [label], size: Size(720, 1280)),
      const Size(800, 400),
    );
    expect(batch.imageSize, const Size(1280, 720));
  });

  test('drops a code without a full corner quad', () {
    final batch = toDetectionBatch(
      const BarcodeCapture(
        barcodes: [
          Barcode(rawValue: 'x', corners: [Offset.zero]),
        ],
        size: Size(720, 1280),
      ),
      const Size(400, 800),
    );
    expect(batch.barcodes, isEmpty);
  });
}
