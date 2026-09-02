import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tap_to_pay_diagnostics.dart';
import '../models/tap_to_pay_status.dart';
import '../providers/config_provider.dart';
import '../services/square_payment_service.dart';
import '../services/tap_to_pay_service.dart';
import '../widgets/tap_to_pay_branding.dart';

/// The app's Tap to Pay on iPhone settings and merchant-education screen.
///
/// Apple's app-review guide requires several things that a checkout-only
/// integration can't provide, and this screen is where they live:
///
/// - **3.4** show how to enable Tap to Pay at the end of merchant onboarding
///   (the onboarding banner links here).
/// - **3.6** enablement must be reachable *outside* the awareness and checkout
///   flows — "such as through your app settings". Hence the drawer entry.
/// - **3.5** a clear action to accept Apple's Terms and Conditions.
/// - **3.8 / 3.8.1** only an authorized merchant may accept them; anyone else
///   is told to contact an admin.
/// - **3.9** after acceptance and education, invite them to try it out.
/// - **3.9.1** show a configuration-progress indicator while the reader gets
///   ready, so "not ready yet" is never silent.
/// - **4.2 / 4.3** education after acceptance, and education permanently
///   available in settings for later reference.
///
/// The education itself is Apple's own sheet (`ProximityReaderDiscovery`), not
/// ours: the same guide forbids writing custom copy or illustrations depicting
/// Tap to Pay on iPhone, and Apple keeps its version current and localized. The
/// text fallback below is only for iOS 17 and earlier, where that API doesn't
/// exist.
class TapToPayScreen extends ConsumerStatefulWidget {
  const TapToPayScreen({super.key});

  @override
  ConsumerState<TapToPayScreen> createState() => _TapToPayScreenState();
}

class _TapToPayScreenState extends ConsumerState<TapToPayScreen> {
  final _service = TapToPayService.instance;

  /// Whether Apple's terms are accepted on this device. Re-read from the SDK on
  /// every refresh and never cached across a rebuild — requirement 1.6.
  bool _enabled = false;
  TapToPayUnsupportedReason _unsupported = TapToPayUnsupportedReason.none;
  bool _loading = true;

  /// Set while the Apple terms sheet is up, so the button can't be double-fired
  /// and the user gets a spinner instead of a dead press.
  bool _enabling = false;

  /// Why Apple's education sheet last failed to appear, or null.
  ///
  /// From iOS 18 requirement 4.1 makes that sheet mandatory, so falling back to
  /// the text below is a defect there rather than the graceful path it is on
  /// iOS 17 — and the two are indistinguishable to anyone looking at the
  /// screen. Shown so they aren't.
  String? _educationError;

