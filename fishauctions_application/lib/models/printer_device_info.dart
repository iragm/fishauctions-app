/// What a Bluetooth printer says it is, read off the open GATT link: the
/// standard Device Information Service (0x180A) plus the services it exposes.
///
/// This exists because the advertised BLE name is a bad identifier — sellers
/// rename their printers, and the same board ships under several brand names —
/// so a name that matches no profile isn't the same thing as an unsupported
/// printer. Asking the device directly is what turns "what kind of printer is
/// this?" from a question for the user into one the app can usually answer
/// itself, and what gives us something worth reporting when it can't (see
/// `PrinterReportService`).
///
/// Every field is best-effort: cheap thermal printers routinely implement none
/// of DIS, and printing works fine without it.
class PrinterDeviceInfo {
  const PrinterDeviceInfo({
    required this.bleName,
    this.manufacturer,
    this.model,
    this.firmware,
    this.hardware,
    this.serviceUuids = const [],
  });

  /// The advertised name the user picked in the connect sheet.
  final String bleName;

  final String? manufacturer;
  final String? model;
  final String? firmware;
  final String? hardware;

  /// GATT services the device exposes, normalized by [normalizeGattUuid].
  final List<String> serviceUuids;

  /// True when the printer told us nothing identifying — no DIS at all.
  bool get isEmpty =>
      manufacturer == null &&
      model == null &&
      firmware == null &&
      hardware == null;

  bool hasService(String uuid) =>
      serviceUuids.contains(normalizeGattUuid(uuid));

  /// Human-readable version for the "we couldn't identify this" dialog — the
  /// user can read it out (or copy it) so a profile can be added for their
  /// printer.
  String get summary {
    final lines = <String>[
      if (bleName.isNotEmpty) 'Name: $bleName',
      if (manufacturer != null) 'Manufacturer: $manufacturer',
      if (model != null) 'Model: $model',
      if (firmware != null) 'Firmware: $firmware',
      if (hardware != null) 'Hardware: $hardware',
      if (serviceUuids.isNotEmpty) 'Services: ${serviceUuids.join(', ')}',
    ];
    return lines.join('\n');
  }

  Map<String, dynamic> toJson() => {
    'ble_name': bleName,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (model != null) 'model': model,
    if (firmware != null) 'firmware': firmware,
    if (hardware != null) 'hardware': hardware,
    'service_uuids': serviceUuids,
  };
}

/// The 128-bit form of a 16-bit GATT UUID reduced back to its four hex digits,
/// so `180a` and `0000180a-0000-1000-8000-00805f9b34fb` compare equal.
/// Anything else (a vendor's own 128-bit UUID) is just lowercased.
String normalizeGattUuid(String uuid) {
  final lower = uuid.toLowerCase().trim();
  final match = _baseUuid.firstMatch(lower);
  return match?.group(1) ?? lower;
}

final _baseUuid = RegExp(r'^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$');
