import 'dart:async';
import 'dart:typed_data';

import 'package:fishauctions_application/models/label_bitmap.dart';
import 'package:fishauctions_application/services/d11s_driver.dart';
import 'package:fishauctions_application/services/printer_exception.dart';
import 'package:fishauctions_application/services/printer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records writes and scripts notify replies so the protocol is testable
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
    if (_eq(bytes, const [0x10, 0xff, 0x40])) {
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

void main() {
  group('D11sDriver command bytes', () {
    final d = D11sDriver(_FakeTransport());

    test('density clamps to 0-2', () {
      expect(d.setDensity(1), [0x10, 0xff, 0x10, 0x00, 0x01]);
      expect(d.setDensity(9), [0x10, 0xff, 0x10, 0x00, 0x02]);
      expect(d.setDensity(-3), [0x10, 0xff, 0x10, 0x00, 0x00]);
    });

    test('raster header encodes width-bytes and rows little-endian', () {
      // 12 bytes/row, 240 rows → 0C 00 / F0 00
      expect(d.rasterHeader(_bitmap(rows: 240)), [
        0x1d,
        0x76,
        0x30,
        0x00,
        0x0c,
        0x00,
        0xf0,
        0x00,
      ]);
    });
  });

  group('D11sDriver.printLabel', () {
    test('emits the full AiYin print sequence and completes on 0xAA', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      await D11sDriver(t).printLabel(_bitmap(rows: 1), density: 2);

      // density → paper type → wake(12 zeros) → enable → raster → feed → stop
      expect(t.writes, contains(equals([0x10, 0xff, 0x10, 0x00, 0x02])));
      expect(t.writes, contains(equals([0x10, 0xff, 0x84, 0x00])));
      expect(t.writes, contains(equals(List<int>.filled(12, 0x00))));
      expect(t.writes, contains(equals([0x10, 0xff, 0xfe, 0x01]))); // enable
      expect(t.writes, contains(equals([0x1d, 0x0c]))); // form feed
      expect(t.writes.last, [0x10, 0xff, 0xfe, 0x45]); // stop is last
    });

    test('Lujiang device class swaps enable/stop bytes', () async {
      final t = _FakeTransport();
      addTearDown(t.dispose);
      await D11sDriver(
        t,
        deviceClass: D11sDeviceClass.lujiang,
      ).printLabel(_bitmap(rows: 1));

      expect(t.writes, contains(equals([0x10, 0xff, 0xf1, 0x03]))); // enable
      expect(t.writes.last, [0x10, 0xff, 0xf1, 0x45]); // stop
    });

    test('blocks with a clear message when out of paper', () async {
      final t = _FakeTransport(statusByte: 0x04); // no paper
      addTearDown(t.dispose);

      await expectLater(
        () => D11sDriver(t).printLabel(_bitmap()),
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

  group('PrinterStatus', () {
    test('decodes the status bitmask', () {
      expect(const PrinterStatus(0x04).outOfPaper, isTrue);
      expect(const PrinterStatus(0x02).coverOpen, isTrue);
      expect(const PrinterStatus(0x08).lowBattery, isTrue);
      expect(const PrinterStatus(0x40).overheated, isTrue);
      expect(const PrinterStatus(0x10).overheated, isTrue);
      expect(const PrinterStatus(0x00).blocker, isNull);
      // Low battery is a warning, not a blocker.
      expect(const PrinterStatus(0x08).blocker, isNull);
    });
  });
}
