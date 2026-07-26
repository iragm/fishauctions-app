import 'dart:convert';

import 'printer_device_info.dart';

/// A Bluetooth thermal label printer the app knows how to drive.
///
/// Profiles are Django admin rows served by `GET /api/mobile/printers/profiles/`
/// — adding support for a new printer is a backend data change, not an app
/// release. Every byte sent to a printer comes from the profile's command
/// programs (see `PrinterProfileDriver`); the app is a generic interpreter.
/// A bundled copy of the seed profiles covers cold-start/offline (see
/// `bundled_printer_profiles.dart`).
class PrinterProfile {
  const PrinterProfile({
    required this.slug,
    required this.name,
    required this.schemaVersion,
    required this.priority,
    required this.bleNamePatterns,
    required this.modelPatterns,
    required this.manufacturerPatterns,
    required this.serviceUuid,
    required this.writeCharacteristicUuid,
    required this.notifyCharacteristicUuid,
    required this.chunkSize,
    required this.chunkDelayMs,
    required this.preferWriteWithResponse,
    required this.printWidthPx,
    required this.dpi,
    required this.invertRaster,
    required this.maxLabelWidthMm,
    required this.maxLabelHeightMm,
    required this.printProgram,
    required this.statusProgram,
    required this.statusFlags,
    required this.labelSizeProgram,
    required this.labelSizeParse,
  });

  factory PrinterProfile.fromJson(Map<String, dynamic> json) {
    final match = _section(json, 'match');
    final transport = _section(json, 'transport');
    final raster = _section(json, 'raster');
    return PrinterProfile(
      slug: json['slug'] as String,
      name: json['name'] as String? ?? json['slug'] as String,
      schemaVersion: _int(json['schema_version'], 1),
      priority: _int(json['priority'], 100),
      bleNamePatterns: _patterns(match['ble_name_patterns']),
      modelPatterns: _patterns(match['model_patterns']),
      manufacturerPatterns: _patterns(match['manufacturer_patterns']),
      serviceUuid: _uuid(match['service_uuid']),
      writeCharacteristicUuid: _uuid(match['write_characteristic_uuid']),
      notifyCharacteristicUuid: _uuid(match['notify_characteristic_uuid']),
      chunkSize: _int(transport['chunk_size'], 200),
      chunkDelayMs: _int(transport['chunk_delay_ms'], 20),
      preferWriteWithResponse:
          transport['prefer_write_with_response'] as bool? ?? true,
      printWidthPx: _int(raster['print_width_px'], 96),
      dpi: _int(raster['dpi'], 203),
      invertRaster:
          (raster['invert'] ?? raster['invert_raster']) as bool? ?? false,
      maxLabelWidthMm: _double(raster['max_label_width_mm']),
      maxLabelHeightMm: _double(raster['max_label_height_mm']),
      printProgram: json['print_program'] as List? ?? const [],
      statusProgram: json['status_program'] as List? ?? const [],
      statusFlags: _map(json['status_flags']),
      labelSizeProgram: json['label_size_program'] as List? ?? const [],
      labelSizeParse: _map(json['label_size_parse']),
    );
  }

  /// The command-program schema version this build can interpret. Profiles
  /// with a newer `schema_version` are ignored on parse — the backend bumps a
  /// profile's version when it uses step types an older app can't run.
  static const supportedSchemaVersion = 1;

  final String slug;
  final String name;
  final int schemaVersion;

  /// Match order when several profiles' name patterns hit the same device —
  /// low wins.
  final int priority;

  // ── Matching ──
  /// Case-insensitive regexes tested against the advertised BLE name. Empty =
  /// never matched this way (a renamed printer, or the raw fallback profile).
  final List<String> bleNamePatterns;

  /// Case-insensitive regexes tested against what the printer reports over
  /// GATT (Device Information Service) once connected — the reliable identity
  /// when the advertised name isn't one. See [matchesDeviceInfo].
  final List<String> modelPatterns;
  final List<String> manufacturerPatterns;

