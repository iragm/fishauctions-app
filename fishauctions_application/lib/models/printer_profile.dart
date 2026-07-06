import 'dart:convert';

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
      bleNamePatterns: [
        for (final p in match['ble_name_patterns'] as List? ?? const [])
          p as String,
      ],
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
  /// never auto-matched (manual pick only).
  final List<String> bleNamePatterns;

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

  /// Whether [bleName] matches any of this profile's name patterns. A broken
  /// regex in an admin row must not take scanning down, so it just never
  /// matches.
  bool matchesName(String bleName) {
    for (final pattern in bleNamePatterns) {
      try {
        if (RegExp(pattern, caseSensitive: false).hasMatch(bleName)) {
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
