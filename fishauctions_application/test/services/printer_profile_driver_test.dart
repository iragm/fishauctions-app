import 'dart:async';
import 'dart:typed_data';

import 'package:fishauctions_application/models/label_bitmap.dart';
import 'package:fishauctions_application/models/printer_profile.dart';
import 'package:fishauctions_application/services/bundled_printer_profiles.dart';
import 'package:fishauctions_application/services/printer_exception.dart';
import 'package:fishauctions_application/services/printer_profile_driver.dart';
import 'package:fishauctions_application/services/printer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records writes and scripts notify replies so profile programs are testable
/// without a real printer.
class _FakeTransport implements PrinterTransport {
  _FakeTransport({this.statusByte = 0x00});

  final List<List<int>> writes = [];
  final _controller = StreamController<Uint8List>.broadcast();

  int statusByte;

  @override
  bool get isConnected => true;

  @override
  Stream<Uint8List> get notifications => _controller.stream;

  @override
  Future<void> write(List<int> bytes) async {
    writes.add(List<int>.from(bytes));
    if (_eq(bytes, const [0x10, 0xff, 0x40]) ||
        _eq(bytes, const [0x1b, 0x21, 0x3f])) {
      // D11s `10 ff 40` and TSPL `<ESC>!?` both answer with one status byte.
      scheduleMicrotask(() => _emit([statusByte]));
    } else if (_eq(bytes, const [0x10, 0xff, 0xfe, 0x45]) ||
        _eq(bytes, const [0x10, 0xff, 0xf1, 0x45])) {
      scheduleMicrotask(() => _emit([0xAA])); // ack either device class's stop
    }
  }

  void _emit(List<int> bytes) {
    if (!_controller.isClosed) {
      _controller.add(Uint8List.fromList(bytes));
    }
  }

  void dispose() => _controller.close();

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

LabelBitmap _bitmap({int bytesPerRow = 12, int rows = 2}) => LabelBitmap(
  bytesPerRow: bytesPerRow,
  rows: rows,
  data: Uint8List(bytesPerRow * rows),
);

PrinterProfile _profile(String slug) =>
    bundledPrinterProfiles().firstWhere((p) => p.slug == slug);

void main() {
  group('bundled profiles', () {
    test('parse, are schema v1, and are priority-ordered', () {
      final profiles = bundledPrinterProfiles();
      expect(profiles.map((p) => p.slug), [
        'd11s-aiyin',
        'd11s-lujiang',
        'tspl-raster',
        'escpos-raster',
      ]);
      for (final p in profiles) {
        expect(p.schemaVersion, PrinterProfile.supportedSchemaVersion);
        expect(p.printProgram, isNotEmpty);
      }
    });

    test('D11s profiles match D11/Fichero names, case-insensitively', () {
      final aiyin = _profile('d11s-aiyin');
      expect(aiyin.matchesName('D11s_5C32'), isTrue);
      expect(aiyin.matchesName('FICHERO_A1'), isTrue);
      expect(aiyin.matchesName('JCP-D30'), isFalse);
      // The raw fallback never auto-matches — manual pick only.
      expect(_profile('escpos-raster').matchesName('D11s_5C32'), isFalse);
    });

    test('profiles with a newer schema version are dropped on parse', () {
      final parsed = parsePrinterProfiles('''
        {"profiles": [
          {"slug": "future", "name": "Future", "schema_version": 99,
           "print_program": [{"tx": "00"}]},
          {"slug": "current", "name": "Current", "schema_version": 1,
           "print_program": [{"tx": "00"}]}
        ]}
      ''');
      expect(parsed.map((p) => p.slug), ['current']);
    });
  });

  // Byte-for-byte parity with the retired hardcoded D11sDriver: same
  // commands, same order, same completion ack.
  group('D11s print program via the interpreter', () {
    test('emits the full AiYin print sequence and completes on 0xAA', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      final warning = await PrinterProfileDriver(
        t,
        _profile('d11s-aiyin'),
      ).printLabel(_bitmap(rows: 1), density: 2);

      expect(warning, isNull);
      // density → paper type → wake(12 zeros) → enable → raster header →
      // raster → feed → stop
      expect(t.writes, contains(equals([0x10, 0xff, 0x10, 0x00, 0x02])));
      expect(t.writes, contains(equals([0x10, 0xff, 0x84, 0x00])));
      expect(t.writes, contains(equals(List<int>.filled(12, 0x00))));
      expect(t.writes, contains(equals([0x10, 0xff, 0xfe, 0x01]))); // enable
      // GS v 0: 12 bytes/row, 1 row → 0C 00 / 01 00 (little-endian).
      expect(
        t.writes,
        contains(equals([0x1d, 0x76, 0x30, 0x00, 0x0c, 0x00, 0x01, 0x00])),
      );
      expect(t.writes, contains(equals([0x1d, 0x0c]))); // form feed
      expect(t.writes.last, [0x10, 0xff, 0xfe, 0x45]); // stop is last
    });

    test('Lujiang profile swaps enable/stop bytes', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      await PrinterProfileDriver(
        t,
        _profile('d11s-lujiang'),
      ).printLabel(_bitmap(rows: 1));

      expect(t.writes, contains(equals([0x10, 0xff, 0xf1, 0x03]))); // enable
      expect(t.writes.last, [0x10, 0xff, 0xf1, 0x45]); // stop
    });

    test('repeat_per_copy runs the copy block per copy', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      final progress = <double>[];
      await PrinterProfileDriver(
        t,
        _profile('d11s-aiyin'),
      ).printLabel(_bitmap(rows: 1), copies: 3, onProgress: progress.add);

      final feeds = t.writes.where(
        (w) => _FakeTransport._eq(w, const [0x1d, 0x0c]),
      );
      expect(feeds.length, 3);
      expect(progress, [1 / 3, 2 / 3, 1.0]);
    });

