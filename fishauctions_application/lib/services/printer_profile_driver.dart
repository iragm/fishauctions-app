import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/label_bitmap.dart';
import '../models/printer_profile.dart';
import 'printer_exception.dart';
import 'printer_transport.dart';

/// Label media size reported by the printer itself, via a profile's
/// `label_size_program`.
class LabelSizeMm {
  const LabelSizeMm({required this.widthMm, required this.heightMm});

  final double widthMm;
  final double heightMm;
}

/// Printer status decoded through a profile's `status_flags` map. The flag
/// names are a fixed vocabulary shared with the backend admin rows.
class ProfilePrinterStatus {
  const ProfilePrinterStatus(this.flags);

  /// A printer that didn't answer (or has no status program) is treated as
  /// ready — some units stay quiet when healthy.
  static const ready = ProfilePrinterStatus({});

  final Set<String> flags;

  bool get printing => flags.contains('printing');
  bool get coverOpen => flags.contains('cover_open');
  bool get outOfPaper => flags.contains('out_of_paper');
  bool get lowBattery => flags.contains('low_battery');
  bool get overheated => flags.contains('overheated');

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

/// Drives any printer described by a [PrinterProfile] over a
/// [PrinterTransport], by interpreting the profile's declarative command
/// programs (BACKEND_SPEC.md §1.3.1): `tx` hex bytes, `tx_text` ASCII with
/// placeholders, `tx_raster` (the packed 1-bit bitmap), `delay_ms`, `await`
/// (wait for a notify frame), and `repeat_per_copy`. No app release is needed
/// for a new printer — its byte sequences live in a Django admin row.
class PrinterProfileDriver {
  PrinterProfileDriver(this._transport, this.profile);

  final PrinterTransport _transport;
  final PrinterProfile profile;

  static const _statusTimeout = Duration(seconds: 5);

