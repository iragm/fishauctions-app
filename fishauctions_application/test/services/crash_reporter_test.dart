import 'dart:io';

import 'package:fishauctions_application/services/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late List<List<Map<String, Object?>>> sent;
  late bool serverUp;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crash_reporter_test');
    sent = [];
    serverUp = true;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  CrashReporter reporter({Map<String, Object?> native = const {}}) =>
      CrashReporter(
        directory: () async => dir,
        send: (batch) async {
          if (!serverUp) {
            return false;
          }
          sent.add(batch);
          return true;
        },
        native: () async => native,
        appVersion: () async => '1.0.0+12',
        platform: 'android',
      );

  test('a recorded error is sent with the version filled in', () async {
    final crashes = reporter()
      ..record(StateError('No element'), StackTrace.current);
    await crashes.flush();

    expect(sent, hasLength(1));
    final crash = sent.single.single;
    expect(crash['kind'], 'dart');
    expect(crash['fatal'], isFalse);
    expect(crash['platform'], 'android');
    expect(crash['message'], 'StateError: Bad state: No element');
    expect(crash['app_version'], '1.0.0+12');
    expect(crashes.queued, isEmpty);
  });

  test('the same error repeating is reported once', () async {
    final stack = StackTrace.current;
    final crashes = reporter();
    for (var frame = 0; frame < 60; frame++) {
      crashes.record(StateError('build failed'), stack);
    }
    await crashes.flush();

    expect(sent.single, hasLength(1));
  });

  test('an unsent report survives to the next launch', () async {
    serverUp = false;
    final first = reporter()..record(ArgumentError('x'), StackTrace.current);
    await first.flush();
    expect(sent, isEmpty);
    expect(File('${dir.path}/${CrashReporter.fileName}').existsSync(), isTrue);

    serverUp = true;
    await reporter().start();

    expect(sent.single.single['message'], contains('ArgumentError'));
    expect(File('${dir.path}/${CrashReporter.fileName}').existsSync(), isFalse);
  });

  test(
    'native crashes from the last launch are sent with the device',
    () async {
      await reporter(
        native: {
          'device': 'Google Pixel 8',
          'os_version': 'Android 16 (API 36)',
          'crashes': [
            {
              'kind': 'native',
              'platform': 'android',
              'fatal': true,
              'message': 'java.lang.IllegalStateException: boom',
              'stack': 'Thread GLThread 12\njava.lang.IllegalStateException',
              'app_version': '1.0.0+11',
            },
          ],
        },
      ).start();

      final crash = sent.single.single;
      expect(crash['kind'], 'native');
      expect(crash['device'], 'Google Pixel 8');
      expect(crash['os_version'], 'Android 16 (API 36)');
      // The build that crashed, not the one sending.
      expect(crash['app_version'], '1.0.0+11');
    },
  );

  test('the queue keeps only the newest reports', () async {
    serverUp = false;
    final crashes = reporter();
    for (var i = 0; i < CrashReporter.maxQueued + 5; i++) {
      crashes.record(StateError('error $i'), StackTrace.current);
    }
    await crashes.idle;

    expect(crashes.queued, hasLength(CrashReporter.maxQueued));
    expect(crashes.queued.last['message'], contains('error 24'));
  });
}
