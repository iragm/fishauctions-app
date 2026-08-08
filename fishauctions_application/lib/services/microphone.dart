import 'package:flutter/foundation.dart';

import 'platform_speech_backend.dart';
import 'speech_backend.dart';

/// Who currently holds the microphone, and the one recognizer they share.
///
/// **A phone has one microphone and one recognition service, so exactly one
/// feature may listen at a time.** Two `SpeechToText` objects don't give you
/// two recognizers — they contend for the same platform one, and the loser
/// fails with `ERROR_RECOGNIZER_BUSY` on Android or simply never delivers a
/// result on iOS. That looks, from the outside, exactly like a dead
/// microphone.
///
/// This matters because the two features that listen overlap on the same
/// screen: the set-winners page has a Listen button, and the command palette
/// (with its own dictation) opens over whatever page the user is on —
/// including that one. So a claim doesn't queue or fail; it *takes* the
/// microphone, stopping whoever had it. Losing dictation to a deliberate tap
/// on Listen is right, and so is the reverse: the last thing the user touched
/// is the thing they meant.
class Microphone {
  Microphone._();

  static final Microphone instance = Microphone._();

  SpeechBackend? _backend;

  /// The shared recognizer. Created lazily — constructing it is cheap, but a
  /// user who never uses voice should never bring the plugin up at all.
  SpeechBackend get backend => _backend ??= PlatformSpeechBackend();

  String? _holder;
  Future<void> Function()? _release;

  /// Which feature is listening (`voice`, `dictation`), or null.
  String? get holder => _holder;

  /// Take the microphone for [owner], stopping the current holder first.
  ///
  /// [release] is how this owner is later asked to stop. It must be safe to
  /// call when the owner isn't listening — a holder that stopped on its own
  /// is the normal case.
  Future<void> claim(String owner, Future<void> Function() release) async {
    if (_holder != null && _holder != owner) {
      final previous = _release;
      _holder = null;
      _release = null;
      await previous?.call();
    }
    _holder = owner;
    _release = release;
  }

  /// Give it back. A no-op unless [owner] is the current holder, so a late
  /// stop can't evict whoever claimed it since.
  void release(String owner) {
    if (_holder == owner) {
      _holder = null;
      _release = null;
    }
  }

  @visibleForTesting
  SpeechBackend? get backendForTesting => _backend;

  @visibleForTesting
  set backendForTesting(SpeechBackend? backend) => _backend = backend;

  @visibleForTesting
  void resetForTesting() {
    _backend = null;
    _holder = null;
    _release = null;
  }
}
