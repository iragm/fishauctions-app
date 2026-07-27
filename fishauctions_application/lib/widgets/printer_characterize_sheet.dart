import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/printer_device_info.dart';
import '../models/printer_profile.dart';
import '../services/bluetooth_service.dart';
import '../services/printer_characterization.dart';
import '../services/printer_probe.dart';
import '../services/printer_report_service.dart';

/// "Help us support this printer" — the guided capture that turns a printer
/// nobody has a profile for into a request someone can act on.
///
/// The flow the user sees is four button presses: put the printer in a state
/// the app describes, tap Capture, repeat. What it produces is the full
/// picture a profile needs — identity, GATT ids, command language, and the
/// status byte for ready / cover open / out of labels — sent to the backend
/// and also shown as copyable text, so the report survives a deployment
/// without the endpoint or a phone with no signal.
///
/// Offered when it would teach us something (see
/// [PrinterCharacterization.isUseful]); never forced, because a user who just
/// wants to print labels should be able to walk away from a diagnostics
/// wizard, and the pairing is already done by the time this appears.
class PrinterCharacterizeSheet extends StatefulWidget {
  const PrinterCharacterizeSheet({
    required this.info,
    required this.profile,
    required this.match,
    super.key,
  });

  final PrinterDeviceInfo info;
  final PrinterProfile? profile;
  final ProfileMatch match;

  static Future<void> show(
    BuildContext context, {
    required PrinterDeviceInfo info,
    required PrinterProfile? profile,
    required ProfileMatch match,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    // Physically fiddling with a printer takes both hands; a stray tap outside
    // shouldn't throw away three completed captures.
    isDismissible: false,
    enableDrag: false,
    builder: (_) =>
        PrinterCharacterizeSheet(info: info, profile: profile, match: match),
  );

  @override
  State<PrinterCharacterizeSheet> createState() =>
      _PrinterCharacterizeSheetState();
}

class _PrinterCharacterizeSheetState extends State<PrinterCharacterizeSheet> {
  int _step = 0;
  bool _capturing = false;
  bool _sending = false;
  bool _sent = false;
  String? _error;
  final Map<String, Map<String, PrinterReply>> _captures = {};

  bool get _done => _step >= PrinterCharacterization.steps.length;

  PrinterCharacterizationResult get _result => PrinterCharacterizationResult(
    info: widget.info,
    probeReplies: BluetoothService.instance.lastProbeReplies,
    gatt: BluetoothService.instance.lastGattTree,
    captures: _captures,
  );

  Future<void> _capture() async {
    final step = PrinterCharacterization.steps[_step];
    setState(() {
      _capturing = true;
      _error = null;
    });
    try {
      final replies = await PrinterCharacterization.capture(
        BluetoothService.instance,
        answered: BluetoothService.instance.lastProbeReplies,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _capturing = false;
        // An unanswered state is recorded as an empty map rather than skipped:
        // "this printer says nothing when the cover is open" is a finding, and
        // one that stops anyone writing a status program that waits forever.
        _captures[step.id] = replies;
        _step++;
      });
      if (_done) {
        unawaited(_send());
      }
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _capturing = false;
        _error =
            'Could not read the printer ($e). Make sure it is still on and '
            'in range, then try again.';
      });
    }
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    await PrinterReportService.instance.report(
      widget.info,
      profile: widget.profile,
      match: widget.match,
      probeReplies: BluetoothService.instance.lastProbeReplies,
      gatt: BluetoothService.instance.lastGattTree,
      characterization: _result,
    );
    if (mounted) {
      setState(() {
        _sending = false;
        _sent = true;
      });
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _result.summary));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Printer report copied.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Help us support this printer',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              _done
                  ? PrinterCharacterization.restoreInstruction
                  : 'Step ${_step + 1} of '
                        '${PrinterCharacterization.steps.length} · about a '
                        'minute. This tells us what your printer reports when '
                        'it runs out of labels, so the app can say so instead '
                        'of printing nothing.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: _done ? _buildDone(theme) : _buildStep(theme),
              ),
            ),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 8),
            ],
            _buildActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(ThemeData theme) {
    final step = PrinterCharacterization.steps[_step];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < PrinterCharacterization.steps.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              i < _step
                  ? Icons.check_circle
                  : (i == _step
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
              color: i < _step ? Colors.green : theme.colorScheme.outline,
            ),
            title: Text(PrinterCharacterization.steps[i].title),
            subtitle: i == _step ? Text(step.instruction) : null,
            // Show what each finished step actually read — it is the evidence
            // being collected, and seeing a byte change when the cover opens
            // is what tells the user this is doing something real.
            trailing: i < _step
                ? Text(
                    _readingFor(PrinterCharacterization.steps[i].id),
                    style: theme.textTheme.bodySmall,
                  )
                : null,
          ),
      ],
    );
  }

  String _readingFor(String stepId) {
    final byQuery = _captures[stepId];
    if (byQuery == null || byQuery.isEmpty) {
      return 'no reply';
    }
    return byQuery.values.first.hex.split(' ').first;
  }

  Widget _buildDone(ThemeData theme) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              _sent ? Icons.check_circle : Icons.cloud_upload,
              size: 18,
              color: _sent ? Colors.green : theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _sending
                    ? 'Sending your printer report…'
                    : (_sent
                          ? "Thanks — your printer's details are on their way. "
                                'Support for it is added on the server, so it '
                                'will start working without updating the app.'
                          : 'Report ready to send.'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('What we collected', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            result.summary,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['Courier'],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    if (_done) {
      return OverflowBar(
        alignment: MainAxisAlignment.end,
        children: [
          TextButton.icon(
            onPressed: _copy,
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy report'),
          ),
          FilledButton(
            onPressed: _sending ? null : () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    }
    return OverflowBar(
      alignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _capturing ? null : () => Navigator.of(context).pop(),
          child: const Text('Not now'),
        ),
        FilledButton.icon(
          onPressed: _capturing ? null : _capture,
          icon: _capturing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(_capturing ? 'Reading…' : 'Capture'),
        ),
      ],
    );
  }
}