  /// Exact GATT ids ('' = discover the first writable characteristic).
  final String serviceUuid;
  final String writeCharacteristicUuid;
  final String notifyCharacteristicUuid;

  // ── Transport pacing (the printer drops data sent too fast) ──
  final int chunkSize;
  final int chunkDelayMs;
  final bool preferWriteWithResponse;

  // ── Raster geometry ──
  final int printWidthPx;
  final int dpi;
  final bool invertRaster;
  final double? maxLabelWidthMm;
  final double? maxLabelHeightMm;

  // ── Command programs (schema §1.3.1 of BACKEND_SPEC.md) ──
  final List<dynamic> printProgram;
  final List<dynamic> statusProgram;
  final Map<String, dynamic> statusFlags;
  final List<dynamic> labelSizeProgram;
  final Map<String, dynamic> labelSizeParse;

  /// Whether [bleName] matches any of this profile's name patterns.
  bool matchesName(String bleName) => _matchesAny(bleNamePatterns, bleName);

  /// Which command language this profile speaks, read off its own print
  /// program.
  ///
  /// Inferred rather than declared because the profile schema has no language
  /// field yet (see `BACKEND_SPEC.md` — `command_language` is proposed). This
  /// isn't guesswork: it reads the actual bytes the profile sends, which *are*
  /// the language. Pairing it with what a printer answered to `PrinterProbe`
  /// is what lets an unknown printer be matched automatically instead of
  /// asking the user to choose a protocol they've never heard of.
  ///
  /// Null when the program is too generic to tell.
  String? get inferredLanguage {
    final text = _programText(printProgram).toLowerCase();
    if (text.contains('bitmap ') || text.contains('size {width_mm}')) {
      return 'tspl';
    }
    if (text.contains('^gfa') || text.contains('^xa')) {
      return 'zpl';
    }
    if (text.contains('! u1') || text.contains('! 0 200')) {
      return 'cpcl';
    }
    if (text.contains('10ff')) {
      return 'd11s';
    }
    if (text.contains('1d7630')) {
      return 'escpos';
    }
    return null;
  }

  /// Flattens a program's `tx`/`tx_text` payloads into one searchable string.
  /// Hex is whitespace-stripped so "1d 76 30" and "1d7630" both match.
  static String _programText(List<dynamic> steps) {
    final buffer = StringBuffer();
    for (final raw in steps) {
      if (raw is! Map) {
        continue;
      }
      final tx = raw['tx'];
      if (tx is String) {
        buffer.write(tx.replaceAll(RegExp(r'\s+'), ''));
      }
      final text = raw['tx_text'];
      if (text is String) {
        buffer.write(text);
      }
      final nested = raw['repeat_per_copy'];
      if (nested is List) {
        buffer.write(_programText(nested));
      }
    }
    return buffer.toString();
  }

  /// Whether the printer's own reported identity matches this profile — the
  /// model number or the manufacturer name from its GATT Device Information
  /// Service. Unlike the BLE name, these are burned in by the OEM, so a
  /// printer the user renamed still identifies itself correctly.
  bool matchesDeviceInfo(PrinterDeviceInfo info) =>
      _matchesAny(modelPatterns, info.model) ||
      _matchesAny(manufacturerPatterns, info.manufacturer);

  /// A broken regex in an admin row must not take pairing down, so it just
  /// never matches.
  static bool _matchesAny(List<String> patterns, String? value) {
    if (value == null || value.isEmpty) {
      return false;
    }
    for (final pattern in patterns) {
      try {
        if (RegExp(pattern, caseSensitive: false).hasMatch(value)) {
          return true;
        }
      } on FormatException {
        // Invalid pattern — skip it.
      }
    }
    return false;
  }

