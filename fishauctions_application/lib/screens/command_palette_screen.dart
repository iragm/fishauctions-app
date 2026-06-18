import 'dart:async';

import 'package:flutter/material.dart';

import '../models/command_palette_models.dart';
import '../services/command_palette_service.dart';

/// Opens the command palette as a full-screen dialog.
///
/// [navigateToPath] is called with a server-relative web path when the user
/// taps a result — the caller is responsible for loading it in the WebView.
Future<void> showCommandPalette(
  BuildContext context,
  void Function(String path) navigateToPath,
) =>
    showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (_) => _CommandPaletteDialog(navigateToPath: navigateToPath),
    );

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog({required this.navigateToPath});

  final void Function(String path) navigateToPath;

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  List<PaletteGroup> _groups = [];
  bool _loading = false;
  int? _sessionId;
  int _lastResultCount = 0;
  bool _hasSearched = false;
  String _currentQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchResults('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _fetchResults(String q) async {
    setState(() => _loading = true);
    try {
      final groups = await CommandPaletteService.instance.search(q);
      final count = groups.fold(0, (sum, g) => sum + g.items.length);
      if (!mounted) {
        return;
      }
      setState(() {
        _groups = groups;
        _lastResultCount = count;
        _loading = false;
      });
      if (q.isNotEmpty) {
        _hasSearched = true;
        _currentQuery = q;
        final result = count > 0 ? 'pending' : 'bounce';
        final id = await CommandPaletteService.instance.log(
          id: _sessionId,
          search: q,
          result: result,
        );
        if (mounted) {
          _sessionId = id;
        }
      }
    } on Exception catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    if (q.isEmpty) {
      _fetchResults('');
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _fetchResults(q),
    );
  }

  void _onItemTap(PaletteItem item) {
    if (item.type == 'search') {
      _textController.text = item.title;
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: item.title.length),
      );
      _fetchResults(item.title);
      return;
    }

    // Fire-and-forget: don't block navigation on the log round-trip.
    CommandPaletteService.instance.log(
      id: _sessionId,
      search: _currentQuery,
      result: 'clicked',
      resultType: item.type,
      resultUrl: item.url,
      resultObjectId: item.id,
    );

    Navigator.of(context).pop();
    widget.navigateToPath(item.url);
  }

  void _handleClose() {
    if (_hasSearched && _lastResultCount > 0) {
      CommandPaletteService.instance.log(
        id: _sessionId,
        search: _currentQuery,
        result: 'abandoned',
      );
    }
    Navigator.of(context).pop();
  }

  List<Widget> _buildResultItems(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final items = <Widget>[];
    for (final group in _groups) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            group.label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
              letterSpacing: 0.8,
            ),
          ),
        ),
      );
      for (final item in group.items) {
        items.add(
          ListTile(
            dense: true,
            leading: Icon(
              _biIcon(item.icon),
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: item.subtitle.isNotEmpty
                ? Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            onTap: () => _onItemTap(item),
          ),
        );
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _handleClose();
        }
      },
      child: Dialog.fullscreen(
        child: SafeArea(
          child: Column(
            children: [
              // ── Search bar ────────────────────────────────────────────────
              Material(
                elevation: 2,
                color: theme.colorScheme.surface,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: 'Close',
                        onPressed: _handleClose,
                      ),
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          focusNode: _focusNode,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          decoration: const InputDecoration(
                            hintText: 'Search auctions, lots, clubs…',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: _onQueryChanged,
                        ),
                      ),
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else if (_textController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear',
                          onPressed: () {
                            _textController.clear();
                            _fetchResults('');
                          },
                        ),
                    ],
                  ),
                ),
              ),
              // ── Results ───────────────────────────────────────────────────
              Expanded(
                child: _groups.isEmpty && !_loading
                    ? Center(
                        child: Text(
                          'No results',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 16),
                        children: _buildResultItems(context),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Maps a Bootstrap Icons class name to the closest Material icon.
IconData _biIcon(String bi) {
  const icons = <String, IconData>{
    'bi-grid': Icons.grid_view,
    'bi-hammer': Icons.gavel,
    'bi-tag': Icons.sell,
    'bi-tags': Icons.local_offer,
    'bi-people': Icons.group_outlined,
    'bi-people-fill': Icons.group,
    'bi-person': Icons.person_outline,
    'bi-person-badge': Icons.badge_outlined,
    'bi-person-vcard': Icons.contact_page_outlined,
    'bi-person-fill-lock': Icons.lock_person,
    'bi-person-fill': Icons.person,
    'bi-bag': Icons.shopping_bag_outlined,
    'bi-bag-heart': Icons.favorite_border,
    'bi-bag-check': Icons.check_circle_outline,
    'bi-bag-heart-fill': Icons.favorite,
    'bi-printer': Icons.print,
    'bi-gear': Icons.settings_outlined,
    'bi-clock-history': Icons.history,
    'bi-calendar-event': Icons.event_outlined,
    'bi-calendar-check': Icons.event_available_outlined,
    'bi-arrow-right-short': Icons.arrow_forward,
    'bi-plus-circle': Icons.add_circle_outline,
    'bi-card-list': Icons.list_alt_outlined,
    'bi-award': Icons.emoji_events_outlined,
    'bi-map': Icons.map_outlined,
    'bi-envelope': Icons.mail_outline,
    'bi-envelope-at': Icons.alternate_email,
    'bi-discord': Icons.chat_bubble_outline,
    'bi-credit-card': Icons.credit_card_outlined,
    'bi-key': Icons.key_outlined,
    'bi-paypal': Icons.payment,
    'bi-sliders': Icons.tune,
    'bi-house': Icons.home_outlined,
    'bi-qr-code-scan': Icons.qr_code_scanner,
    'bi-input-cursor-text': Icons.text_fields,
    'bi-telephone-fill': Icons.phone,
    'bi-google': Icons.language,
    'bi-star': Icons.star_outline,
    'bi-heart': Icons.favorite_border,
  };
  return icons[bi] ?? Icons.arrow_forward_ios;
}
