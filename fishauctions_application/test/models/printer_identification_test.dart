import 'dart:convert';

import 'package:fishauctions_application/models/printer_device_info.dart';
import 'package:fishauctions_application/models/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// A profile row as the backend serves it, with only the matching bits filled
/// in — everything else defaults.
PrinterProfile _profile(
  String slug, {
  List<String> names = const [],
  List<String> models = const [],
  List<String> manufacturers = const [],
  String service = '',
  List<dynamic> printProgram = const [],
}) => parsePrinterProfiles(
  jsonEncode({
    'profiles': [
      {
        'slug': slug,
        'name': slug,
        'schema_version': 1,
        'match': {
          'ble_name_patterns': names,
          'model_patterns': models,
          'manufacturer_patterns': manufacturers,
          'service_uuid': service,
        },
        'print_program': printProgram,
      },
    ],
  }),
).single;

/// A profile whose print program is unmistakably one language, so
/// [matchProfileForLanguage] has something to read.
PrinterProfile _speaking(
  String slug,
  String language, {
  List<String> names = const ['^x'],
}) => _profile(
  slug,
  names: names,
  printProgram: switch (language) {
    'tspl' => [
      {'tx_text': 'SIZE {width_mm} mm,{height_mm} mm\r\nBITMAP 0,0,'},
    ],
    'escpos' => [
      {'tx': '1d 76 30 00 {u16le:width_bytes} {u16le:height_px}'},
    ],
    'zpl' => [
      {'tx_text': '^XA^GFA,'},
    ],
    _ => throw ArgumentError(language),
  },
);

