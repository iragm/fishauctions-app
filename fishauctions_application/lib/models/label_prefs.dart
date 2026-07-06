/// How the user wants label print actions handled, chosen on the `/printing/`
/// web page (`UserLabelPrefs.print_method`).
enum PrintMethod {
  /// Download/share the PDF — the web's behavior, and the default.
  pdf,

  /// Hand the same PDF to the OS print dialog (Android print framework /
  /// AirPrint).
  system,

  /// Native thermal printing over BLE.
  bluetooth;

  static PrintMethod fromApi(String? value) => switch (value) {
    'system' => PrintMethod.system,
    'bluetooth' => PrintMethod.bluetooth,
    _ => PrintMethod.pdf,
  };
}

/// The user's label preferences from `GET /api/mobile/labels/prefs/` — the
/// same `UserLabelPrefs` row the `/printing/` page edits, plus the server-
/// computed mismatch warnings so app and web always show identical ones.
class LabelPrefs {
  const LabelPrefs({
    required this.printMethod,
    required this.preset,
    required this.unit,
    required this.labelWidth,
    required this.labelHeight,
    required this.warnings,
  });

  factory LabelPrefs.fromJson(Map<String, dynamic> json) => LabelPrefs(
    printMethod: PrintMethod.fromApi(json['print_method'] as String?),
    preset: json['preset'] as String? ?? 'lg',
    unit: json['unit'] as String? ?? 'in',
    labelWidth: (json['label_width'] as num?)?.toDouble() ?? 0,
    labelHeight: (json['label_height'] as num?)?.toDouble() ?? 0,
    warnings: [
      for (final w in json['warnings'] as List? ?? const []) w as String,
    ],
  );

  final PrintMethod printMethod;

  /// `sm` / `lg` / `thermal_sm` / `thermal_very_sm` / `custom`.
  final String preset;

  /// `in` or `cm` — applies to [labelWidth]/[labelHeight].
  final String unit;
  final double labelWidth;
  final double labelHeight;
  final List<String> warnings;

  /// Effective label size in mm. The thermal presets have fixed dimensions
  /// (the backend's raw width/height fields aren't updated when a preset is
  /// picked); everything else converts the stored fields by [unit]. Null when
  /// the stored fields are unusable.
  (double widthMm, double heightMm)? get sizeMm => switch (preset) {
    // Thermal 3"×2".
    'thermal_sm' => (76.2, 50.8),
    // Dymo 30252, 3½" × 1⅛".
    'thermal_very_sm' => (88.9, 28.575),
    _ when labelWidth > 0 && labelHeight > 0 => (
      labelWidth * _mmPerUnit,
      labelHeight * _mmPerUnit,
    ),
    _ => null,
  };

  double get _mmPerUnit => unit == 'cm' ? 10 : 25.4;
}
