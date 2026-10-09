import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/device_identity.dart';
import '../utils/platform_bridge.dart';
import 'api_service.dart';

/// Sends a batch to `POST /api/mobile/crashes/`. True once the server is done
/// with it: taken, or refused as malformed (sending it again can't help).
typedef CrashSender = Future<bool> Function(List<Map<String, Object?>> batch);

/// The native side's crashes since the last call (`PlatformBridge`).
typedef NativeCrashSource = Future<Map<String, Object?>> Function();

/// The app's own crash reports, sent to the backend for the hourly check.
///
/// Neither store lets anything but a person read its crash reports (Apple has
/// no API for them at all), so the app reports its own:
///
/// - **Dart errors** through `FlutterError.onError` and
///   `PlatformDispatcher.onError`, as they happen. Neither kills a Flutter
///   app, so they are reported as not fatal. The previous handlers still run.
/// - **Native crashes and hangs** (`CrashCapture.kt` / `CrashCapture.swift`),
///   which end the process before Dart can see them, collected from the OS on
///   the next launch.
///
/// Everything waits in one JSON file until the server has it, so a report made
/// offline at an auction hall goes out on a later launch. Off in debug builds:
/// a developer's red screen is not a bug report.
class CrashReporter {
  CrashReporter({
    required this._directory,
    required this._send,
    this._native,
    Future<String> Function()? appVersion,
    String? platform,
  }) : _appVersionOf = appVersion ?? _installedVersion,
       _platform = platform ?? DeviceIdentity.platformTag;

  static final CrashReporter instance = CrashReporter(
    directory: getApplicationSupportDirectory,
    send: _post,
    native: PlatformBridge.takePendingCrashes,
  );

  static const String fileName = 'crash_reports.json';

  /// Past this many waiting, the oldest go: a crash loop says the same thing
  /// every time, and the file must stay small enough to read at launch.
  static const int maxQueued = 20;
  static const int messageChars = 2000;
  static const int stackChars = 20000;

  /// How long after an error to send it, so a burst goes in one request.
  static const Duration sendDelay = Duration(seconds: 5);

  final Future<Directory> Function() _directory;
  final CrashSender _send;
  final NativeCrashSource? _native;
  final Future<String> Function() _appVersionOf;
  final String _platform;

  List<Map<String, Object?>> _queue = [];
  bool _loaded = false;
  final Set<String> _seen = {};
  String _appVersion = '';
  String _device = '';
  String _osVersion = Platform.operatingSystemVersion;
  Future<void> _work = Future.value();
  Timer? _sendTimer;

  /// What is waiting to be sent.
  @visibleForTesting
  List<Map<String, Object?>> get queued => List.unmodifiable(_queue);

  /// Completes when everything asked of this reporter so far has finished.
  @visibleForTesting
  Future<void> get idle => _work;

  /// Hooks the error handlers and sends what earlier launches left behind.
  void install() {
    if (kDebugMode) {
      return;
    }
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      previousFlutter?.call(details);
      record(details.exception, details.stack);
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack);
      return previousPlatform?.call(error, stack) ?? false;
    };
    unawaited(start());
  }

  /// Reads the queue, adds the native side's crashes, and sends.
  Future<void> start() => _serial(() async {
    await _load();
    _appVersion = await _appVersionOf();
    final native = await _native?.call() ?? const {};
    _device = native['device'] as String? ?? _device;
    _osVersion = native['os_version'] as String? ?? _osVersion;
    for (final crash in native['crashes'] as List<Object?>? ?? const []) {
      if (crash is Map) {
        _enqueue({..._context(), ...crash.cast<String, Object?>()});
      }
    }
    await _save();
    await _sendQueued();
  });

  /// Queues one Dart error. Never throws: this runs inside the error handlers.
  void record(Object error, StackTrace? stack, {bool fatal = false}) {
    try {
      final message = _clip('${error.runtimeType}: $error', messageChars);
      final trace = _clip((stack ?? StackTrace.empty).toString(), stackChars);
      // A broken build method throws on every frame; one report says it.
      if (!_seen.add('$message\n$trace')) {
        return;
      }
      final crash = {
        ..._context(),
        'kind': 'dart',
        'fatal': fatal,
        'message': message,
        'stack': trace,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
      };
      unawaited(
        _serial(() async {
          await _load();
          _enqueue(crash);
          await _save();
        }),
      );
      _sendTimer?.cancel();
      _sendTimer = Timer(sendDelay, () => unawaited(flush()));
    } on Object catch (e) {
      debugPrint('CrashReporter: could not record an error: $e');
    }
  }

  /// Sends whatever is waiting now.
  Future<void> flush() => _serial(_sendQueued);

  Map<String, Object?> _context() => {
    'platform': _platform,
    'app_version': _appVersion,
    'os_version': _osVersion,
    'device': _device,
  };

  void _enqueue(Map<String, Object?> crash) {
    _queue.add(crash);
    if (_queue.length > maxQueued) {
      _queue = _queue.sublist(_queue.length - maxQueued);
    }
  }

  Future<void> _sendQueued() async {
    if (_queue.isEmpty) {
      return;
    }
    if (_appVersion.isEmpty) {
      _appVersion = await _appVersionOf();
    }
    final count = _queue.length;
    // An error recorded before launch finished reading the version and the
    // device went without them; fill in what is known now.
    final context = _context();
    final batch = [
      for (final crash in _queue)
        {
          ...crash,
          for (final MapEntry(:key, :value) in context.entries)
            if ((crash[key] ?? '') == '') key: value,
        },
    ];
    if (!await _send(batch)) {
      return;
    }
    // Only what was sent: an error recorded mid-send waits for the next one.
    _queue.removeRange(0, count);
    await _save();
  }

  Future<void> _load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final file = await _file();
      if (file.existsSync()) {
        final stored = jsonDecode(await file.readAsString());
        if (stored is List) {
          _queue = [
            for (final crash in stored)
              if (crash is Map) crash.cast<String, Object?>(),
            ..._queue,
          ];
        }
      }
    } on Object catch (e) {
      // An unreadable file is dropped, never a reason not to report.
      debugPrint('CrashReporter: could not read the queue: $e');
    }
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      if (_queue.isEmpty) {
        if (file.existsSync()) {
          await file.delete();
        }
        return;
      }
      await file.writeAsString(jsonEncode(_queue), flush: true);
    } on Object catch (e) {
      debugPrint('CrashReporter: could not save the queue: $e');
    }
  }

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  /// One thing at a time, and a failure never stops the next.
  Future<void> _serial(Future<void> Function() task) =>
      _work = _work.then((_) => task()).catchError((Object e) {
        debugPrint('CrashReporter: $e');
      });

  static String _clip(String text, int length) =>
      text.length <= length ? text : text.substring(0, length);

  static Future<String> _installedVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } on Object {
      return '';
    }
  }

  static Future<bool> _post(List<Map<String, Object?>> batch) async {
    try {
      await ApiService.instance.dio.post<Object?>(
        'crashes/',
        data: {'crashes': batch},
      );
      return true;
    } on DioException catch (e) {
      // 400 is a report the server will never take; anything else is retried
      // on a later launch (offline, throttled, server down).
      return e.response?.statusCode == 400;
    }
  }
}
