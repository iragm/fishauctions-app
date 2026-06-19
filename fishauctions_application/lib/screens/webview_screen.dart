import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config/environment.dart';
import '../constants/app_constants.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import 'command_palette_screen.dart';

class WebViewScreen extends ConsumerStatefulWidget {
  const WebViewScreen({super.key});

  @override
  ConsumerState<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends ConsumerState<WebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _webLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: _onPageFinished,
          onNavigationRequest: _handleNavigation,
        ),
      )
      ..setUserAgent(
        'FishAuctionsApp/1.0 (Flutter; ${defaultTargetPlatform.name})',
      );
    _initWebView();
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
    await _controller.loadRequest(Uri.parse(EnvironmentConfig.webBaseUrl));
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

  void _onPageFinished(String url) {
    final uri = Uri.parse(url);
    final onAuthPage =
        uri.path.startsWith('/accounts/login') ||
        uri.path.startsWith('/accounts/signup');
    setState(() {
      _loading = false;
      _webLoggedIn = !onAuthPage;
    });
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
