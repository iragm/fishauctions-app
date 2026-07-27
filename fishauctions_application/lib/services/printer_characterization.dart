import 'dart:async';

import '../models/printer_device_info.dart';
import '../models/printer_profile.dart';
import 'printer_probe.dart';
import 'printer_transport.dart';

/// One physical state we ask the user to put the printer into, and what that
/// state means in `status_flags` vocabulary.
typedef CharacterizationStep = ({
  /// Stable id, used as the capture key and reported to the backend.
  String id,

  /// Short label for the stepper.
  String title,

  /// What the user has to physically do. Written for someone holding the
  /// printer, not for someone who knows what a status byte is.
  String instruction,

  /// The conditions this state represents. This is the *answer key*: whatever
  /// byte the printer reports here means exactly these flags, which is what
  /// makes a `status_flags.values` map derivable rather than guessable.
  List<String> flags,
});

/// Everything learned about one printer, in the shape a profile is written
/// from.
class PrinterCharacterizationResult {
  const PrinterCharacterizationResult({
    required this.info,
    required this.probeReplies,
    required this.gatt,
    required this.captures,
  });

  /// What the printer said it was over GATT (often the radio module).
  final PrinterDeviceInfo info;

  /// Which command languages answered, and with what.
  final Map<String, PrinterReply> probeReplies;

  /// The full GATT tree — where a profile's service/characteristic ids come
  /// from.
  final List<Map<String, dynamic>> gatt;

  /// Status replies keyed by step id, then by query name.
  final Map<String, Map<String, PrinterReply>> captures;

  String? get language => PrinterProbe.languageFrom(probeReplies);

  /// The status query whose answers are worth decoding: the one belonging to
  /// the language the printer actually speaks. Null when nothing answered.
  String? get statusQueryName {
    for (final query in PrinterProbe.statusQueries) {
      if (query.language == language &&
          captures.values.any((byQuery) => byQuery.containsKey(query.name))) {
        return query.name;
      }
    }
    for (final byQuery in captures.values) {
      if (byQuery.isNotEmpty) {
        return byQuery.keys.first;
      }
    }
    return null;
  }

  /// The derived `status_flags.values` map: **status byte → the conditions
  /// that byte means**, ready to paste into a `ThermalPrinterProfile` row.
  ///
  /// This is the whole point of the guided capture. Working out that a
  /// VEVOR Y486BT answers `07` for "lid open with no ribbon" — and that its
  /// status is an *enumeration*, so decoding it as a bitmask claims the
  /// labels are missing when they are sitting right there — took a person
  /// with the hardware, a terminal, and an afternoon. Doing it as four button
  /// presses in the pairing flow means the next printer costs nobody an
  /// afternoon, and the exactness matters: a wrong status map tells a user to
  /// fix a problem they don't have.
  ///
  /// Only the first byte of the reply is used, which is what every status
  /// query in [PrinterProbe] answers with. Steps the printer didn't answer
  /// are absent rather than guessed.
  Map<String, List<String>> get statusValues {
    final query = statusQueryName;
    if (query == null) {
      return const {};
    }
    final values = <String, List<String>>{};
    for (final step in PrinterCharacterization.steps) {
      final byte = _firstByte(captures[step.id]?[query]);
      if (byte != null) {
        values[byte] = step.flags;
      }
    }
    return values;
  }

  /// States the printer reports with the *same* byte, so it genuinely cannot
  /// tell them apart. Worth surfacing rather than silently letting the last
  /// one win: it means the profile can only promise the weaker message, and a
  /// reviewer should know that before writing "out of labels" into it.
  List<String> get ambiguities {
    final query = statusQueryName;
    if (query == null) {
      return const [];
    }
    final byByte = <String, List<String>>{};
    for (final step in PrinterCharacterization.steps) {
      final byte = _firstByte(captures[step.id]?[query]);
      if (byte != null) {
        (byByte[byte] ??= []).add(step.id);
      }
    }
    return [
      for (final entry in byByte.entries)
        if (entry.value.length > 1)
          '${entry.key}: ${entry.value.join(' and ')} are indistinguishable',
    ];
  }

  static String? _firstByte(PrinterReply? reply) {
    final hex = reply?.hex;
    if (hex == null || hex.isEmpty) {
      return null;
    }
    return hex.split(' ').first;
  }