  /// The last troubleshooting snapshot, or null until one is run.
  TapToPayDiagnostics? _diagnostics;
  bool _diagnosing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final unsupported = await _service.unsupportedReason();
    // Only ask about terms on a device that could use them — on an unsupported
    // device the SDK call is meaningless and may throw.
    final enabled = unsupported.isSupported && await _service.isEnabled();
    // Re-fetch eligibility so a Square account linked on the website a moment
    // ago is reflected without an app restart.
    final cfg = await ref
        .read(configProvider.future)
        .catchError((_) => throw Exception('config'));
    unawaited(
      _service.prepare(
        applicationId: cfg.hasSquare ? cfg.squareApplicationId : null,
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _unsupported = unsupported;
      _enabled = enabled;
      _loading = false;
    });
  }

  /// Requirement 3.5's explicit acceptance action, followed immediately by
  /// requirement 4.2's education. Both are Apple's own sheets.
  Future<void> _enable() async {
    setState(() => _enabling = true);
    try {
      final ok = await _service.enable();
      if (!mounted) {
        return;
      }
      setState(() {
        _enabled = ok;
        _enabling = false;
      });
      if (ok) {
        // 4.2: education comes *after* the terms are accepted.
        await _showEducation();
      }
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() => _enabling = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Setting up Tap to Pay on iPhone was cancelled or failed. '
            'You can try again any time.',
          ),
        ),
      );
    }
  }

  /// Collects the troubleshooting snapshot.
  ///
  /// This is the screen's answer to a failure mode with no other witness: when
  /// Square declines to arm the reader it shows a native "connect hardware to
  /// take card payments" prompt carrying no error, no code and no text, so
  /// without this the only way to tell "NFC is off" from "the merchant account
  /// is not activated" from "the app attestation was rejected" is a rebuild
  /// with a debugger attached.
  Future<void> _runDiagnostics() async {
    setState(() => _diagnosing = true);
    String? applicationId;
    try {
      final cfg = await ref.read(configProvider.future);
      applicationId = cfg.hasSquare ? cfg.squareApplicationId : null;
    } on Object {
      // Config not loaded (offline cold start). The rest of the snapshot is
      // still worth having, and the missing app id is itself reported.
      applicationId = null;
    }
    final report = await _service.diagnose(applicationId: applicationId);
    if (!mounted) {
      return;
    }
    setState(() {
      _diagnostics = report;
      _diagnosing = false;
    });
  }

  /// Puts this device back to its pre-setup state so Apple's onboarding and
  /// education flows can be recorded again, then offers the Apple Account
  /// sheet — the one step no reset can clear, since the SDK has no unlink.
  Future<void> _resetForRecording() async {
    final failures = await _service.resetForRecording();
    if (!mounted) {
      return;
    }
    setState(() => _diagnostics = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failures.isEmpty
              ? 'Reset. The awareness moment fires again on the next auction '
                    'page, and the reader arms from cold.'
              : 'Partly reset — ${failures.join('; ')}',
        ),
        duration: const Duration(seconds: 8),
      ),
    );
    if (!_service.isApplePlatform) {
      return;
    }
    try {
      await SquarePaymentService.instance.relinkAppleAccount();
    } on Object catch (e) {
      // Cancelling the sheet lands here and is the normal way out of it.
      debugPrint('Apple account relink not completed: $e');
    }
  }

  /// Apple's education sheet, with a text fallback for iOS 17 and earlier.
  Future<void> _showEducation() async {
    if (await _service.presentEducation()) {
      if (mounted && _educationError != null) {
        setState(() => _educationError = null);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _educationError = _service.lastEducationError);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _EducationFallbackSheet(),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(tapToPayName)),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [
                const TapToPayHeader(),
                const SizedBox(height: 24),
                ..._statusSection(context),
                const SizedBox(height: 24),
                // 4.3: education stays permanently available here, whether or
                // not the merchant has finished setup.
                OutlinedButton.icon(
                  onPressed: _showEducation,
                  icon: const Icon(Icons.school_outlined),
                  label: const Text('How to take a payment'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Learn how to accept contactless cards, Apple Pay and other '
                  'digital wallets, and what to do when a customer is asked '
                  'for a PIN.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_educationError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    "Apple's own guide couldn't be shown on this iPhone, "
                    'so the summary above was used instead. '
                    'Reason: $_educationError',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                _TroubleshootingSection(
                  diagnostics: _diagnostics,
                  running: _diagnosing,
                  onRun: _runDiagnostics,
                  onReset: _resetForRecording,
                ),
              ],
            ),
          ),
  );

  /// The state-dependent middle of the screen: what's blocking, what to press.
  List<Widget> _statusSection(BuildContext context) {
    // An unsupported device is terminal — but 1.4 insists the *reason* be
    // honest, because "update your iPhone" and "this iPhone will never work"
    // lead the merchant to completely different actions.
    if (!_unsupported.isSupported) {
      return [
        _StatusCard(
          icon: Icons.phonelink_erase,
          tone: _Tone.warning,
          title: _unsupported == TapToPayUnsupportedReason.osVersion
              ? 'Update to the latest iOS'
              : 'This device can\'t use $tapToPayName',
          body: _unsupported == TapToPayUnsupportedReason.osVersion
              ? 'Update your iPhone in Settings › General › Software Update, '
                    'then come back here. $tapToPayName needs an iPhone XS or '
                    'later running an up-to-date version of iOS.'
              : '$tapToPayName needs an iPhone XS or later. You can still take '
                    'payments from another device, or have your customer pay '
                    'their invoice online.',
        ),
      ];
    }

    return [
      // Eligibility is the backend's call (3.8): only an admin of an auction
      // with a linked Square account may accept Apple's terms.
      ValueListenableBuilder<TapToPayEligibility?>(
        valueListenable: _service.eligibility,
        builder: (context, eligibility, _) {
          // Unknown (no endpoint, or offline) is deliberately permissive: the
          // charge path enforces authorization server-side anyway, and blocking
          // setup on a fetch that may never succeed would strand a legitimate
          // merchant at an auction with bad wifi.
          if (eligibility != null && !eligibility.canAcceptTerms) {
            // 3.8.1: tell an unauthorized user who to ask.
            return _StatusCard(
              icon: Icons.admin_panel_settings_outlined,
              tone: _Tone.info,
              title: 'Ask an admin to set this up',
              body:
                  eligibility.message ??
                  'Only an auction or club admin with a connected Square '
                      'account can set up $tapToPayName. Ask the organizer to '
                      'connect Square and give you admin access.',
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (eligibility?.sellerName != null) ...[
                Text(
                  'Paying into ${eligibility!.sellerName}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
              ],
              if (_enabled) ..._enabledState(context) else ..._setupState(),
            ],
          );
        },
      ),
    ];
  }

  /// Set up and ready: show the reader's readiness (3.9.1) and — per 3.9 —
  /// invite them to try it.
  List<Widget> _enabledState(BuildContext context) => [
    ValueListenableBuilder<TapToPayReaderStatus>(
      valueListenable: _service.status,
      builder: (context, status, _) {
        final blocked = status == TapToPayReaderStatus.unavailable;
        // Square's own account of the refusal. Nothing else has one: by the
        // time the cashier hits the charge path there is no catchable error
        // left, only the native "connect hardware" screen.
        final reason = _service.lastUnavailableReason;
        final String body;
        if (status.isReady) {
          body =
              'Open an invoice from a checkout page and tap the '
              '$tapToPayName button to take a payment.';
        } else if (blocked && reason != null) {
          body =
              '${describeUnavailableReason(reason)}\n\n'
              'Square reported: $reason';
        } else if (blocked) {
          body =
              'Square could not get the reader ready and did not say why. '
              'Open Troubleshooting below for the full picture.';
        } else {
          body =
              'Your iPhone is finishing setup. This usually takes a few '
              'seconds and happens automatically.';
        }
        return _StatusCard(
          icon: status.isReady
              ? Icons.check_circle_outline
              : blocked
              ? Icons.error_outline
              : Icons.sync,
          tone: status.isReady
              ? _Tone.success
              : blocked
              ? _Tone.warning
              : _Tone.info,
          title: status.isReady ? '$tapToPayName is ready' : status.message,
          body: body,
          // 3.9.1: the progress indicator itself.
          progress: status.isBusy,
        );
      },
    ),
  ];

  /// Not set up yet — 3.5's clear acceptance action.
  ///
  /// **No contactless glyph anywhere in here.** Requirement 5.5 allows only SF
  /// Symbols' `wave.3.right.circle[.fill]` on a Tap to Pay control, and the
  /// marketing rules separately forbid any icon that depicts the capability —
  /// so a Material lookalike is worse than no icon, and this button and card
  /// used to carry `Icons.contactless` / `Icons.contactless_outlined`. The
  /// reasoning, and how to add Apple's real symbol, is in
  /// `tap_to_pay_branding.dart`; `tapToPaySymbolAsset` is the slot for it.
  List<Widget> _setupState() => [
    const _StatusCard(
      icon: Icons.info_outline,
      tone: _Tone.info,
      title: 'Set up $tapToPayName',
      body:
          'Accept Apple\'s Terms and Conditions to start taking contactless '
          'payments on this iPhone. You only do this once per device.',
    ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: _enabling ? null : _enable,
      child: _enabling
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Setting up…'),
              ],
            )
          : const Text('Set up $tapToPayName'),
    ),
  ];
}

