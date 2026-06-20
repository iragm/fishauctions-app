import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config/environment.dart';
import '../constants/app_constants.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
import 'command_palette_screen.dart';

class WebViewScreen extends ConsumerStatefulWidget {
  const WebViewScreen({super.key});

  @override
  ConsumerState<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends ConsumerState<WebViewScreen>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _loading = true;
  bool _webLoggedIn = false;
  // The soft location banner is offered at most once per app session, the first
  // time the user reaches a location-aware screen. See _maybeOfferLocation.
  bool _locationOffered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onNavigationRequest: _handleNavigation,
        ),
      )
      ..setUserAgent(
        'FishAuctionsApp/1.0 (Flutter; ${defaultTargetPlatform.name})',
      );
    _initWebView();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh the location cookies silently when the app returns to the
    // foreground — the user may have moved. The server reads them per request,
    // so the next navigation/XHR picks up the newest position; no reload (that
    // would be jarring mid-browse). Never prompts here.
    if (state == AppLifecycleState.resumed) {
      _applyLocation(prompt: false);
    }
  }

  Future<void> _initWebView() async {
    // Try to inject a Django session cookie so the WebView is
    // pre-authenticated. Falls back gracefully if not yet deployed.
    final cookie = await AuthService.instance.getWebSessionCookie();
    if (cookie != null) {
      final uri = Uri.parse(EnvironmentConfig.webBaseUrl);
      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: 'sessionid',
          value: _extractSessionId(cookie) ?? '',
          domain: uri.host,
        ),
      );
    }
    // If location is already granted, seed the cookies from the instant cached
    // fix so distances render on the first page without delaying it. We never
    // prompt at app open — that happens contextually on a location-aware screen
    // (see _maybeOfferLocation).
    await _applyLocation(prompt: false, fresh: false);
    await _controller.loadRequest(Uri.parse(EnvironmentConfig.webBaseUrl));
  }

  /// Reads the device position and, if available, writes the
  /// `latitude`/`longitude` cookies the web UI reads. Returns true when cookies
  /// were written. A denied/unavailable location is a no-op, so listings just
  /// render without distances.
  ///
  /// [prompt] shows the OS permission dialog when undecided; otherwise it reads
  /// silently (null unless already granted). [fresh] is forwarded to the silent
  /// read — false for an instant cached fix (pre-navigation), true for a
  /// current fix (foreground). Prompting always uses a current fix.
  Future<bool> _applyLocation({required bool prompt, bool fresh = true}) async {
    final position = prompt
        ? await LocationService.instance.requestAndGetPosition()
        : await LocationService.instance.positionIfPermitted(fresh: fresh);
    if (position == null) {
      return false;
    }
    await _setLocationCookies(position);
    return true;
  }

  Future<void> _setLocationCookies(Position position) async {
    final host = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    final manager = WebViewCookieManager();
    // Non-HttpOnly, non-sensitive cookies the web UI also sets from JS; path '/'
    // and the site host match what document.cookie writes, so the server reads
    // them the same way whether they came from the browser or from here.
    await manager.setCookie(
      WebViewCookie(
        name: 'latitude',
        value: LocationService.formatCoordinate(position.latitude),
        domain: host,
      ),
    );
    await manager.setCookie(
      WebViewCookie(
        name: 'longitude',
        value: LocationService.formatCoordinate(position.longitude),
        domain: host,
      ),
    );
  }

  /// The first time the user lands on a location-aware screen without location
  /// set, offer a soft, dismissible banner. Runs at most once per app session.
  /// If location is already granted we just refresh the cookies silently; if it
  /// was permanently denied we stay quiet (the banner couldn't re-prompt).
  Future<void> _maybeOfferLocation(String path) async {
    if (_locationOffered || !LocationService.isLocationAwarePath(path)) {
      return;
    }
    if (await LocationService.instance.hasPermission()) {
      _locationOffered = true;
      // Already granted: refine the pre-load cached fix to a current one for
      // subsequent navigations. No reload — the page already rendered.
      await _applyLocation(prompt: false);
      return;
    }
    if (!await LocationService.instance.canPrompt()) {
      _locationOffered = true; // permanently denied — nothing we can offer
      return;
    }
    _locationOffered = true;
    _showLocationBanner();
  }

  void _showLocationBanner() {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.location_on_outlined),
        content: const Text(
          'See auctions near you? Enable location to show the distance to each '
          'one.',
        ),
        actions: [
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: _enableLocationFromBanner,
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  Future<void> _enableLocationFromBanner() async {
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    }
    // Prompt, and on a grant reload so the page in front of the user gains
    // distances immediately. A decline is a no-op — same as a web visitor who
    // declines the browser prompt.
    if (await _applyLocation(prompt: true)) {
      await _controller.reload();
    }
  }

  String? _extractSessionId(String cookieHeader) {
    for (final part in cookieHeader.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length >= 2 && kv[0].trim() == 'sessionid') {
        return kv[1].trim();
      }
    }
    return null;
  }

  void _onPageStarted(String url) {
    // A new page load supersedes any location banner the user hasn't acted on,
    // so it doesn't float over an unrelated screen.
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    }
    setState(() => _loading = true);
  }

  void _onPageFinished(String url) {
    final uri = Uri.parse(url);
    final onAuthPage =
        uri.path.startsWith('/accounts/login') ||
        uri.path.startsWith('/accounts/signup');
    setState(() {
      _loading = false;
      _webLoggedIn = !onAuthPage;
    });
    // On the auctions/lots screens, offer location in context (once per
    // session). The home page and everything else never triggers this.
    _maybeOfferLocation(uri.path);
  }

  void _loadPath(String path) {
    _controller.loadRequest(Uri.parse('${EnvironmentConfig.webBaseUrl}$path'));
  }

  void _navigate(BuildContext drawerContext, String path) {
    Navigator.of(drawerContext).pop();
    _loadPath(path);
  }

  void _onTitleTap() {
    // The command palette is backed by the JWT API, so it needs a native
    // sign-in. Prompt for one if missing; otherwise open search.
    final user = ref.read(authProvider).valueOrNull;
    if (user == null) {
      context.push('/login');
      return;
    }
    showCommandPalette(context, _loadPath);
  }

  NavigationDecision _handleNavigation(NavigationRequest request) {
    final uri = Uri.parse(request.url);

    if (uri.scheme == EnvironmentConfig.urlScheme) {
      _handleDeepLink(uri);
      return NavigationDecision.prevent;
    }

    // Only allow standard web navigation. Block javascript:, intent:, file:,
    // and other schemes that injected or remote content could abuse. http(s)
    // stays open so allauth social-login redirects (Google, Discord) work.
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return NavigationDecision.prevent;
    }

    // When the user logs out via the website, also clear the native JWT
    // session and drop the WebView's own cookies so no stale session lingers.
    // Scope this to our own host so an external page (e.g. a social-login
    // redirect) that happens to use the same path can't log the user out.
    final webHost = Uri.parse(EnvironmentConfig.webBaseUrl).host;
    if (uri.path == '/accounts/logout/' && uri.host == webHost) {
      ref.read(authProvider.notifier).logout();
      WebViewCookieManager().clearCookies();
    }

    return NavigationDecision.navigate;
  }

  void _handleDeepLink(Uri uri) {
    switch (uri.host) {
      case 'pay':
        final invoicePk = int.tryParse(uri.pathSegments.firstOrNull ?? '');
        if (invoicePk != null) {
          context.push('/pay/$invoicePk');
        }
      case 'print':
        // fishauctions://print/<lot_pk> — print a label. Without a valid pk
        // (e.g. a bare "set up printer" link) fall back to printer settings.
        final lotPk = int.tryParse(uri.pathSegments.firstOrNull ?? '');
        if (lotPk != null) {
          context.push('/print/$lotPk');
        } else {
          context.push('/settings/printer');
        }
    }
  }

  Widget _buildDrawer(BuildContext ctx) => Drawer(
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: Text(
              AppConstants.appName,
              style: Theme.of(
                ctx,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _navTile(ctx, Icons.gavel, 'Auctions', '/auctions/'),
                _navTile(ctx, Icons.grid_view, 'Lots', '/lots/all/'),
                _navTile(ctx, Icons.sell, 'Selling', '/selling/'),
                _navTile(
                  ctx,
                  Icons.favorite_border,
                  'Watched lots',
                  '/lots/watched/',
                ),
                _navTile(ctx, Icons.groups, 'Clubs', '/clubs/'),
                ExpansionTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('About'),
                  children: [
                    _navTile(ctx, null, 'FAQ', '/faq/', indent: true),
                    _navTile(
                      ctx,
                      null,
                      'Terms & Conditions',
                      '/tos/',
                      indent: true,
                    ),
                  ],
                ),
                const Divider(),
                if (_webLoggedIn)
                  _navTile(ctx, Icons.logout, 'Sign out', '/accounts/logout/')
                else ...[
                  _navTile(ctx, Icons.login, 'Sign in', '/accounts/login/'),
                  _navTile(
                    ctx,
                    Icons.person_add,
                    'Create account',
                    '/accounts/signup/',
                  ),
                ],
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Browsing and app features (payments, printing) sign in '
                    'separately.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                if (ref.watch(authProvider).valueOrNull == null)
                  ListTile(
                    leading: const Icon(Icons.lock_open),
                    title: const Text('Sign in for app features'),
                    subtitle: const Text('Payments, printing & search'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      context.push('/login');
                    },
                  )
                // Web logout already clears the native session too, so only
                // surface a separate app sign-out when the two have drifted:
                // signed in for app features but logged out on the website.
                else if (!_webLoggedIn)
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('Sign out of app features'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      ref.read(authProvider.notifier).logout();
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.print),
                  title: const Text('Printer setup'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    context.push('/settings/printer');
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  ListTile _navTile(
    BuildContext ctx,
    IconData? icon,
    String label,
    String path, {
    bool indent = false,
  }) => ListTile(
    contentPadding: indent
        ? const EdgeInsets.only(left: 56, right: 16)
        : const EdgeInsets.symmetric(horizontal: 16),
    leading: icon != null ? Icon(icon) : null,
    title: Text(label),
    onTap: () => _navigate(ctx, path),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: GestureDetector(
        onTap: _onTitleTap,
        child: const Text(AppConstants.appName),
      ),
      actions: [
        Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: 'Menu',
            onPressed: Scaffold.of(ctx).openEndDrawer,
          ),
        ),
      ],
    ),
    endDrawer: Builder(builder: _buildDrawer),
    body: Stack(
      children: [
        WebViewWidget(controller: _controller),
        if (_loading) const LinearProgressIndicator(minHeight: 3),
      ],
    ),
  );
}
