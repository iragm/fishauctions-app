import 'package:flutter/foundation.dart';

import 'biased_speech_backend.dart';
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

  /// The shared recognizer, of the kind [id] names.
  ///
  /// **Still one object, not one per caller**, for the reason in this class's
  /// doc: a phone has one recognition service and two of anything contend for
  /// it. So asking for a different kind *replaces* the shared instance rather
  /// than adding a second — and only ever between sessions, since the holder
  /// is stopped first.
  ///
  /// In practice this is asked once, when voice set-winners starts and the
  /// served grammar says which backend to use. Palette dictation never asks
  /// and so inherits whatever is current, which is right: dictation has no
  /// vocabulary to bias towards, so either recognizer serves it equally, and
  /// swapping the shared object underneath it would be the expensive kind of
  /// clever.
  ///
  /// An unknown id, or a backend that turns out not to be available on this
  /// build, falls back to `platform` rather than disabling voice — a config
  /// written for a newer app must degrade on an older one, not break it.
  Future<SpeechBackend> backendFor(String id) async {
    if (_pinned || _backend?.id == id) {
      return backend;
    }
    if (id != 'biased') {
      return _swapTo(PlatformSpeechBackend());
    }
    final biased = BiasedSpeechBackend();
    if (await biased.isCapable()) {
      return _swapTo(biased);
    }
    // No native recognizer in this build (or none on this device). Nothing is
    // said to the user: `platform` is a working recognizer, it just can't be
    // told what to expect, and `supportsPhraseBias` already reports that.
    await biased.dispose();
    return _backend?.id == 'platform'
        ? _backend!
        : _swapTo(PlatformSpeechBackend());
  }

  /// Replace the shared recognizer, stopping whoever is using it first.
  ///
  /// The order matters and is not obvious: whoever holds the microphone holds
  /// it *through* the outgoing backend, so disposing it under them closes the
  /// event stream they're listening to and leaves a lit button attached to a
  /// dead recognizer. Voice set-winners selects its backend before it claims
  /// the microphone — it has to, since a refused permission mustn't evict
  /// palette dictation — so this is the moment the previous holder has to be
  /// let go.
  Future<SpeechBackend> _swapTo(SpeechBackend next) async {
    final previous = _backend;
    final release = _release;
    _holder = null;
    _release = null;
    await release?.call();
    _backend = next;
    if (previous != null) {
      await previous.dispose();
    }
    return next;
  }

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

  /// Set when a test installs a stand-in, which [backendFor] must then never
  /// swap out from under it. Production code never sets this, so the selection
  /// logic above is exercised exactly as written everywhere else.
  bool _pinned = false;

  @visibleForTesting
  SpeechBackend? get backendForTesting => _backend;

  @visibleForTesting
  set backendForTesting(SpeechBackend? backend) {
    _backend = backend;
    _pinned = backend != null;
  }

  @visibleForTesting
  void resetForTesting() {
    _backend = null;
    _pinned = false;
    _holder = null;
    _release = null;
  }
}
