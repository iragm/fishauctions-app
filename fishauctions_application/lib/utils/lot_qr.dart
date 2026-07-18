/// Parses the lot pk out of a scanned lot-label QR code.
///
/// Labels encode `Lot.qr_code` = `https://<domain>/qr/<pk>/` (the backend's
/// `lot_by_pk_qr` route). The domain is whatever deployment printed the label —
/// often production even when the app points at staging — so any http(s) host
/// is accepted; only the path shape identifies a lot QR. Returns null for
/// anything that isn't one (other QR codes in the room are expected noise).
int? parseLotQr(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  // pathSegments for "/qr/123/" is ["qr", "123", ""] — drop the trailing
  // empty segment a canonical Django URL carries.
  final segments = [
    for (final s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  if (segments.length != 2 || segments.first != 'qr') {
    return null;
  }
  final pk = int.tryParse(segments[1]);
  return (pk != null && pk > 0) ? pk : null;
}