enum _Tone { info, success, warning }

/// One status block: icon, headline, explanation, and optionally the
/// configuration progress bar Apple's 3.9.1 requires.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.tone,
    required this.title,
    required this.body,
    this.progress = false,
  });

  final IconData icon;
  final _Tone tone;
  final String title;
  final String body;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      _Tone.info => (scheme.surfaceContainerHighest, scheme.onSurface),
      _Tone.success => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _Tone.warning => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: TextStyle(color: fg, height: 1.35)),
          if (progress) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                backgroundColor: fg.withValues(alpha: 0.15),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Everything the app can find out about whether a tap would work, collapsed
/// by default and copyable.
///
/// Collapsed because this is a merchant settings screen, not a debug console.
/// Present, because the failure it explains has no other witness: Square shows
/// one opaque "connect hardware to take card payments" prompt for every cause,
/// so without this the only way to tell them apart is a signed rebuild per
/// hypothesis — which is exactly how this feature lost several days.
class _TroubleshootingSection extends StatelessWidget {
  const _TroubleshootingSection({
    required this.diagnostics,
    required this.running,
    required this.onRun,
    required this.onReset,
  });

  final TapToPayDiagnostics? diagnostics;
  final bool running;
  final Future<void> Function() onRun;
  final Future<void> Function() onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = diagnostics;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: const Text('Troubleshooting'),
        subtitle: const Text('Check what this iPhone reports'),
        // Collected on first expand rather than on screen load: it wakes the
        // Square SDK and the reader, which is not something a merchant who
        // came here to read the education should pay for.
        onExpansionChanged: (open) {
          if (open && report == null && !running) {
            unawaited(onRun());
          }
        },
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (running)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (report == null)
            const Text('Nothing checked yet.')
          else ...[
            if (report.headline != null) ...[
              Text(
                report.headline!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              // Selectable as well as copyable: on a phone in a noisy room,
              // reading one line out loud beats mailing the whole block.
              child: SelectableText(
                report.toReport(),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(_copy(context, report)),
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Copy'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: running ? null : () => unawaited(onRun()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Re-check'),
                  ),
                ),
              ],
            ),
          ],
          // Outside the `else` above so it works before anything is collected:
          // the state this clears is exactly what a stuck device has.
          const Divider(height: 32),
          TextButton.icon(
            onPressed: () => unawaited(onReset()),
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset for re-recording'),
          ),
          Text(
            'Clears the one-time awareness moment and releases this device\'s '
            'Square authorization, then re-opens the Apple Account sheet, so '
            'the setup flow can be recorded again. Does not affect payments '
            'already taken.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, TapToPayDiagnostics report) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: report.toReport()));
    messenger.showSnackBar(
      const SnackBar(content: Text('Diagnostics copied.')),
    );
  }
}