  /// Prints [bitmap] [copies] times. Runs the profile's status program as a
  /// pre-flight and throws a [PrinterException] with a clear next step when
  /// the printer can't print (out of paper, cover open, overheated).
  ///
  /// [labelWidthMm]/[labelHeightMm] feed the `{width_mm}`/`{height_mm}`
  /// placeholders (TSPL-style `SIZE` commands); when absent they're derived
  /// from the bitmap and the profile's dpi. Returns a user-facing warning
  /// string when the job finished with a soft problem (e.g. the printer never
  /// acked an `await` marked `on_timeout: warn`), or null on a clean print.
  Future<String?> printLabel(
    LabelBitmap bitmap, {
    int copies = 1,
    int density = 1,
    int paperType = 0,
    double? labelWidthMm,
    double? labelHeightMm,
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

    final ctx = _ProgramContext(
      profile.invertRaster ? _inverted(bitmap.data) : bitmap.data,
      widthPx: bitmap.widthPx,
      heightPx: bitmap.rows,
      widthBytes: bitmap.bytesPerRow,
      widthMm: labelWidthMm ?? bitmap.widthPx / profile.dpi * 25.4,
      heightMm: labelHeightMm ?? bitmap.rows / profile.dpi * 25.4,
      copies: copies,
      density: density.clamp(0, 2),
      paperType: paperType & 0xff,
      onProgress: onProgress,
    );
    return _runProgram(profile.printProgram, ctx);
  }

  /// Queries the printer's status via the profile's status program. Profiles
  /// without one (or printers that stay quiet) report
  /// [ProfilePrinterStatus.ready] — printing proceeds and hardware problems
  /// surface on the print itself.
  Future<ProfilePrinterStatus> readStatus({
    Duration timeout = _statusTimeout,
  }) async {
    if (profile.statusProgram.isEmpty || profile.statusFlags.isEmpty) {
      return ProfilePrinterStatus.ready;
    }
    // Arm the listener before sending the query so the reply can't be missed.
    final reply = _transport.notifications.first;
    await _runProgram(profile.statusProgram, _ProgramContext.commandsOnly());
    try {
      final frame = await reply.timeout(timeout);
      return _decodeStatus(frame);
    } on TimeoutException {
      return ProfilePrinterStatus.ready;
    }
  }

  /// Asks the printer what label media is loaded, for profiles that define a
  /// `label_size_program` (`SIZE?`-style queries, RFID rolls). Returns null
  /// when the profile can't (most cheap BLE printers) or the printer doesn't
  /// answer in time — callers fall back to the user's saved label prefs.
  Future<LabelSizeMm?> readLabelSize() async {
    if (profile.labelSizeProgram.isEmpty || profile.labelSizeParse.isEmpty) {
      return null;
    }
    final parse = profile.labelSizeParse;
    // Only ascii_regex is defined for schema v1; unknown kinds are a newer
    // backend talking past this build — skip gracefully.
    if (parse['kind'] != 'ascii_regex') {
      return null;
    }
    final RegExp pattern;
    try {
      pattern = RegExp(parse['pattern'] as String);
    } on Object {
      return null;
    }
    final timeout = Duration(milliseconds: parse['timeout_ms'] as int? ?? 3000);
    final unit = parse['unit'] as String? ?? 'mm';

    final buffer = _FrameBuffer(_transport.notifications);
    try {
      await _runProgram(
        profile.labelSizeProgram,
        _ProgramContext.commandsOnly(),
      );
      final frame = await buffer.nextWhere(
        (f) => pattern.hasMatch(latin1.decode(f, allowInvalid: true)),
        timeout,
      );
      final match = pattern.firstMatch(
        latin1.decode(frame, allowInvalid: true),
      )!;
      final w = double.tryParse(match.namedGroup('w') ?? '');
      final h = double.tryParse(match.namedGroup('h') ?? '');
      if (w == null || h == null || w <= 0 || h <= 0) {
        return null;
      }
      return LabelSizeMm(widthMm: _toMm(w, unit), heightMm: _toMm(h, unit));
    } on TimeoutException {
      return null;
    } finally {
      buffer.dispose();
    }
  }

  double _toMm(double value, String unit) => switch (unit) {
    'in' => value * 25.4,
    'dots' => value / profile.dpi * 25.4,
    _ => value, // 'mm'
  };

  // ── Program execution ─────────────────────────────────────────────────────

  /// Runs [steps] in order. Returns a user-facing warning when an `await`
  /// with `on_timeout: warn` expired, else null.
  Future<String?> _runProgram(List<dynamic> steps, _ProgramContext ctx) async {
    // Buffer notify frames for the whole run so an ack that arrives while a
    // delay step is sleeping isn't lost before its await step executes.
    final buffer = _FrameBuffer(_transport.notifications);
    try {
      await _runSteps(steps, ctx, buffer);
    } finally {
      buffer.dispose();
    }
    return ctx.warning;
  }

  Future<void> _runSteps(
    List<dynamic> steps,
    _ProgramContext ctx,
    _FrameBuffer buffer,
  ) async {
    for (final raw in steps) {
      if (raw is! Map) {
        throw _invalidProfile();
      }
      final step = raw.cast<String, dynamic>();
      if (step.containsKey('tx')) {
        await _transport.write(_compileHex(step['tx'] as String, ctx));
      } else if (step.containsKey('tx_text')) {
        await _transport.write(
          latin1.encode(_substituteText(step['tx_text'] as String, ctx)),
        );
      } else if (step.containsKey('tx_raster')) {
        await _transport.write(ctx.rasterOrThrow(_invalidProfile));
      } else if (step.containsKey('delay_ms')) {
        await Future<void>.delayed(
          Duration(milliseconds: (step['delay_ms'] as num).toInt()),
        );
      } else if (step.containsKey('await')) {
        await _awaitFrame(step['await'], ctx, buffer);
      } else if (step.containsKey('repeat_per_copy')) {
        final nested = step['repeat_per_copy'] as List? ?? const [];
        for (var copy = 0; copy < ctx.copies; copy++) {
          await _runSteps(nested, ctx, buffer);
          ctx.onProgress?.call((copy + 1) / ctx.copies);
        }
      } else {
        // Unknown step type in a schema version we claim to support — an
        // authoring error the backend's clean() should have caught.
        throw _invalidProfile();
      }
    }
  }

  Future<void> _awaitFrame(
    dynamic spec,
    _ProgramContext ctx,
    _FrameBuffer buffer,
  ) async {
    if (spec is! Map) {
      throw _invalidProfile();
    }
    final prefixes = [
      for (final p in spec['any_hex_prefix'] as List? ?? const [])
        _parseHex(p as String),
    ];
    if (prefixes.isEmpty) {
      throw _invalidProfile();
    }
    final timeout = Duration(milliseconds: spec['timeout_ms'] as int? ?? 60000);
    try {
      await buffer.nextWhere(
        (f) => prefixes.any((p) => _startsWith(f, p)),
        timeout,
      );
    } on TimeoutException {
      if (spec['on_timeout'] == 'fail') {
        throw const PrinterException(
          "The printer didn't respond. Check that it's on and in range, then "
          'try again.',
        );
      }
      ctx.warning ??=
          "The printer didn't confirm the print finished. Check the label and "
          'reprint if it came out blank.';
    }
  }

  static bool _startsWith(Uint8List frame, List<int> prefix) {
    if (frame.length < prefix.length) {
      return false;
    }
    for (var i = 0; i < prefix.length; i++) {
      if (frame[i] != prefix[i]) {
        return false;
      }
    }
    return true;
  }

  ProfilePrinterStatus _decodeStatus(Uint8List frame) {
    if (frame.isEmpty) {
      return ProfilePrinterStatus.ready;
    }
    final byteIndex = profile.statusFlags['byte'] as int? ?? -1;
    final index = byteIndex < 0 ? frame.length + byteIndex : byteIndex;
    if (index < 0 || index >= frame.length) {
      return ProfilePrinterStatus.ready;
    }
    final status = frame[index];
    final flags = <String>{};
    final specs = profile.statusFlags['flags'];
    if (specs is Map) {
      specs.forEach((name, mask) {
        if (status & _parseMask(mask) != 0) {
          flags.add('$name');
        }
      });
    }
    return ProfilePrinterStatus(flags);
  }

  /// Masks come as hex strings ("50"), ints, or a list of either (OR-ed).
  static int _parseMask(dynamic mask) {
    if (mask is int) {
      return mask;
    }
    if (mask is String) {
      return int.tryParse(mask, radix: 16) ?? 0;
    }
    if (mask is List) {
      var combined = 0;
      for (final m in mask) {
        combined |= _parseMask(m);
      }
      return combined;
    }
    return 0;
  }

  // ── Placeholder substitution ──────────────────────────────────────────────

  /// Compiles a `tx` template ("1d 76 30 00 {u16le:width_bytes} …") to bytes.
  /// Whitespace separates tokens; each token is hex bytes or a placeholder
  /// (`{name}` → one byte, `{u16le:name}` → two bytes little-endian).
  List<int> _compileHex(String template, _ProgramContext ctx) {
    final bytes = <int>[];
    for (final token in template.trim().split(RegExp(r'\s+'))) {
      if (token.isEmpty) {
        continue;
      }
      if (token.startsWith('{') && token.endsWith('}')) {
        final name = token.substring(1, token.length - 1);
        if (name.startsWith('u16le:')) {
          final value = ctx.intValue(name.substring(6), _invalidProfile);
          bytes
            ..add(value & 0xff)
            ..add((value >> 8) & 0xff);
        } else {
          bytes.add(ctx.intValue(name, _invalidProfile).clamp(0, 255));
        }
      } else {
        if (token.length.isOdd) {
          throw _invalidProfile();
        }
        for (var i = 0; i < token.length; i += 2) {
          final byte = int.tryParse(token.substring(i, i + 2), radix: 16);
          if (byte == null) {
            throw _invalidProfile();
          }
          bytes.add(byte);
        }
      }
    }
    return bytes;
  }

  /// Substitutes `{name}` placeholders in a `tx_text` template with decimal
  /// values (TSPL/ZPL-style ASCII commands like "SIZE {width_mm} mm,…").
  String _substituteText(String template, _ProgramContext ctx) =>
      template.replaceAllMapped(
        RegExp(r'\{([a-z0-9_]+)\}'),
        (m) => ctx.textValue(m.group(1)!, _invalidProfile),
      );

  static List<int> _parseHex(String hex) {
    final clean = hex.replaceAll(RegExp(r'\s+'), '');
    if (clean.isEmpty || clean.length.isOdd) {
      return const [-1]; // matches nothing
    }
    return [
      for (var i = 0; i < clean.length; i += 2)
        int.tryParse(clean.substring(i, i + 2), radix: 16) ?? -1,
    ];
  }

  static Uint8List _inverted(Uint8List data) {
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      out[i] = ~data[i] & 0xff;
    }
    return out;
  }

