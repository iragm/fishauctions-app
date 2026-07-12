import '../models/printer_profile.dart';

/// Bundled copy of the backend's seed `ThermalPrinterProfile` rows
/// (BACKEND_SPEC.md §1.3.2), used when `GET /api/mobile/printers/profiles/`
/// has never succeeded on this install (cold start, offline). Kept in the API
/// response shape so it goes through the exact same parser as the live data.
///
/// This is a fallback, not the source of truth — the server rows win whenever
/// they're reachable, and new printers are added there, not here. Update this
/// copy only when the seed rows themselves change.
List<PrinterProfile> bundledPrinterProfiles() =>
    parsePrinterProfiles(_bundledJson);

// The D11s protocol was reverse-engineered from
// https://github.com/0xMH/fichero-printer: `10 FF`-prefixed commands, an
// ESC/POS `GS v 0` raster, 96 px printhead, 200-byte/20 ms BLE pacing. The two
// rows differ only in the enable/stop pair (AiYin vs Base/Lujiang boards —
// the wrong pair is a *silent* no-print, hence two rows the user can pick
// between on an ambiguous name match).
const _bundledJson = '''
{
  "schema_version_max": 1,
  "profiles": [
    {
      "slug": "d11s-aiyin",
      "name": "Fichero / AiYin D11s",
      "schema_version": 1,
      "priority": 10,
      "match": {
        "ble_name_patterns": ["^d11", "^fichero", "^aiyin"],
        "service_uuid": "000018f0-0000-1000-8000-00805f9b34fb",
        "write_characteristic_uuid": "00002af1-0000-1000-8000-00805f9b34fb",
        "notify_characteristic_uuid": "00002af0-0000-1000-8000-00805f9b34fb"
      },
      "transport": {
        "chunk_size": 200,
        "chunk_delay_ms": 20,
        "prefer_write_with_response": true
      },
      "raster": {
        "print_width_px": 96,
        "dpi": 203,
        "invert": false,
        "max_label_width_mm": null,
        "max_label_height_mm": null
      },
      "print_program": [
        {"tx": "10 ff 10 00 {density}"},
        {"delay_ms": 100},
        {"tx": "10 ff 84 {paper_type}"},
        {"delay_ms": 50},
        {"repeat_per_copy": [
          {"tx": "00 00 00 00 00 00 00 00 00 00 00 00"},
          {"delay_ms": 50},
          {"tx": "10 ff fe 01"},
          {"delay_ms": 50},
          {"tx": "1d 76 30 00 {u16le:width_bytes} {u16le:height_px}"},
          {"tx_raster": true},
          {"delay_ms": 500},
          {"tx": "1d 0c"},
          {"delay_ms": 300}
        ]},
        {"tx": "10 ff fe 45"},
        {"await": {"any_hex_prefix": ["AA", "4F4B"], "timeout_ms": 60000,
                   "on_timeout": "warn"}}
      ],
      "status_program": [{"tx": "10 ff 40"}],
      "status_flags": {"byte": -1, "flags": {"printing": "01",
        "cover_open": "02", "out_of_paper": "04", "low_battery": "08",
        "overheated": "50"}},
      "label_size_program": [],
      "label_size_parse": {}
    },
    {
      "slug": "d11s-lujiang",
      "name": "Fichero / AiYin D11s (LuJiang board)",
      "schema_version": 1,
      "priority": 20,
      "match": {
        "ble_name_patterns": ["^d11", "^fichero", "^aiyin"],
        "service_uuid": "000018f0-0000-1000-8000-00805f9b34fb",
        "write_characteristic_uuid": "00002af1-0000-1000-8000-00805f9b34fb",
        "notify_characteristic_uuid": "00002af0-0000-1000-8000-00805f9b34fb"
      },
      "transport": {
        "chunk_size": 200,
        "chunk_delay_ms": 20,
        "prefer_write_with_response": true
      },
      "raster": {
        "print_width_px": 96,
        "dpi": 203,
        "invert": false,
        "max_label_width_mm": null,
        "max_label_height_mm": null
      },
      "print_program": [
        {"tx": "10 ff 10 00 {density}"},
        {"delay_ms": 100},
        {"tx": "10 ff 84 {paper_type}"},
        {"delay_ms": 50},
        {"repeat_per_copy": [
          {"tx": "00 00 00 00 00 00 00 00 00 00 00 00"},
          {"delay_ms": 50},
          {"tx": "10 ff f1 03"},
          {"delay_ms": 50},
          {"tx": "1d 76 30 00 {u16le:width_bytes} {u16le:height_px}"},
          {"tx_raster": true},
          {"delay_ms": 500},
          {"tx": "1d 0c"},
          {"delay_ms": 300}
        ]},
        {"tx": "10 ff f1 45"},
        {"await": {"any_hex_prefix": ["AA", "4F4B"], "timeout_ms": 60000,
                   "on_timeout": "warn"}}
      ],
      "status_program": [{"tx": "10 ff 40"}],
      "status_flags": {"byte": -1, "flags": {"printing": "01",
        "cover_open": "02", "out_of_paper": "04", "low_battery": "08",
        "overheated": "50"}},
      "label_size_program": [],
      "label_size_parse": {}
    },
    {
      "slug": "escpos-raster",
      "name": "Raw ESC/POS raster (GS v 0)",
      "schema_version": 1,
      "priority": 900,
      "match": {
        "ble_name_patterns": [],
        "service_uuid": "",
        "write_characteristic_uuid": "",
        "notify_characteristic_uuid": ""
      },
      "transport": {
        "chunk_size": 200,
        "chunk_delay_ms": 20,
        "prefer_write_with_response": true
      },
      "raster": {
        "print_width_px": 384,
        "dpi": 203,
        "invert": false,
        "max_label_width_mm": null,
        "max_label_height_mm": null
      },
      "print_program": [
        {"repeat_per_copy": [
          {"tx": "1d 76 30 00 {u16le:width_bytes} {u16le:height_px}"},
          {"tx_raster": true},
          {"delay_ms": 200},
          {"tx": "1d 0c"},
          {"delay_ms": 200}
        ]}
      ],
      "status_program": [],
      "status_flags": {},
      "label_size_program": [],
      "label_size_parse": {}
    }
  ]
}
''';
