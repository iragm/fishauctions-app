import 'dart:async';
import 'dart:typed_data';

import 'package:fishauctions_application/models/printer_device_info.dart';
import 'package:fishauctions_application/models/printer_profile.dart';
import 'package:fishauctions_application/services/printer_characterization.dart';
import 'package:fishauctions_application/services/printer_probe.dart';
import 'package:fishauctions_application/services/printer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the TSPL status query with a scripted byte per call, so a whole
/// guided capture can be played out without hardware.
class _FakeTransport implements PrinterTransport {
  _FakeTransport(this.replies);

  /// Status bytes to answer with, in order. A null entry means "say nothing",
  /// which is what a printer that doesn't implement the query does.
  final List<int?> replies;
  int _call = 0;

  final _controller = StreamController<Uint8List>.broadcast();

  @override
  bool get isConnected => true;

  @override
  Stream<Uint8List> get notifications => _controller.stream;

  @override
  Future<void> write(List<int> bytes) async {
    // Only the TSPL status query is answered; everything else is silence,
    // which is what makes `statusQueryName` pick tspl_status.
    if (bytes.length == 3 &&
        bytes[0] == 0x1b &&
        bytes[1] == 0x21 &&
        bytes[2] == 0x3f) {
      final reply = _call < replies.length ? replies[_call] : null;
      _call++;
      if (reply != null) {
        scheduleMicrotask(() {
          if (!_controller.isClosed) {
            _controller.add(Uint8List.fromList([reply]));
          }
        });
      }
    }
  }

  void dispose() => _controller.close();
}

PrinterReply _reply(String hex) => (hex: hex, ascii: '.');

/// A finished capture: `states` maps a step id to the status byte the printer
/// reported in it.
PrinterCharacterizationResult _result(
  Map<String, String> states, {
  Map<String, PrinterReply> probe = const {
    'tspl_status': (hex: '00', ascii: '.'),
  },
  String query = 'tspl_status',
}) => PrinterCharacterizationResult(
  info: const PrinterDeviceInfo(bleName: 'Y486BT', model: 'Y486'),
  probeReplies: probe,
  gatt: const [],
  captures: {
    for (final e in states.entries) e.key: {query: _reply(e.value)},
  },
);

