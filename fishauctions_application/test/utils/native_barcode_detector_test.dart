import 'dart:convert';

import 'package:fishauctions_application/utils/native_barcode_detector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fishauctions.app/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final jpeg = base64Encode([0xFF, 0xD8, 0xFF, 0xD9]);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('NativeBarcodeDetector.handle', () {
    test(
      'passes the image and only supported formats to the native reader',
      () async {
        MethodCall? seen;
        messenger.setMockMethodCallHandler(channel, (call) async {
          seen = call;
          return [
            {
              'rawValue': 'https://auction.fish/qr/12/',
              'format': 'qr_code',
              'corners': [
                [0.1, 0.2],
                [0.3, 0.2],
                [0.3, 0.4],
                [0.1, 0.4],
              ],
            },
          ];
        });
        final answer = await NativeBarcodeDetector.handle([
          {
            'image': jpeg,
            'formats': ['qr_code', 'code_128', 'made_up', 7],
          },
        ]);
        expect(seen?.method, 'detectBarcodes');
        final args = seen!.arguments as Map;
        expect(args['bytes'], [0xFF, 0xD8, 0xFF, 0xD9]);
        expect(args['formats'], ['qr_code', 'code_128']);
        expect(answer['error'], isNull);
        final barcodes = answer['barcodes']! as List;
        expect(barcodes, hasLength(1));
        final first = barcodes.single as Map;
        expect(first['rawValue'], 'https://auction.fish/qr/12/');
        expect(first['format'], 'qr_code');
        expect((first['corners'] as List).first, [0.1, 0.2]);
      },
    );

    test('drops malformed native results instead of passing them on', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => [
          'not a map',
          {
            'rawValue': 'X',
            'corners': [
              [0.1],
              ['a', 'b'],
              [0.5, 0.5],
            ],
          },
        ],
      );
      final answer = await NativeBarcodeDetector.handle([
        {'image': jpeg, 'formats': <String>[]},
      ]);
      final barcodes = answer['barcodes']! as List;
      expect(barcodes, hasLength(1));
      final only = barcodes.single as Map;
      expect(only['format'], 'unknown');
      expect(only['corners'], [
        [0.5, 0.5],
      ]);
    });

    test(
      'never throws: bad requests and reader failures resolve empty',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'detect_failed', message: 'boom');
        });
        for (final args in <List<dynamic>>[
          [],
          ['a string'],
          [
            {'image': ''},
          ],
          [
            {'image': 'not base64!!'},
          ],
          [
            {'image': jpeg},
          ],
        ]) {
          final answer = await NativeBarcodeDetector.handle(args);
          expect(answer['barcodes'], isEmpty, reason: '$args');
          expect(answer['error'], isNotNull, reason: '$args');
        }
      },
    );

    test(
      'a build without the native reader answers with nothing found',
      () async {
        final answer = await NativeBarcodeDetector.handle([
          {'image': jpeg},
        ]);
        expect(answer['barcodes'], isEmpty);
        expect(answer['error'], isNull);
      },
    );
  });

  test('the script stands aside when the engine has a BarcodeDetector', () {
    final source = NativeBarcodeDetector.userScript.source;
    expect(source, contains("if ('BarcodeDetector' in window) { return; }"));
    expect(source, contains("callHandler('barcodeDetect'"));
    expect(NativeBarcodeDetector.userScript.forMainFrameOnly, isTrue);
  });
}
