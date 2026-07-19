import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/offline_sync_service.dart';

/// Offline mirror of the web users page's "Add user" modal — the subset of
/// its fields that matter with no connection (bidder number, name, email,
/// phone). The bidder number is pre-filled with the next free one so the
/// admin can hand it to the person on the spot; the server keeps it on sync
/// unless someone claimed it meanwhile (which surfaces as a conflict).
class OfflineAddUserScreen extends StatefulWidget {
  const OfflineAddUserScreen({super.key});

  @override
  State<OfflineAddUserScreen> createState() => _OfflineAddUserScreenState();
}

class _OfflineAddUserScreenState extends State<OfflineAddUserScreen> {
  final _service = OfflineSyncService.instance;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _bidderNumber;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _bidderNumber = TextEditingController(
      text: _service.store.nextBidderNumber(),
    );
  }

  @override
  void dispose() {
    _bidderNumber.dispose();
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  String? _validateBidderNumber(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) {
      return 'Enter a bidder number';
    }
    if (_service.store.findUserByBidder(v) != null) {
      return 'This bidder number is already in use';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    final name = _name.text.trim();
    final bidder = _bidderNumber.text.trim();
    await _service.recordedOp(
      (store) => store.addUser(
        bidderNumber: bidder,
        name: name,
        email: _email.text.trim(),
        phoneNumber: _phone.text.trim(),
      ),
    );
    if (mounted) {
      context.pop('Added $name as bidder $bidder');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add user')),
    body: Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _bidderNumber,
            decoration: const InputDecoration(
              labelText: 'Bidder number',
              border: OutlineInputBorder(),
            ),
            validator: _validateBidderNumber,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                (v?.trim().isEmpty ?? true) ? 'Enter a name' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email (optional)',
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              final email = v?.trim() ?? '';
              if (email.isNotEmpty && !email.contains('@')) {
                return 'Enter a valid email';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : () => unawaited(_save()),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
