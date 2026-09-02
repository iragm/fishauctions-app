import '../config/environment.dart';

/// Normalizes a server-supplied link to a **site-relative path**, or null when
/// it points somewhere other than this deployment.
///
/// Everything the backend hands the app as a link — the legal paths in
/// `/api/mobile/config/`, every row of the drawer's `menu` block — is loaded
/// in one of the app's own WebViews, sometimes inside the signed-out login
/// trap. So the rule is the same everywhere: a bare path is taken as-is, an
/// absolute URL is accepted only on our own host and reduced to its path, and
/// anything else (another host, a protocol-relative `//host/…`, a non-URL) is
/// refused rather than followed. Query and fragment are preserved — the
/// admin menu's links carry `?days=30` and mean it.
String? sitePathOrNull(String value) {
  if (value.isEmpty || value.startsWith('//')) {
    return null;
  }
  if (value.startsWith('/')) {
    return value;
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) {
    return null;
  }
  if (uri.host != Uri.parse(EnvironmentConfig.webBaseUrl).host) {
    return null;
  }
  final path = uri.path.isEmpty ? '/' : uri.path;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  final fragment = uri.fragment.isEmpty ? '' : '#${uri.fragment}';
  return '$path$query$fragment';
}