/// Text-only merchant education for iOS 17 and earlier, where Apple's
/// `ProximityReaderDiscovery` sheet doesn't exist.
///
/// Kept deliberately plain — no illustrations, no depictions of an iPhone or of
/// the Tap to Pay interface, because Apple's marketing rules forbid creating
/// custom imagery for Tap to Pay on iPhone. The wording covers what the guide's
/// education requirements list: contactless cards (4.5), Apple Pay and other
/// digital wallets (4.6), and PIN entry (4.7, required in every region except
/// Japan and Taiwan). On iOS 18+ none of this is shown; Apple's own sheet is.
class _EducationFallbackSheet extends StatelessWidget {
  const _EducationFallbackSheet();

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How to take a payment',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          const _EducationStep(
            number: '1',
            text:
                'Enter the amount and tap the $tapToPayName button on the '
                'checkout page.',
          ),
          const _EducationStep(
            number: '2',
            text:
                'Hold your iPhone steady and ask the customer to hold their '
                'contactless card, iPhone, or Apple Watch near the top of your '
                'iPhone, over the contactless symbol. Other digital wallets '
                'work the same way.',
          ),
          const _EducationStep(
            number: '3',
            text:
                'Wait for the checkmark. Some cards ask the customer to enter '
                'a PIN on your iPhone — hand them the phone, and they can use '
                'the accessibility options on the PIN screen if they need to.',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _EducationStep extends StatelessWidget {
  const _EducationStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            number,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ],
    ),
  );
}
