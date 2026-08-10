import 'dart:async';

import 'package:fishauctions_application/services/speech_backend.dart';

/// A recognizer that records what it was asked, so a test can assert on what
/// *didn't* happen — which is most of what matters here: the microphone
/// permission must not be touched until the user taps something.
class FakeSpeechBackend implements SpeechBackend {
  bool capable = true;
  bool permitted = false;
  SpeechReadiness readiness = SpeechReadiness.ready;

  int prepareCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;

  /// What the last [start] was asked for.
  SpeechSessionOptions? lastOptions;

  final _events = StreamController<SpeechEvent>.broadcast();

  /// Push an event as though the platform recognizer had produced it.
  void emit(SpeechEvent event) => _events.add(event);

  @override
  String get id => 'fake';

  @override
  bool get isOnDevice => true;

  /// Settable, so a test can stand in for the `biased` backend that doesn't
  /// exist yet and check the settings panel is told the truth either way.
  @override
  bool supportsPhraseBias = false;

  @override
  bool get needsPermission => !permitted;

  @override
  Stream<SpeechEvent> get events => _events.stream;

  @override
  Future<bool> isCapable() async => capable;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<SpeechReadiness> prepare() async {
    prepareCalls++;
    if (readiness == SpeechReadiness.ready) {
      permitted = true;
    }
    return readiness;
  }

  @override
  Future<void> start(SpeechSessionOptions options) async {
    lastOptions = options;
    startCalls++;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async => _events.close();
}