void main() {
  group('normalizeGattUuid', () {
    test('reduces the 128-bit form of a SIG uuid to its 16 bits', () {
      expect(normalizeGattUuid('0000180A-0000-1000-8000-00805F9B34FB'), '180a');
      expect(normalizeGattUuid('180A'), '180a');
    });

    test('leaves a vendor uuid alone apart from case', () {
      expect(
        normalizeGattUuid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E'),
        '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      );
    });

    test('matches uuids written in either form', () {
      const info = PrinterDeviceInfo(bleName: 'x', serviceUuids: ['18f0']);
      expect(info.hasService('000018f0-0000-1000-8000-00805f9b34fb'), isTrue);
      expect(info.hasService('18F0'), isTrue);
      expect(info.hasService('180a'), isFalse);
    });
  });

  group('profile matching', () {
    test('an unparsed match section leaves the pattern lists empty', () {
      final profile = _profile('bare');
      expect(profile.modelPatterns, isEmpty);
      expect(profile.manufacturerPatterns, isEmpty);
      expect(
        profile.matchesDeviceInfo(
          const PrinterDeviceInfo(bleName: 'x', model: 'anything'),
        ),
        isFalse,
      );
    });

    test('matches the printer-reported model', () {
      final profile = _profile('d11s', models: ['^d11']);
      expect(
        profile.matchesDeviceInfo(
          const PrinterDeviceInfo(bleName: 'Bob', model: 'D11S'),
        ),
        isTrue,
      );
    });

    test('matches the manufacturer when the model says nothing', () {
      final profile = _profile('d11s', manufacturers: ['aiyin']);
      expect(
        profile.matchesDeviceInfo(
          const PrinterDeviceInfo(bleName: 'Bob', manufacturer: 'AiYin Tech'),
        ),
        isTrue,
      );
    });

    test('an invalid regex never matches instead of throwing', () {
      final profile = _profile('broken', models: ['*nope(']);
      expect(
        profile.matchesDeviceInfo(
          const PrinterDeviceInfo(bleName: 'x', model: '*nope('),
        ),
        isFalse,
      );
    });

    test('a device that reports nothing matches nothing', () {
      final profile = _profile('d11s', models: ['^d11'], manufacturers: ['a']);
      expect(
        profile.matchesDeviceInfo(const PrinterDeviceInfo(bleName: 'D11')),
        isFalse,
      );
    });
  });

  group('matchProfileForDeviceInfo', () {
    final aiyin = _profile('d11s-aiyin', models: ['^d11'], service: '18f0');
    final lujiang = _profile('d11s-lujiang', service: '18f0');
    final escpos = _profile('escpos-raster');

    test('model patterns win, in profile order', () {
      final result = matchProfileForDeviceInfo([
        aiyin,
        lujiang,
        escpos,
      ], const PrinterDeviceInfo(bleName: 'renamed', model: 'D11S'));
      expect(result?.$1.slug, 'd11s-aiyin');
      expect(result?.$2, ProfileMatch.deviceInfo);
    });

    test('falls back to a service uuid only one profile claims', () {
      final result = matchProfileForDeviceInfo([
        aiyin,
        escpos,
      ], const PrinterDeviceInfo(bleName: 'renamed', serviceUuids: ['18f0']));
      expect(result?.$1.slug, 'd11s-aiyin');
      expect(result?.$2, ProfileMatch.serviceUuid);
    });

    test('a service uuid two profiles claim is not enough to guess', () {
      // The AiYin and LuJiang D11s boards share 18f0 but speak differently;
      // picking one at random would print garbage. Ask the user instead.
      final result = matchProfileForDeviceInfo([
        aiyin,
        lujiang,
      ], const PrinterDeviceInfo(bleName: 'renamed', serviceUuids: ['18f0']));
      expect(result, isNull);
    });

    test('a printer that says nothing usable is left to the user', () {
      expect(
        matchProfileForDeviceInfo([
          aiyin,
          lujiang,
          escpos,
        ], const PrinterDeviceInfo(bleName: 'Mystery Printer')),
        isNull,
      );
    });
  });

  group('isGenericFallback', () {
    test('a profile declaring no way to be recognised is a fallback', () {
      expect(_profile('raw').isGenericFallback, isTrue);
    });

    test('any one identifying signal is enough to not be a fallback', () {
      expect(_profile('a', names: ['^d11']).isGenericFallback, isFalse);
      expect(_profile('b', models: ['^y486']).isGenericFallback, isFalse);
      expect(
        _profile('c', manufacturers: ['aiyin']).isGenericFallback,
        isFalse,
      );
      expect(_profile('d', service: '18f0').isGenericFallback, isFalse);
    });
  });

  group('matchProfileForLanguage', () {
    test('picks the only profile speaking the language', () {
      final profiles = [_speaking('tspl-a', 'tspl'), _speaking('zpl-a', 'zpl')];
      expect(matchProfileForLanguage(profiles, 'tspl')?.slug, 'tspl-a');
      expect(matchProfileForLanguage(profiles, 'zpl')?.slug, 'zpl-a');
    });

    test('two profiles speaking it is a real question for the user', () {
      final profiles = [
        _speaking('tspl-a', 'tspl'),
        _speaking('tspl-b', 'tspl'),
      ];
      expect(matchProfileForLanguage(profiles, 'tspl'), isNull);
    });

    test('a language nothing speaks matches nothing', () {
      expect(matchProfileForLanguage([_speaking('a', 'tspl')], 'cpcl'), isNull);
      expect(matchProfileForLanguage([_speaking('a', 'tspl')], null), isNull);
      expect(matchProfileForLanguage([_speaking('a', 'tspl')], ''), isNull);
    });

    test('the generic fallback is never auto-selected by language', () {
      // The regression this guards: escpos-raster is the only ESC/POS profile,
      // so "exactly one speaks it" would hand it every printer that answers
      // DLE EOT — driven at that row's placeholder 384px head, with no GATT
      // ids, silently.
      final fallback = _profile(
        'escpos-raster',
        printProgram: const [
          {'tx': '1d 76 30 00 {u16le:width_bytes} {u16le:height_px}'},
        ],
      );
      expect(fallback.isGenericFallback, isTrue);
      expect(fallback.inferredLanguage, 'escpos');
      expect(matchProfileForLanguage([fallback], 'escpos'), isNull);
    });

    test('a real ESC/POS profile alongside the fallback still matches', () {
      // The exclusion must not make ESC/POS unmatchable — only unmatchable
      // *by the placeholder row*.
      final profiles = [
        _profile(
          'escpos-raster',
          printProgram: const [
            {'tx': '1d 76 30 00 {u16le:width_bytes}'},
          ],
        ),
        _speaking('real-escpos', 'escpos', names: ['^acme']),
      ];
      expect(matchProfileForLanguage(profiles, 'escpos')?.slug, 'real-escpos');
    });
  });

  group('PrinterDeviceInfo', () {
    test('isEmpty tracks whether the printer identified itself at all', () {
      expect(
        const PrinterDeviceInfo(bleName: 'x', serviceUuids: ['18f0']).isEmpty,
        isTrue,
      );
      expect(
        const PrinterDeviceInfo(bleName: 'x', model: 'D11S').isEmpty,
        isFalse,
      );
    });

    test('summary lists only what was reported', () {
      const info = PrinterDeviceInfo(
        bleName: 'D11-1234',
        manufacturer: 'AiYin',
        serviceUuids: ['18f0', '180a'],
      );
      expect(
        info.summary,
        'Name: D11-1234\nManufacturer: AiYin\nServices: 18f0, 180a',
      );
    });

    test('toJson omits fields the printer never gave us', () {
      const info = PrinterDeviceInfo(bleName: 'D11-1234', model: 'D11S');
      expect(info.toJson(), {
        'ble_name': 'D11-1234',
        'model': 'D11S',
        'service_uuids': <String>[],
      });
    });
  });
}