    test('blocks with a clear message when out of paper', () async {
      final t = _FakeTransport(statusByte: 0x04); // no paper
      addTearDown(t.dispose);

      await expectLater(
        () => PrinterProfileDriver(
          t,
          _profile('d11s-aiyin'),
        ).printLabel(_bitmap()),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            contains('out of labels'),
          ),
        ),
      );
      // Must not have started printing.
      const anyDensity = [0x10, 0xff, 0x10];
      final startedPrinting = t.writes.any(
        (w) => w.length >= 3 && _FakeTransport._eq(w.sublist(0, 3), anyDensity),
      );
      expect(startedPrinting, isFalse);
    });
  });

  // The VEVOR Y486BT (and TSC-compatible 4x6 printers generally) speak TSPL,
  // not ESC/POS: an ASCII command stream with the bitmap inlined, and — the
  // detail that inverts everything — a bit value of *0* prints a black dot.
  group('TSPL print program', () {
    test('matches Y486BT names but not a D11s', () {
      final tspl = _profile('tspl-raster');
      expect(tspl.matchesName('Y486BT_AB10'), isTrue);
      expect(tspl.matchesName('Y486BT_AB10-BLE'), isTrue);
      expect(tspl.matchesName('D11s_5C32'), isFalse);
      // 4" head at 203 dpi, and TSPL's inverted ink polarity.
      expect(tspl.printWidthPx, 832);
      expect(tspl.dpi, 203);
      expect(tspl.invertRaster, isTrue);
      // The Y486BT is a Feasycom FSC-BT986 running Microchip's transparent
      // UART. Its ids must be pinned: the service's first *writable*
      // characteristic is the module's control channel, so discovery would
      // send label data somewhere that reconfigures the radio.
      expect(tspl.serviceUuid, '49535343-fe7d-4ae5-8fa9-9fafd205e455');
      expect(
        tspl.writeCharacteristicUuid,
        '49535343-8841-43f4-a8d4-ecbe34729bb3',
      );
      expect(
        tspl.notifyCharacteristicUuid,
        '49535343-1e4d-4bd9-ba61-23c647249616',
      );
    });

    test('emits SIZE/CLS, an inline BITMAP, then PRINT', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      final warning = await PrinterProfileDriver(
        t,
        _profile('tspl-raster'),
      ).printLabel(_bitmap(rows: 1), labelWidthMm: 101.6, labelHeightMm: 152.4);

      // No `await` step: TSPL has no completion ack, so a clean run must not
      // claim it "couldn't confirm the print finished".
      expect(warning, isNull);

      final text = t.writes.map(String.fromCharCodes).toList();
      expect(
        text,
        contains(
          'SIZE 101.6 mm,152.4 mm\r\nDIRECTION 0\r\n'
          'REFERENCE 0,0\r\nCLS\r\n',
        ),
      );
      // BITMAP x,y,width_in_BYTES,height_in_DOTS,mode — then raw bytes.
      expect(text, contains('BITMAP 0,0,12,1,0,'));
      expect(text.last, '\r\nPRINT 1,1\r\n');
    });

    test('inverts the raster, because TSPL prints on a 0 bit', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      // An all-zero bitmap is a blank (all-white) label.
      await PrinterProfileDriver(
        t,
        _profile('tspl-raster'),
      ).printLabel(_bitmap(bytesPerRow: 4, rows: 1));

      // ...so every bit must reach the printer set, or the label comes out
      // solid black and burns through the roll.
      expect(t.writes, contains(equals([0xff, 0xff, 0xff, 0xff])));
    });

    test('decodes TSPL status, including a jam', () async {
      Future<ProfilePrinterStatus> read(int byte) {
        final t = _FakeTransport(statusByte: byte);
        addTearDown(t.dispose);
        return PrinterProfileDriver(t, _profile('tspl-raster')).readStatus();
      }

      expect((await read(0x00)).blocker, isNull);
      expect((await read(0x01)).coverOpen, isTrue);
      expect((await read(0x02)).paperJam, isTrue);
      expect((await read(0x04)).outOfPaper, isTrue);
      expect((await read(0x20)).printing, isTrue);
      // With the lid shut, the specific faults still report themselves.
      expect((await read(0x04)).blocker?.message, contains('out of labels'));
      expect((await read(0x02)).blocker?.message, contains('jam'));
    });

    test('an open lid is reported as an open lid, not as empty', () async {
      // Measured on a VEVOR Y486BT: lid open, roll loaded → 0x07. TSPL's
      // status byte is an enumeration ("out of ribbon and head opened"), so
      // read as a bitmask it also sets out_of_paper (0x04) and paper_jam
      // (0x02). Telling someone to load labels that are already in the
      // printer is the worst possible answer, so cover-open wins.
      final t = _FakeTransport(statusByte: 0x07);
      addTearDown(t.dispose);
      final status = await PrinterProfileDriver(
        t,
        _profile('tspl-raster'),
      ).readStatus();

      expect(status.coverOpen, isTrue);
      expect(status.blocker?.message, contains('cover is open'));
    });
  });

  // Reading the language off a profile's own bytes is what lets an unknown
  // printer be matched from what it answered, instead of asking a volunteer
  // to choose between "TSPL" and "Raw ESC/POS raster (GS v 0)".
  group('command language inferred from the print program', () {
    test('identifies each bundled profile', () {
      expect(_profile('tspl-raster').inferredLanguage, 'tspl');
      expect(_profile('escpos-raster').inferredLanguage, 'escpos');
      expect(_profile('d11s-aiyin').inferredLanguage, 'd11s');
      expect(_profile('d11s-lujiang').inferredLanguage, 'd11s');
    });

    test('finds bytes nested inside repeat_per_copy', () {
      // The ESC/POS raster header only appears inside the per-copy block, so a
      // scan that didn't recurse would report no language at all.
      final profile = parsePrinterProfiles('''
        {"profiles": [{
          "slug": "nested", "name": "Nested", "schema_version": 1,
          "print_program": [
            {"repeat_per_copy": [
              {"tx": "1d 76 30 00 {u16le:width_bytes} {u16le:height_px}"},
              {"tx_raster": true}
            ]}
          ]
        }]}
      ''').single;
      expect(profile.inferredLanguage, 'escpos');
    });

    test('a program with nothing distinctive reports no language', () {
      final profile = parsePrinterProfiles('''
        {"profiles": [{
          "slug": "plain", "name": "Plain", "schema_version": 1,
          "print_program": [{"tx_raster": true}]
        }]}
      ''').single;
      expect(profile.inferredLanguage, isNull);
    });

    test('probe matches report as deviceInfo on the wire', () {
      // `matched_by` is a strict ChoiceField; an unknown value 400s the whole
      // report, so `probe` has to ride under an accepted name for now.
      expect(ProfileMatch.probe.wireName, 'deviceInfo');
      expect(ProfileMatch.bleName.wireName, 'bleName');
      expect(ProfileMatch.manual.wireName, 'manual');
    });
  });

  group('status decoding via status_flags', () {
    test('decodes the D11s status bitmask', () async {
      Future<ProfilePrinterStatus> read(int byte) {
        final t = _FakeTransport(statusByte: byte);
        addTearDown(t.dispose);
        return PrinterProfileDriver(t, _profile('d11s-aiyin')).readStatus();
      }

      expect((await read(0x04)).outOfPaper, isTrue);
      expect((await read(0x02)).coverOpen, isTrue);
      expect((await read(0x08)).lowBattery, isTrue);
      // 0x50 mask folds both overheat bits.
      expect((await read(0x40)).overheated, isTrue);
      expect((await read(0x10)).overheated, isTrue);
      expect((await read(0x00)).blocker, isNull);
      // Low battery is a warning, not a blocker.
      expect((await read(0x08)).blocker, isNull);
    });

    test('a profile without a status program reports ready', () async {
      final t = _FakeTransport(statusByte: 0x04);
      addTearDown(t.dispose);
      final status = await PrinterProfileDriver(
        t,
        _profile('escpos-raster'),
      ).readStatus();
      expect(status.blocker, isNull);
      expect(t.writes, isEmpty); // nothing was sent
    });
  });

  group('placeholders', () {
    test('tx_text substitutes mm dimensions as trimmed decimals', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      final profile = parsePrinterProfiles(r'''
        {"profiles": [{
          "slug": "tspl", "name": "TSPL", "schema_version": 1,
          "raster": {"print_width_px": 96, "dpi": 203},
          "print_program": [
            {"tx_text": "SIZE {width_mm} mm,{height_mm} mm\r\n"},
            {"tx_raster": true}
          ]
        }]}
      ''').single;
      await PrinterProfileDriver(
        t,
        profile,
      ).printLabel(_bitmap(rows: 1), labelWidthMm: 76.2, labelHeightMm: 51);
      expect(String.fromCharCodes(t.writes.first), 'SIZE 76.2 mm,51 mm\r\n');
    });

    test('an unknown placeholder throws a profile-config error', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      final profile = parsePrinterProfiles('''
        {"profiles": [{
          "slug": "bad", "name": "Bad", "schema_version": 1,
          "print_program": [{"tx": "10 {bogus}"}]
        }]}
      ''').single;
      await expectLater(
        () => PrinterProfileDriver(t, profile).printLabel(_bitmap()),
        throwsA(
          isA<PrinterException>().having(
            (e) => e.message,
            'message',
            contains('profile is invalid'),
          ),
        ),
      );
    });
  });
}