void main() {
  group('derived status values', () {
    test('turns the captured bytes into a status_flags.values map', () {
      // The Y486BT's real answers: the enumeration that a bitmask reading gets
      // wrong, which is the whole reason this flow exists.
      final result = _result({
        'ready': '00',
        'cover_open': '01',
        'no_labels_cover_open': '05',
        'no_labels': '04',
      });
      expect(result.statusValues, {
        '00': <String>[],
        '01': ['cover_open'],
        '05': ['cover_open', 'out_of_paper'],
        '04': ['out_of_paper'],
      });
      expect(result.ambiguities, isEmpty);
    });

    test('states the printer cannot distinguish are reported, not hidden', () {
      // A printer that answers 01 for both "open" and "open and empty" can
      // only ever support the weaker message; whoever writes the profile needs
      // to know that rather than discover it from a support ticket.
      final result = _result({
        'ready': '00',
        'cover_open': '01',
        'no_labels_cover_open': '01',
      });
      expect(result.ambiguities, hasLength(1));
      expect(
        result.ambiguities.single,
        allOf(
          contains('01'),
          contains('cover_open'),
          contains('no_labels_cover_open'),
        ),
      );
    });

    test('a step the printer never answered is absent, never guessed', () {
      final result = PrinterCharacterizationResult(
        info: const PrinterDeviceInfo(bleName: 'x'),
        probeReplies: const {'tspl_status': (hex: '00', ascii: '.')},
        gatt: const [],
        captures: {
          'ready': {'tspl_status': _reply('00')},
          // The user completed the step; the printer said nothing.
          'cover_open': const {},
        },
      );
      expect(result.statusValues, {'00': <String>[]});
    });

    test('a printer that answers nothing at all yields no map', () {
      const result = PrinterCharacterizationResult(
        info: PrinterDeviceInfo(bleName: 'x'),
        probeReplies: {},
        gatt: [],
        captures: {'ready': {}, 'cover_open': {}},
      );
      expect(result.statusQueryName, isNull);
      expect(result.statusValues, isEmpty);
      expect(result.ambiguities, isEmpty);
    });

    test('decodes the query belonging to the language that answered', () {
      // A printer may reply to more than one language's status query; the one
      // matching its probed language is the one whose values mean anything.
      final result = PrinterCharacterizationResult(
        info: const PrinterDeviceInfo(bleName: 'x'),
        probeReplies: const {'escpos_status': (hex: '12', ascii: '.')},
        gatt: const [],
        captures: {
          'ready': {'tspl_status': _reply('00'), 'escpos_status': _reply('12')},
        },
      );
      expect(result.statusQueryName, 'escpos_status');
      expect(result.statusValues, {'12': <String>[]});
    });
  });

  group('report summary', () {
    test('carries everything a profile author needs', () {
      final result = PrinterCharacterizationResult(
        info: const PrinterDeviceInfo(
          bleName: 'Y486BT',
          manufacturer: 'Feasycom',
          model: 'FSC-BT986',
        ),
        probeReplies: const {'tspl_status': (hex: '00', ascii: '.')},
        gatt: const [
          {
            'uuid': '49535343-fe7d-4ae5-8fa9-9fafd205e455',
            'characteristics': [
              {
                'uuid': '49535343-8841-43f4-a8d4-ecbe34729bb3',
                'properties': ['write'],
              },
            ],
          },
        ],
        captures: {
          'ready': {'tspl_status': _reply('00')},
          'cover_open': {'tspl_status': _reply('01')},
        },
      );
      final summary = result.summary;
      // The identity, so the row's match patterns can be written.
      expect(summary, contains('FSC-BT986'));
      // The language, so the print program can be.
      expect(summary, contains('tspl'));
      // The GATT ids, which are otherwise only in a logcat buffer.
      expect(summary, contains('49535343-8841-43f4-a8d4-ecbe34729bb3'));
      // And the derived map, ready to paste.
      expect(summary, contains('Proposed status_flags.values'));
      expect(summary, contains('"01": ["cover_open"]'));
    });

    test('says so plainly when the printer answered nothing', () {
      const result = PrinterCharacterizationResult(
        info: PrinterDeviceInfo(bleName: 'Mystery'),
        probeReplies: {},
        gatt: [],
        captures: {},
      );
      expect(result.summary, contains('answered none of them'));
    });
  });

  group('toJson', () {
    test('sends the captures and the derived map', () {
      final json = _result({'ready': '00', 'cover_open': '01'}).toJson();
      expect(json['probed_language'], 'tspl');
      expect((json['status_captures']! as Map)['cover_open'], {
        'tspl_status': {'hex': '01', 'ascii': '.'},
      });
      expect(json['derived_status_values'], {
        '00': <String>[],
        '01': ['cover_open'],
      });
      expect(json.containsKey('status_ambiguities'), isFalse);
    });

    test('includes ambiguities when there are any', () {
      final json = _result({'ready': '00', 'cover_open': '00'}).toJson();
      expect(json['status_ambiguities'], hasLength(1));
    });
  });

  group('isUseful', () {
    test('an unidentified printer always is', () {
      expect(PrinterCharacterization.isUseful(null), isTrue);
    });

    test('a profile with no status handling is worth characterising', () {
      final profile = parsePrinterProfiles('''
        {"profiles": [{"slug": "raw", "name": "Raw", "schema_version": 1,
          "print_program": [{"tx_raster": true}]}]}
      ''').single;
      expect(PrinterCharacterization.isUseful(profile), isTrue);
    });

    test('a v1 bitmask profile still is — its codes may be an enum', () {
      final profile = parsePrinterProfiles('''
        {"profiles": [{"slug": "v1", "name": "V1", "schema_version": 1,
          "print_program": [{"tx_raster": true}],
          "status_program": [{"tx": "1b 21 3f"}],
          "status_flags": {"byte": 0, "flags": {"cover_open": "01"}}}]}
      ''').single;
      expect(PrinterCharacterization.isUseful(profile), isTrue);
    });

    test('a profile with an exact value map has nothing left to give', () {
      final profile = parsePrinterProfiles('''
        {"profiles": [{"slug": "v2", "name": "V2", "schema_version": 2,
          "print_program": [{"tx_raster": true}],
          "status_program": [{"tx": "1b 21 3f"}],
          "status_flags": {"byte": 0, "values": {"00": []}}}]}
      ''').single;
      expect(PrinterCharacterization.isUseful(profile), isFalse);
    });
  });

  group('capture', () {
    test(
      'only re-asks the languages that answered the opening probe',
      () async {
        final t = _FakeTransport([0x01]);
        addTearDown(t.dispose);
        final replies = await PrinterCharacterization.capture(
          t,
          answered: const {'tspl_status': (hex: '00', ascii: '.')},
        );
        expect(replies.keys, ['tspl_status']);
        expect(replies['tspl_status']!.hex, '01');
      },
    );

    test('falls back to every status query when nothing answered before', () {
      // A printer matched by BLE name was never probed, so there is no
      // shortlist to narrow to — asking all of them is the only way to learn
      // anything.
      expect(PrinterProbe.statusQueries.map((q) => q.name), [
        'tspl_status',
        'escpos_status',
        'zpl_host_status',
        'd11s_status',
      ]);
    });

    test('a silent printer is an empty result, not a failure', () async {
      final t = _FakeTransport([null]);
      addTearDown(t.dispose);
      expect(await PrinterCharacterization.capture(t), isEmpty);
    });
  });

  group('steps', () {
    test('cover the states a status map needs, with an answer key', () {
      expect(PrinterCharacterization.steps.map((s) => s.id), [
        'ready',
        'cover_open',
        'no_labels_cover_open',
        'no_labels',
      ]);
      // "Ready" must mean no conditions — it is the baseline every other
      // reading is compared against.
      expect(PrinterCharacterization.steps.first.flags, isEmpty);
      // Both open states are captured separately, because printers commonly
      // report a combination as its own value rather than as OR-ed bits.
      expect(
        PrinterCharacterization.steps
            .firstWhere((s) => s.id == 'no_labels_cover_open')
            .flags,
        ['cover_open', 'out_of_paper'],
      );
    });

    test('every flag used is one the driver can act on', () {
      // A step promising a condition the driver ignores would produce a
      // status map that decodes to nothing.
      const known = {
        'cover_open',
        'out_of_paper',
        'paper_jam',
        'low_battery',
        'overheated',
        'no_ribbon',
        'printing',
      };
      for (final step in PrinterCharacterization.steps) {
        expect(known, containsAll(step.flags), reason: step.id);
      }
    });
  });
}
