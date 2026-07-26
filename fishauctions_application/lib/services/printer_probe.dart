import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'printer_transport.dart';

/// One question to ask an unidentified printer, and what language it's from.
typedef PrinterQuery = ({String name, String language, List<int> bytes});

/// What a printer said back to a [PrinterQuery].
typedef PrinterReply = ({String hex, String ascii});

/// Asks an unknown printer a short list of read-only questions and records
/// whatever it says back.
///
/// This exists so that supporting a new printer is a *data* task. When a
/// printer matches no profile the app currently has to ask the user what it
/// is, and the only evidence anyone has to author a profile from is a BLE
/// name and whatever the Device Information Service volunteered — which on
/// the VEVOR Y486BT is "Feasycom FSC-BT986", the radio module, not the
/// printer. Replies to these queries are far more telling: which of them
/// answers at all identifies the command language, and the contents often
/// carry a model string or the loaded media size.
///
/// The replies ride along to `printers/observed/`, so the profile author is
/// working from what the hardware actually does rather than from a guess.
///
/// **Every query here must be read-only.** These get sent to hardware nobody
/// has characterised yet, so the rule is: status and identity requests only,
/// nothing that configures the printer, feeds media, or begins a label.
class PrinterProbe {
  const PrinterProbe._();

  /// How long to wait for each answer. Printers that implement a query answer
  /// it almost immediately; the ones that don't never will, and the whole
  /// sweep has to stay inside a pairing flow a human is watching.
  static const perQueryTimeout = Duration(milliseconds: 700);

  static List<int> _ascii(String s) => latin1.encode(s);

  /// The questions, ordered cheapest/safest first. Each is the standard
  /// status or identity request of one of the command languages these
  /// printers actually ship with.
  static final List<PrinterQuery> queries = [
    // TSPL <ESC>!? — one status byte. TSC-compatible label printers.
    (name: 'tspl_status', language: 'tspl', bytes: const [0x1b, 0x21, 0x3f]),
    // TSPL system commands: model/version, then code page + country.
    (name: 'tspl_model', language: 'tspl', bytes: _ascii('~!T\r\n')),
    (name: 'tspl_codepage', language: 'tspl', bytes: _ascii('~!I\r\n')),
    // ESC/POS DLE EOT n — real-time status. Receipt-style printers.
    (
      name: 'escpos_status',
      language: 'escpos',
      bytes: const [0x10, 0x04, 0x01],
    ),
    // ESC/POS GS I n — printer id / model.
    (name: 'escpos_id', language: 'escpos', bytes: const [0x1d, 0x49, 0x01]),
    // ZPL ~HS — host status, three lines including media settings.
    (name: 'zpl_host_status', language: 'zpl', bytes: _ascii('~HS\r\n')),
    // CPCL getvar — Zebra mobile printers answer with the value.
    (
      name: 'cpcl_product_name',
      language: 'cpcl',
      bytes: _ascii('! U1 getvar "device.product_name"\r\n'),
    ),
    // The D11s vendor status byte, for the cheap 12 mm BLE printers.
    (name: 'd11s_status', language: 'd11s', bytes: const [0x10, 0xff, 0x40]),
  ];

  /// Sends every query in turn over [transport] and returns the ones that got
  /// an answer, keyed by query name. Queries that go unanswered are simply
  /// absent — that silence is itself the useful signal, and reporting a map of
  /// empty strings would only make the record harder to read.
  ///
  /// Never throws: a probe is diagnostics running inside a pairing flow, and
  /// a printer that dislikes one of these must not break the pairing.
  static Future<Map<String, PrinterReply>> run(
    PrinterTransport transport, {
    Duration timeout = perQueryTimeout,
  }) async {
    final results = <String, PrinterReply>{};
    // Subscribe once for the whole sweep: several of these printers answer a
    // moment late, and a per-query subscription would drop those replies.
    final frames = <Uint8List>[];
    StreamSubscription<Uint8List>? sub;
    try {
      sub = transport.notifications.listen(frames.add);
      for (final query in queries) {
        if (!transport.isConnected) {
          break;
        }
        frames.clear();
        try {
          await transport.write(query.bytes);
        } on Object {
          continue; // Rejected write — try the next language.
        }
        await Future<void>.delayed(timeout);
        if (frames.isEmpty) {
          continue;
        }
        final joined = <int>[for (final f in frames) ...f];
        results[query.name] = (hex: _hex(joined), ascii: _printable(joined));
      }
    } on Object {
      // Fall through with whatever was collected.
    } finally {
      await sub?.cancel();
    }
    return results;
  }

  /// Cap on how much of a reply to keep — enough for a model string or a ZPL
  /// status block, without shipping a stuck printer's entire output stream.
  static const _maxReplyBytes = 128;

  static String _hex(List<int> bytes) => bytes
      .take(_maxReplyBytes)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');

  static String _printable(List<int> bytes) => String.fromCharCodes([
    for (final b in bytes.take(_maxReplyBytes))
      (b >= 0x20 && b < 0x7f) ? b : 0x2e,
  ]);

  /// The command language implied by which queries answered, or null when
  /// nothing did. A first guess for the profile author — and, once profiles
  /// exist per language, the hook for choosing one without asking the user.
  static String? languageFrom(Map<String, PrinterReply> replies) {
    for (final query in queries) {
      if (replies.containsKey(query.name)) {
        return query.language;
      }
    }
    return null;
  }
}
