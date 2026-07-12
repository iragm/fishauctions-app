import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'system_print_service.dart';

/// Handles files the WebView asks to download — CSV exports, invoice PDFs,
/// calendar `.ics`, Apple Wallet `.pkpass`. The system WebView can't download
/// on its own, and these Django endpoints are **session-authenticated**, so we
/// refetch the URL with the WebView's own cookies attached, stage the bytes in
/// a temp file, then hand it to the OS by MIME type:
///
///  • `text/calendar` (`.ics`)         → open with the OS so it imports into the
///    calendar. This is also the fallback for the native "add to calendar"
///    button when the JS bridge isn't available.
///  • `application/vnd.apple.pkpass`    → open with the OS (iOS routes to Wallet).
///  • everything else (CSV, PDF, …)     → the share sheet (save / open / send).
///
/// Cookie forwarding is the critical detail: a bare HTTP client (no session
/// cookie) is bounced to the login page instead of the file.
class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const _icsMime = 'text/calendar';
  static const _pkpassMime = 'application/vnd.apple.pkpass';

  // A dedicated Dio, deliberately WITHOUT ApiService's JWT interceptor: these
  // are Django *session* endpoints, authenticated by the cookie header we copy
  // off the WebView — not by the mobile API's Bearer token. Bytes, generous
  // receive timeout (large CSVs/PDFs), and we follow the redirect chain so a
  // login bounce is observable in the final response.
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 120),
      responseType: ResponseType.bytes,
      followRedirects: true,
      validateStatus: (s) => s != null && s >= 200 && s < 400,
    ),
  );

  /// Downloads [request] (the WebView's download intent) and dispatches the
  /// saved file to the OS. Returns a user-facing error string on failure, or
  /// null on success.
  ///
  /// [printPdfWithSystemDialog] — the "System printer" print method: PDFs go
  /// to the OS print dialog instead of the share sheet (other MIME types are
  /// unaffected).
  Future<String?> handle(
    DownloadStartRequest request, {
    String? userAgent,
    bool printPdfWithSystemDialog = false,
  }) async {
    final url = request.url;
    try {
      final cookieHeader = await _cookieHeaderFor(url);
      final response = await _dio.getUri<List<int>>(
        url,
        options: Options(
          headers: {
            if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
            if (userAgent != null && userAgent.isNotEmpty)
              'User-Agent': userAgent,
          },
        ),
      );

      final contentType = response.headers.value('content-type') ?? '';
      // No session → the endpoint 302s to the login page (an HTML 200), not the
      // file. Detect that rather than saving a login page as "export.csv".
      final bouncedToLogin =
          contentType.startsWith('text/html') ||
          response.realUri.path == '/login/';
      if (bouncedToLogin) {
        return 'You need to be signed in to download this.';
      }

      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        return 'The download was empty.';
      }

      final mime = _resolveMime(request.mimeType, contentType);
      final filename = _resolveFilename(request.suggestedFilename, url, mime);
      if (printPdfWithSystemDialog && mime.startsWith('application/pdf')) {
        await SystemPrintService.instance.printPdf(
          Uint8List.fromList(bytes),
          jobName: filename,
        );
        return null;
      }
      final path = await _writeTemp(filename, bytes);
      await _dispatch(path, mime);
      return null;
    } on DioException catch (e) {
      return 'Download failed: ${e.message ?? e.type.name}';
    } on Object catch (e) {
      return 'Download failed: $e';
    }
  }

  /// Serializes the WebView's cookies for [url] into a `Cookie:` header value.
  Future<String> _cookieHeaderFor(WebUri url) async {
    final cookies = await CookieManager.instance().getCookies(url: url);
    return cookies
        .where((c) => c.value.isNotEmpty)
        .map((c) => '${c.name}=${c.value}')
        .join('; ');
  }

  /// `.ics` and `.pkpass` open in the OS handler (calendar importer / Wallet);
  /// everything else goes to the share sheet so the user can save or send it.
  Future<void> _dispatch(String path, String mime) async {
    if (mime.startsWith(_icsMime) || mime.startsWith(_pkpassMime)) {
      await OpenFilex.open(path, type: mime);
    } else {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path, mimeType: mime)]),
      );
    }
  }

  /// Trust the server's Content-Type when the WebView's guess is missing or the
  /// generic octet-stream; strip any `; charset=…` parameter.
  String _resolveMime(String? requested, String contentType) {
    final fromServer = contentType.split(';').first.trim();
    final fromRequest = (requested ?? '').trim();
    final requestUnhelpful =
        fromRequest.isEmpty || fromRequest == 'application/octet-stream';
    if (requestUnhelpful && fromServer.isNotEmpty) {
      return fromServer;
    }
    return fromRequest.isNotEmpty ? fromRequest : 'application/octet-stream';
  }

  String _resolveFilename(String? suggested, WebUri url, String mime) {
    final fromSuggested = (suggested ?? '').trim();
    if (fromSuggested.isNotEmpty) {
      return _sanitize(fromSuggested);
    }
    final lastSegment = url.pathSegments.isNotEmpty
        ? url.pathSegments.last
        : '';
    if (lastSegment.isNotEmpty && lastSegment.contains('.')) {
      return _sanitize(lastSegment);
    }
    return 'download${_extForMime(mime)}';
  }

  String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[/\\?%*:|"<>]'), '_');

  String _extForMime(String mime) {
    switch (mime) {
      case _icsMime:
        return '.ics';
      case _pkpassMime:
        return '.pkpass';
      case 'text/csv':
        return '.csv';
      case 'application/pdf':
        return '.pdf';
      default:
        return '';
    }
  }

  Future<String> _writeTemp(String filename, List<int> bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