  /// Sections are nested in the API response but may be flattened in hand-
  /// written JSON (tests, admin exports); fall back to the top level.
  static Map<String, dynamic> _section(Map<String, dynamic> json, String key) {
    final section = json[key];
    return section is Map ? section.cast<String, dynamic>() : json;
  }

  static List<String> _patterns(dynamic v) => [
    if (v is List)
      for (final p in v)
        if (p is String) p,
  ];

  static Map<String, dynamic> _map(dynamic v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  static int _int(dynamic v, int fallback) => v is num ? v.toInt() : fallback;

  static double? _double(dynamic v) => v is num ? v.toDouble() : null;

  /// GATT ids are compared against `Guid.str` (lowercased 128-bit form).
  static String _uuid(dynamic v) => (v as String? ?? '').toLowerCase().trim();
}

/// Parses a `GET /api/mobile/printers/profiles/` response body (live, cached,
/// or the bundled copy) into usable profiles: drops rows whose schema version
/// this build doesn't understand, drops rows that don't parse (a bad admin row
/// must not brick the rest), and orders by priority.
List<PrinterProfile> parsePrinterProfiles(String jsonBody) {
  final decoded = jsonDecode(jsonBody);
  final rows = decoded is Map ? decoded['profiles'] as List? : null;
  final profiles = <PrinterProfile>[];
  for (final row in rows ?? const []) {
    if (row is! Map) {
      continue;
    }
    try {
      final profile = PrinterProfile.fromJson(row.cast<String, dynamic>());
      if (profile.schemaVersion <= PrinterProfile.supportedSchemaVersion) {
        profiles.add(profile);
      }
    } on Object {
      // Malformed row — skip it.
    }
  }
  profiles.sort((a, b) => a.priority.compareTo(b.priority));
  return profiles;
}

/// How a printer's profile was decided, so the backend can learn which
/// printers identify themselves usefully and which still need a human.
enum ProfileMatch {
  bleName,
  deviceInfo,
  serviceUuid,

  /// Matched by asking the print engine which command language it speaks
  /// (`PrinterProbe`) and finding exactly one profile that speaks it.
  probe,

  manual;

  /// The string `printers/observed/` accepts. `matched_by` is a strict
  /// `ChoiceField` on the backend, so [probe] reports as `deviceInfo` — both
  /// mean "the printer told us what it is", and sending an unknown value
  /// would 400 the whole report. Collapse this to `probe` once
  /// `MATCHED_BY_CHOICES` gains it (see `BACKEND_SPEC.md`).
  String get wireName => switch (this) {
    ProfileMatch.probe => ProfileMatch.deviceInfo.name,
    _ => name,
  };
}

/// Picks the profile for a printer that didn't match on its advertised name,
/// from what the printer itself reported. Confidence ladder, first hit wins:
///
///  1. **Model / manufacturer patterns.** Deliberate backend data — a new
///     printer is a Django admin edit, not an app release.
///  2. **Service UUID, but only if exactly one profile claims it.** Weak on
///     its own: the cheap-BLE-printer service `18f0` is shared by half the
///     market, and the two D11s profiles (AiYin vs LuJiang board) both use it
///     — those genuinely can't be told apart this way, and guessing wrong
///     means sending a different command language. Ambiguity falls through to
///     asking the user.
///
/// [profiles] is in preference order. Null means "ask the user".
(PrinterProfile, ProfileMatch)? matchProfileForDeviceInfo(
  List<PrinterProfile> profiles,
  PrinterDeviceInfo info,
) {
  for (final profile in profiles) {
    if (profile.matchesDeviceInfo(info)) {
      return (profile, ProfileMatch.deviceInfo);
    }
  }
  final claimants = [
    for (final profile in profiles)
      if (profile.serviceUuid.isNotEmpty &&
          info.hasService(profile.serviceUuid))
        profile,
  ];
  if (claimants.length == 1) {
    return (claimants.first, ProfileMatch.serviceUuid);
  }
  return null;
}
