import 'dart:async';
import 'dart:typed_data';

import '../models/label_bitmap.dart';
import 'printer_exception.dart';
import 'printer_transport.dart';

/// Enable/stop commands differ by the printer's internal board. The Fichero
/// D11s is an AiYin unit; Base/Lujiang units use a different pair. Choosing the
/// wrong one causes a *silent* no-print, so it's pinned explicitly.
enum D11sDeviceClass {
  aiyin(enable: [0x10, 0xff, 0xfe, 0x01], stop: [0x10, 0xff, 0xfe, 0x45]),
  lujiang(enable: [0x10, 0xff, 0xf1, 0x03], stop: [0x10, 0xff, 0xf1, 0x45]);

  const D11sDeviceClass({required this.enable, required this.stop});

  final List<int> enable;
  final List<int> stop;
}

/// Decoded D11s status byte (from `getStatus` or a notify push).
class PrinterStatus {
  const PrinterStatus(this.raw);

  final int raw;

  bool get printing => raw & 0x01 != 0;
  bool get coverOpen => raw & 0x02 != 0;
  bool get outOfPaper => raw & 0x04 != 0;
  bool get lowBattery => raw & 0x08 != 0;
  bool get charging => raw & 0x20 != 0;
  bool get overheated => raw & 0x10 != 0 || raw & 0x40 != 0;

  /// A user-facing reason printing can't start right now, or null if it can.
  /// Low battery is a warning, not a blocker, so it isn't returned here.
  PrinterException? get blocker {
    if (outOfPaper) {
      return const PrinterException(
        'The printer is out of labels. Load a label roll, then try again.',
      );
    }
    if (coverOpen) {
      return const PrinterException(
        'The printer cover is open. Close it, then try again.',
      );
    }
    if (overheated) {
      return const PrinterException(
        'The printer is too hot. Wait a minute for it to cool down, then '
        'try again.',
      );
    }
    return null;
  }
}

/// Drives the Fichero / AiYin D11s proprietary protocol over a
/// [PrinterTransport]. Reverse-engineered from https://github.com/0xMH/fichero-printer
/// — commands are `10 FF`-prefixed, the bitmap rides an ESC/POS `GS v 0` raster
/// header, and timing/chunking mirror the reference client (the printer drops
/// data sent too fast).
class D11sDriver {
  D11sDriver(this._transport, {this.deviceClass = D11sDeviceClass.aiyin});

  final PrinterTransport _transport;
  final D11sDeviceClass deviceClass;

  /// The D11s printhead is 96 px (12 bytes) wide. Label images are resized to
  /// this width before packing.
  static const printWidthPx = 96;

  static const _statusQuery = [0x10, 0xff, 0x40];
  static const _formFeed = [0x1d, 0x0c];

  // Inter-command settle times from the reference client; the printer drops
  // commands issued back-to-back without them.
  static const _afterDensity = Duration(milliseconds: 100);
  static const _afterPaperType = Duration(milliseconds: 50);
  static const _afterWake = Duration(milliseconds: 50);
  static const _afterEnable = Duration(milliseconds: 50);
  static const _afterRaster = Duration(milliseconds: 500);
  static const _afterFeed = Duration(milliseconds: 300);

  List<int> setDensity(int level) => [
    0x10,
    0xff,
    0x10,
    0x00,
    level.clamp(0, 2),
  ];

  List<int> setPaperType(int type) => [0x10, 0xff, 0x84, type & 0xff];

  /// ESC/POS `GS v 0`: mode 0, width in bytes (little-endian), height in rows
  /// (little-endian). Width/height come from the bitmap so non-default label
  /// lengths just work.
  List<int> rasterHeader(LabelBitmap b) => [
    0x1d, 0x76, 0x30, 0x00, //
    b.bytesPerRow & 0xff, (b.bytesPerRow >> 8) & 0xff,
    b.rows & 0xff, (b.rows >> 8) & 0xff,
  ];

  /// Queries the printer's status. Subscribes to notifications *before* sending
  /// the query so the reply can't be missed. Returns `PrinterStatus(0)` (ready)
  /// if the printer doesn't answer in [timeout] — some units stay quiet when
  /// healthy.
  Future<PrinterStatus> readStatus({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final reply = _transport.notifications.first;
    await _transport.write(_statusQuery);
    try {
      final bytes = await reply.timeout(timeout);
      return PrinterStatus(bytes.isEmpty ? 0 : bytes.last);
    } on TimeoutException {
      return const PrinterStatus(0);
    }
  }

  /// Prints [bitmap] [copies] times at [density] (0–2). Does a pre-flight
  /// status check and throws a [PrinterException] with a clear next step if the
  /// printer can't print (out of paper, cover open, overheated). [onProgress]
  /// reports 0.0–1.0 across copies.
  Future<void> printLabel(
    LabelBitmap bitmap, {
    int density = 1,
    int copies = 1,
    int paperType = 0,
    void Function(double progress)? onProgress,
  }) async {
    if (!_transport.isConnected) {
      throw const PrinterException(
        'The printer connection dropped. Reconnect the printer and try again.',
      );
    }

    final blocker = (await readStatus()).blocker;
    if (blocker != null) {
      throw blocker;
    }

    await _transport.write(setDensity(density));
    await Future<void>.delayed(_afterDensity);
    await _transport.write(setPaperType(paperType));
    await Future<void>.delayed(_afterPaperType);

    for (var copy = 0; copy < copies; copy++) {
      await _transport.write(List<int>.filled(12, 0x00)); // wake/sync
      await Future<void>.delayed(_afterWake);
      await _transport.write(deviceClass.enable);
      await Future<void>.delayed(_afterEnable);

      final header = rasterHeader(bitmap);
      final payload = Uint8List(header.length + bitmap.data.length)
        ..setRange(0, header.length, header)
        ..setRange(
          header.length,
          header.length + bitmap.data.length,
          bitmap.data,
        );
      await _transport.write(payload);
      await Future<void>.delayed(_afterRaster);

      await _transport.write(_formFeed);
      await Future<void>.delayed(_afterFeed);

      onProgress?.call((copy + 1) / copies);
    }

    // Stop, then wait for the printer's done ack (0xAA or "OK"). Arm the
    // listener before sending stop so a fast ack isn't missed.
    final done = _awaitDone(const Duration(seconds: 60));
    await _transport.write(deviceClass.stop);
    await done;
  }

  Future<void> _awaitDone(Duration timeout) async {
    try {
      await _transport.notifications
          .firstWhere((d) => d.isNotEmpty && (d[0] == 0xAA || _isOk(d)))
          .timeout(timeout);
    } on TimeoutException {
      throw const PrinterException(
        "The printer didn't confirm the print finished. Check the label and "
        'reprint if it came out blank.',
      );
    }
  }

  // ASCII "OK".
  static bool _isOk(Uint8List d) =>
      d.length >= 2 && d[0] == 0x4f && d[1] == 0x4b;
}
