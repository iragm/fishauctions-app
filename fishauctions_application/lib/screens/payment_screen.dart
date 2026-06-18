import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/api_service.dart';

/// Square Tap to Pay checkout screen.
///
/// Flow:
///   1. POST /api/mobile/payments/create/ → Square config + idempotency key
///   2. Initialize Square In-Person SDK with returned params
///   3. User taps card → SDK returns source_id nonce
///   4. POST /api/mobile/payments/confirm/ → backend charges card
///   5. Show result and pop back to WebView
class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({required this.invoicePk, super.key});

  final int invoicePk;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic>? _paymentContext;

  @override
  void initState() {
    super.initState();
    _createPayment();
  }

  Future<void> _createPayment() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });

    try {
      final res = await ApiService.instance.dio.post(
        'payments/create/',
        data: {'invoice_pk': widget.invoicePk},
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _paymentContext = res.data as Map<String, dynamic>;
        _phase = _Phase.ready;
      });
    } on DioException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.response?.data?['detail'] as String? ??
            'Could not load invoice. Please try again.';
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _startTapToPay() async {
    if (_paymentContext == null) return;

    setState(() => _phase = _Phase.processing);

    // TODO: Initialize Square In-Person SDK with:
    //   applicationId: _paymentContext!['square_application_id']
    //   locationId:    _paymentContext!['location_id']
    //   environment:   _paymentContext!['square_environment']
    // Then call startPayment() to collect the card tap and get source_id.
    //
    // Once source_id is obtained, call _confirmPayment(sourceId).
    //
    // Placeholder: show a snackbar until SDK is integrated.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Square SDK integration pending — see CLAUDE.md'),
        ),
      );
      setState(() => _phase = _Phase.ready);
    }
  }

  Future<void> _confirmPayment(String sourceId) async {
    final ctx = _paymentContext!;
    try {
      final res = await ApiService.instance.dio.post(
        'payments/confirm/',
        data: {
          'invoice_pk': widget.invoicePk,
          'source_id': sourceId,
          'idempotency_key': ctx['idempotency_key'],
        },
      );
      final data = res.data as Map<String, dynamic>;
      setState(() => _phase = _Phase.success);
      if (mounted) {
        await _showResult(
          success: true,
          message: 'Payment confirmed — ${data['receipt_number'] ?? data['payment_id']}',
        );
        context.pop();
      }
    } on DioException catch (e) {
      final msg = e.response?.data?['detail'] as String? ?? 'Payment failed.';
      setState(() {
        _error = msg;
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _showResult({
    required bool success,
    required String message,
  }) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(success ? 'Payment Complete' : 'Payment Failed'),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tap to Pay')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_phase) {
            _Phase.loading => const Center(child: CircularProgressIndicator()),
            _Phase.error => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _error ?? 'Something went wrong.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _createPayment,
                    child: const Text('Try Again'),
                  ),
                ],
              ),
            _Phase.ready => _ReadyView(
                context: _paymentContext!,
                onPay: _startTapToPay,
              ),
            _Phase.processing => const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Processing payment…'),
                ],
              ),
            _Phase.success => const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle, size: 80, color: Colors.green),
                  SizedBox(height: 16),
                  Text('Payment complete!'),
                ],
              ),
          },
        ),
      ),
    );
  }
}

enum _Phase { loading, ready, processing, success, error }

class _ReadyView extends StatelessWidget {
  const _ReadyView({required this.context, required this.onPay});

  final Map<String, dynamic> context;
  final VoidCallback onPay;

  @override
  Widget build(BuildContext _) {
    final amount = context['amount'] as String? ?? '—';
    final currency = context['currency'] as String? ?? '';

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.contactless, size: 80),
        const SizedBox(height: 16),
        Text(
          '$currency $amount',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Hold your card or device near the reader',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 40),
        FilledButton.icon(
          onPressed: onPay,
          icon: const Icon(Icons.nfc),
          label: const Text('Tap to Pay'),
        ),
      ],
    );
  }
}