  PrinterException _invalidProfile() => PrinterException(
    'The "${profile.name}" printer profile is invalid. This is a server-side '
    'configuration problem — please report it.',
  );
}

/// Values the placeholders resolve against for one program run.
class _ProgramContext {
  _ProgramContext(
    this._raster, {
    required this.widthPx,
    required this.heightPx,
    required this.widthBytes,
    required this.widthMm,
    required this.heightMm,
    required this.copies,
    required this.density,
    required this.paperType,
    this.onProgress,
  });

  /// For status/size-query programs, which send fixed commands and must not
  /// reference raster placeholders.
  _ProgramContext.commandsOnly()
    : _raster = null,
      widthPx = 0,
      heightPx = 0,
      widthBytes = 0,
      widthMm = 0,
      heightMm = 0,
      copies = 1,
      density = 1,
      paperType = 0,
      onProgress = null;

  final Uint8List? _raster;
  final int widthPx;
  final int heightPx;
  final int widthBytes;
  final double widthMm;
  final double heightMm;
  final int copies;
  final int density;
  final int paperType;
  final void Function(double progress)? onProgress;

  /// Set by an `await` step that timed out with `on_timeout: warn`.
  String? warning;

  Uint8List rasterOrThrow(PrinterException Function() invalid) {
    final raster = _raster;
    if (raster == null) {
      throw invalid();
    }
    return raster;
  }

