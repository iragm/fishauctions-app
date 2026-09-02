import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/command_palette_models.dart';
import '../models/last_used_auction.dart';
import '../services/command_palette_logger.dart';
import '../services/command_palette_service.dart';
import '../services/last_used_auction_service.dart';
import '../services/location_service.dart';
import '../services/tap_to_pay_service.dart';
import '../utils/bi_icons.dart';
import '../widgets/tap_to_pay_branding.dart';

/// Opens the command palette as a full-screen dialog.
///
/// [navigateToPath] is called with a server-relative web path when the user
/// taps a result — the caller is responsible for loading it in the WebView.
/// [onOpenAr] is called with an auction slug when the user taps the locally
/// injected AR entry (see [_CommandPaletteDialogState._arItem]) — AR is a
/// native camera screen, not a web path, so it can't go through
/// [navigateToPath]. [onOpenTapToPay] is the same arrangement for the Tap to
/// Pay entry, which needs no argument at all (its route is fixed).
Future<void> showCommandPalette(
  BuildContext context,
  void Function(String path) navigateToPath, {
  void Function(String auctionSlug)? onOpenAr,
  void Function()? onOpenTapToPay,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (_) => _CommandPaletteDialog(
    navigateToPath: navigateToPath,
    onOpenAr: onOpenAr,
    onOpenTapToPay: onOpenTapToPay,
  ),
);

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog({
    required this.navigateToPath,
    this.onOpenAr,
    this.onOpenTapToPay,
  });

  final void Function(String path) navigateToPath;
  final void Function(String auctionSlug)? onOpenAr;
  final void Function()? onOpenTapToPay;

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  final _logger = CommandPaletteLogger();
  Timer? _debounce;

  List<PaletteGroup> _serverGroups = [];
  bool _loading = false;

  /// The last search couldn't reach the server (vs. legitimately matching
  /// nothing). Drives the empty state's wording.
  bool _searchFailed = false;

  // AR command palette entry (BACKEND_SPEC.md "AR Command Palette Entry —
  // Last-Used-Auction Lookup"). Loaded once alongside the default results;
  // [_groups] injects a local AR item on top of whatever the server returned,
  // since AR is a native screen the server can't hand back as a URL.
  LastUsedAuction? _lastUsedAuction;
  Position? _arPosition;

  /// 10 miles, in meters — the "near your last in-person auction" radius.
  static const _arRadiusMeters = 10 * 1609.344;

  @override
  void initState() {
    super.initState();
    _fetchResults('');
    unawaited(_loadArContext());
  }

  /// Loads the last-used-auction lookup and a best-effort GPS fix, in
  /// parallel with the default search results. Never prompts for location
  /// permission — [LocationService.positionIfPermitted] only returns a fix
  /// when permission was already granted, matching the "no location
  /// permission ⇒ still show it" rule in [_arItem].
  Future<void> _loadArContext() async {
    final results = await Future.wait([
      LastUsedAuctionService.instance.fetch(),
      LocationService.instance.positionIfPermitted(fresh: false),
    ]);
    if (!mounted) {
      return;
    }
    setState(() {
      _lastUsedAuction = results[0] as LastUsedAuction?;
      _arPosition = results[1] as Position?;
    });
  }

  /// The rendered groups: the server's results with a local "Lot scanning"
  /// group prepended when it applies to the current query.
  List<PaletteGroup> get _groups {
    final ar = _arItem(_textController.text);
    final tapToPay = _tapToPayItem(_textController.text);
    return [
      if (ar != null) PaletteGroup(label: 'Lot scanning', items: [ar]),
      if (tapToPay != null)
        PaletteGroup(label: tapToPayName, items: [tapToPay]),
      ..._serverGroups,
    ];
  }

  /// The Tap to Pay entry for [query], or null when it doesn't apply.
  ///
  /// Same shape as [_arItem]: a native screen the server can't hand back as a
  /// URL, shown either because it's relevant (the backend says this user is a
  /// merchant) or because the user explicitly searched for it.
  ///
  /// Asking by name works **even when eligibility is unknown**, which matters
  /// twice over. It's the only way in on a deployment that doesn't serve
  /// `payments/authorization/` yet — otherwise the drawer tile is hidden, the
  /// awareness modal never fires, and `/tap-to-pay` is unreachable. And it
  /// rescues a real merchant whose eligibility fetch simply failed, who would
  /// otherwise be told nothing and offered nothing.
  PaletteItem? _tapToPayItem(String query) {
    if (!TapToPayService.instance.isApplePlatform) {
      return null;
    }
    final eligible =
        TapToPayService.instance.eligibility.value?.eligible ?? false;
    if (!eligible && !_tapToPayQueryMatches(query)) {
      return null;
    }
    return const PaletteItem(
      type: 'tap_to_pay',
      title: 'Set up $tapToPayName',
      subtitle: 'Take contactless card payments on this iPhone',
      // No URL — the palette logger records the type, and [_handleTap] routes
      // by type rather than navigating the web shell.
      url: '',
      icon: 'bi-credit-card',
    );
  }

  bool _tapToPayQueryMatches(String q) {
    final ql = q.trim().toLowerCase();
    // Two characters is too coarse to distinguish intent, and "ta" would
    // otherwise put a payment terminal in front of someone typing "tank".
    if (ql.length < 3) {
      return false;
    }
    const phrases = [
      'tap to pay',
      'tap to pay on iphone',
      'contactless',
      'card reader',
      'take a payment',
      'accept payments',
    ];
    return phrases.any((p) => p.contains(ql) || ql.contains(p));
  }

  /// The AR entry for [query], or null when it doesn't apply.
  ///
  /// Shown when the last-used auction is in-person and hasn't wound down
  /// ("pretty much over"), and either: the query explicitly asks for it
  /// ("ar", "lot scanning", "augmented reality" — regardless of distance), or
  /// the auction is within [_arRadiusMeters]. Distance defaults to "in range"
  /// whenever it can't be computed (no location permission, no fix yet, or
  /// the auction has no single physical location) — the in-person + not-over
  /// gate is the one that actually matters; a missing distance shouldn't hide
  /// an otherwise-relevant shortcut.
  PaletteItem? _arItem(String query) {
    final auction = _lastUsedAuction;
    if (auction == null || !auction.isActiveInPerson) {
      return null;
    }
    if (!_arQueryMatches(query) && !_arWithinRange(auction)) {
      return null;
    }
    return PaletteItem(
      type: 'ar',
      title: 'Scan lots — ${auction.title}',
      subtitle: 'Point your camera at a label to find and identify lots',
      url: auction.slug!,
      icon: 'bi-qr-code-scan',
    );
  }

  bool _arWithinRange(LastUsedAuction auction) {
    final position = _arPosition;
    final lat = auction.latitude;
    final lon = auction.longitude;
    if (position == null || lat == null || lon == null) {
      return true;
    }
    final meters = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      lat,
      lon,
    );
    return meters <= _arRadiusMeters;
  }

  bool _arQueryMatches(String q) {
    final ql = q.trim().toLowerCase();
    if (ql.isEmpty) {
      return false;
    }
    if (ql == 'ar') {
      return true;
    }
    const phrases = ['lot scanning', 'augmented reality'];
    return phrases.any((p) => p.contains(ql) || ql.contains(p));
  }

  @override
  void dispose() {
    // The dispose-time page-hide analog: finalizes the search however the
    // palette was dismissed (back gesture, programmatic pop, …), not just via
    // the close button. The once-guard in the logger keeps it to one write.
    _logger.finalize();
    _debounce?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _fetchResults(String q) async {
    // Record the query before results load, so it survives the user navigating
    // away mid-request (the whole point of a command palette is to leave).
    if (q.isNotEmpty) {
      _logger.recordPending(q);
    }
    setState(() {
      _loading = true;
      _searchFailed = false;
    });
    try {
      final groups = await CommandPaletteService.instance.search(q);
      final count = groups.fold(0, (sum, g) => sum + g.items.length);
      // Refine before the mounted check — the log must land even if the widget
      // is gone (e.g. the user already tapped a result).
      if (q.isNotEmpty) {
        _logger.recordResults(q, count);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _serverGroups = groups;
        _loading = false;
      });
    } on Exception catch (_) {
      // Search is server-side, so offline means no results at all — say that
      // instead of "No results", which reads as "your query matched nothing"
      // and sends the user off rewording a search that could never run.
      if (mounted) {
        setState(() {
          _loading = false;
          _searchFailed = true;
        });
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

    // The click is the search's terminal outcome; the logger marks the session
    // finalized so the dispose-time finalizer won't also record an abandon.
    // The write survives the navigation we're about to trigger.
    _logger.recordClick(type: item.type, url: item.url, objectId: item.id);

    Navigator.of(context).pop();
    if (item.type == 'ar') {
      // AR is a native camera screen, not a web path — [item.url] carries the
      // auction slug (there's no real URL to log/open) for [onOpenAr].
      widget.onOpenAr?.call(item.url);
      return;
    }
    if (item.type == 'tap_to_pay') {
      // Also a native screen, and with no slug to carry — the route is fixed.
      widget.onOpenTapToPay?.call();
      return;
    }
    widget.navigateToPath(item.url);
  }

  void _handleClose() {
    _logger.finalize();
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
              // Ink, so `secondary` — `primary` is a fill color. See AppTheme.
              color: theme.colorScheme.secondary,
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
              biIcon(item.icon),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
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
                            // Clearing abandons the current search and starts
                            // over — finalize it, then begin a fresh session.
                            _logger.reset();
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
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            _searchFailed
                                ? 'Couldn\'t search — check your connection '
                                      'and try again.'
                                : 'No results',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
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
