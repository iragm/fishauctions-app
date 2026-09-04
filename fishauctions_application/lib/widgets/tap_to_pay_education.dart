import 'package:flutter/material.dart';

import '../services/tap_to_pay_service.dart';
import 'tap_to_pay_branding.dart';

/// Presents Apple's merchant-education sheet, falling back to [
/// TapToPayEducationFallbackSheet] when it can't be shown.
///
/// Returns null when Apple's own sheet appeared, or the reason it didn't —
/// which the settings screen surfaces, because from iOS 18 requirement 4.1
/// makes that sheet mandatory and a silent fallback there is a defect rather
/// than the graceful path it is on iOS 17.
///
/// Shared rather than private to the settings screen because education has two
/// callers, not one: requirement 4.2 wants it after *every* acceptance of the
/// terms, and the terms can be accepted from checkout (requirement 3.7's
/// in-checkout enablement trigger) as easily as from settings. It used to live
/// on the settings screen alone, so a merchant whose first-ever acceptance
/// happened at a checkout — the likeliest way it happens, since that is where
/// the pressure to set up comes from — was never educated at all.
Future<String?> showTapToPayEducation(BuildContext context) async {
  final service = TapToPayService.instance;
  if (await service.presentEducation()) {
    return null;
  }
  if (!context.mounted) {
    return service.lastEducationError;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const TapToPayEducationFallbackSheet(),
  );
  return service.lastEducationError;
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
class TapToPayEducationFallbackSheet extends StatelessWidget {
  const TapToPayEducationFallbackSheet({super.key});

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