  int intValue(String name, PrinterException Function() invalid) =>
      switch (name) {
        'width_px' => widthPx,
        'height_px' => heightPx,
        'width_bytes' => widthBytes,
        'density' => density,
        'paper_type' => paperType,
        'copies' => copies,
        // width_mm/height_mm are fractional — meaningless as a raw byte.
        _ => throw invalid(),
      };

  String textValue(String name, PrinterException Function() invalid) =>
      switch (name) {
        'width_mm' => _formatNum(widthMm),
        'height_mm' => _formatNum(heightMm),
        _ => intValue(name, invalid).toString(),
      };

  /// "76.2" but "76" (not "76.0") for whole numbers — TSPL parsers vary.
  static String _formatNum(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();
}

/// Collects notify frames so an ack arriving during a `delay_ms` sleep is
/// still there when the `await` step runs. Matched frames are consumed.
class _FrameBuffer {
  _FrameBuffer(Stream<Uint8List> stream) {
    _sub = stream.listen((frame) {
      _frames.add(frame);
      final waiter = _waiter;
      _waiter = null;
      waiter?.complete();
    });
  }

  final _frames = <Uint8List>[];
  StreamSubscription<Uint8List>? _sub;
  Completer<void>? _waiter;

  Future<Uint8List> nextWhere(
    bool Function(Uint8List) test,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final index = _frames.indexWhere(test);
      if (index >= 0) {
        return _frames.removeAt(index);
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('no matching printer reply', timeout);
      }
      final waiter = _waiter = Completer<void>();
      // On timeout the loop re-checks and throws above.
      await waiter.future.timeout(remaining, onTimeout: () {});
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