  /// The whole finding as one block of text the user can copy into an email.
  ///
  /// Deliberately independent of the upload: a deployment without the endpoint,
  /// or a phone that was offline in an auction hall, must still end with the
  /// user holding something they can send. The report is the deliverable; the
  /// POST is just the convenient path for it.
  String get summary {
    final lines = <String>[
      '=== FishAuctions printer report ===',
      info.summary,
      if (language != null) 'Command language: $language',
      '',
      'Probe replies:',
      if (probeReplies.isEmpty)
        '  (the printer answered none of them)'
      else
        for (final e in probeReplies.entries)
          '  ${e.key}: ${e.value.hex}  "${e.value.ascii}"',
    ];
    if (captures.isNotEmpty) {
      lines
        ..add('')
        ..add('Status codes by printer state:');
      for (final step in steps) {
        final byQuery = captures[step.id];
        if (byQuery == null) {
          continue;
        }
        lines.add(
          '  ${step.id} (${step.flags.isEmpty ? "ready" : step.flags.join('+')}'
          '): '
          '${byQuery.entries.map((e) => "${e.key}=${e.value.hex}").join(', ')}',
        );
      }
      final derived = statusValues;
      if (derived.isNotEmpty) {
        lines
          ..add('')
          ..add('Proposed status_flags.values:')
          ..add(
            '  {${derived.entries.map((e) => '"${e.key}": '
                '[${e.value.map((f) => '"$f"').join(', ')}]').join(', ')}}',
          );
      }
      for (final note in ambiguities) {
        lines.add('  NOTE $note');
      }
    }
    if (gatt.isNotEmpty) {
      lines
        ..add('')
        ..add('GATT:');
      for (final service in gatt) {
        lines.add('  service ${service['uuid']}');
        for (final c in (service['characteristics'] as List? ?? const [])) {
          final map = c as Map;
          lines.add(
            '    ${map['uuid']} '
            '[${(map['properties'] as List? ?? const []).join(',')}]',
          );
        }
      }
    }
    return lines.join('\n');
  }

  static List<CharacterizationStep> get steps => PrinterCharacterization.steps;

  Map<String, dynamic> toJson() => {
    'probe_replies': {
      for (final e in probeReplies.entries)
        e.key: {'hex': e.value.hex, 'ascii': e.value.ascii},
    },
    'probed_language': language,
    'gatt': gatt,
    'status_captures': {
      for (final e in captures.entries)
        e.key: {
          for (final q in e.value.entries)
            q.key: {'hex': q.value.hex, 'ascii': q.value.ascii},
        },
    },
    'derived_status_values': statusValues,
    if (ambiguities.isNotEmpty) 'status_ambiguities': ambiguities,
  };
}

/// Walks the user through putting a printer into each state that matters and
/// records what it reports, so an unknown printer can be turned into a
/// `ThermalPrinterProfile` row by someone who doesn't own one.
///
/// The gap this closes: the app can already discover a printer's identity,
/// its GATT ids and its command language on its own ([PrinterProbe],
/// `BluetoothService.identify`). What it cannot discover alone is the
/// **meaning of the status byte** — no query makes a printer run out of
/// labels. That needs a human to open the cover and take the roll out, which
/// is thirty seconds of work at exactly the moment the user is already
/// holding the printer and fiddling with it.
///
/// Every query sent is a read-only status request from [PrinterProbe]; nothing
/// here configures the printer, feeds media, or prints.
class PrinterCharacterization {
  const PrinterCharacterization._();

  /// The states to capture, in an order that only ever asks the user to do the
  /// next small thing: close and load → open → remove roll → close.
  ///
  /// The two "cover open" variants exist because of the TSPL lesson: printers
  /// commonly report a *combination* as its own value rather than as OR-ed
  /// bits, so "open" and "open and empty" have to be captured separately or
  /// the difference is invisible.
  static const List<CharacterizationStep> steps = [
    (
      id: 'ready',
      title: 'Ready',
      instruction:
          'Load a roll of labels and close the cover, so the printer is ready '
          'to print. Then tap Capture.',
      flags: <String>[],
    ),
    (
      id: 'cover_open',
      title: 'Cover open',
      instruction:
          'Open the printer cover, but leave the labels in it. Then tap '
          'Capture.',
      flags: ['cover_open'],
    ),
    (
      id: 'no_labels_cover_open',
      title: 'Labels out',
      instruction:
          'Take the roll of labels out, leaving the cover open. Then tap '
          'Capture.',
      flags: ['cover_open', 'out_of_paper'],
    ),
    (
      id: 'no_labels',
      title: 'Empty, closed',
      instruction: 'Close the cover with no labels loaded. Then tap Capture.',
      flags: ['out_of_paper'],
    ),
  ];

  /// What to tell the user when the capture is finished — they are holding a
  /// printer with the labels out and the app should say so.
  static const restoreInstruction =
      'All done — put the labels back in and close the cover.';

  /// Asks the printer for its status in whichever languages answered during
  /// [PrinterProbe]'s opening sweep, and returns what came back.
  ///
  /// [answered] is the initial probe result; only the status queries of
  /// languages that responded are re-sent, so a capture takes about a second
  /// rather than working through every language again at every step.
  static Future<Map<String, PrinterReply>> capture(
    PrinterTransport transport, {
    Map<String, PrinterReply> answered = const {},
  }) {
    final wanted = [
      for (final query in PrinterProbe.statusQueries)
        if (answered.isEmpty || answered.containsKey(query.name)) query,
    ];
    return PrinterProbe.run(
      transport,
      only: wanted.isEmpty ? PrinterProbe.statusQueries : wanted,
    );
  }

  /// Whether characterizing this printer would teach us anything.
  ///
  /// A printer already driven by a profile that has a status program *and* an
  /// exact value map has nothing left to give — its codes are known. Every
  /// other case does: no profile at all (the user picked one manually), a
  /// profile with no status handling (so out-of-labels currently surfaces as a
  /// blank label), or one still decoding an enumeration as a bitmask.
  static bool isUseful(PrinterProfile? profile) {
    if (profile == null) {
      return true;
    }
    if (profile.statusProgram.isEmpty) {
      return true;
    }
    return profile.statusFlags['values'] is! Map;
  }
}
