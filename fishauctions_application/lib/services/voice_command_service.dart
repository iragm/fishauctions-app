import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../models/voice_command.dart';
import '../models/voice_grammar.dart';
import 'bundled_voice_grammar.dart';
import 'platform_speech_backend.dart';
import 'speech_backend.dart';
import 'voice_parser.dart';
import 'voice_vocabulary_service.dart';

final _log = Logger();

/// What the page is told, in the shape it goes over the bridge as.
typedef VoiceEventSink = void Function(Map<String, dynamic> event);

/// Owns a voice set-winners session: one [SpeechBackend], one [VoiceParser],
/// and the small amount of state that has to live between utterances.
///
/// The page owns the form — validation, submit, undo and the queue
/// auto-advance are all unchanged and all server-side. This service owns only
/// what the web can't do: the microphone, and deciding what was said.
class VoiceCommandService {
  VoiceCommandService._();

  static final VoiceCommandService instance = VoiceCommandService._();

  /// A continuous recognizer re-delivers: the restart loop can hand back the
  /// tail of an utterance it already reported, and partial-to-final promotion
  /// produces the same words twice. Writing the same value into the same slot
  /// twice is harmless but makes the page flicker and re-validate, so drop
  /// repeats inside this window.
  static const Duration dedupeWindow = Duration(seconds: 2);

  SpeechBackend? _backend;
  StreamSubscription<SpeechEvent>? _subscription;
  VoiceEventSink? _sink;
  VoiceGrammar _grammar = bundledVoiceGrammar();

  /// The last value accepted per slot, and how sure we were. Drives the
  /// `blocked_by` list on a `sold`, which is the whole reason a "sold" heard
  /// mid-chant can't quietly record a wrong bidder.
  final Map<VoiceSlot, ({String value, double confidence})> _slots = {};
  final Map<VoiceSlot, ({String value, DateTime at})> _lastEmitted = {};

  bool get isListening => _listening;
  bool _listening = false;

  String get backendId => _backend?.id ?? 'platform';

  bool get isOnDevice => _backend?.isOnDevice ?? false;

  /// Whether this build/device/deployment can do voice at all. Drives the
  /// page's decision to reveal the microphone button, so a phone with no
  /// recognition service — or a deployment that turned voice off — shows no
  /// dead control.
  Future<bool> isSupported() async {
    if (!_grammar.enabled) {
      return false;
    }
    final backend = _ensureBackend();
    return backend.available();
  }

  /// True when the only thing missing is the OS permission, so the caller can
  /// say "allow the microphone" rather than "this device can't".
  bool get needsPermission => _backend?.needsPermission ?? false;

  /// Apply the deployment's served grammar. Merged over the bundled default
  /// field by field, so overriding one anchor list doesn't require restating
  /// the rest.
  void applyConfig(Object? voiceBlock) {
    if (voiceBlock is Map<String, dynamic>) {
      _grammar = VoiceGrammar.fromJson(voiceBlock, fallback: _grammar);
    }
  }

  VoiceGrammar get grammar => _grammar;

  /// The backend named by [VoiceGrammar.backend].
  ///
  /// Only `platform` exists today, and an unrecognised id resolves to it
  /// rather than disabling voice — a config written for a build that has
  /// `biased` or `cloud` should degrade on an older app, not break it. This is
  /// the seam the other backends slot into; nothing above it changes.
  SpeechBackend _ensureBackend() {
    if (_grammar.backend != 'platform') {
      _log.i('Unknown voice backend "${_grammar.backend}"; using platform');
    }
    return _backend ??= PlatformSpeechBackend();
  }

  /// Start listening for [auctionSlug], reporting everything to [sink].
  Future<bool> start({
    required String auctionSlug,
    required VoiceEventSink sink,
  }) async {
    if (_listening) {
      return true;
    }
    _sink = sink;
    _slots.clear();
    _lastEmitted.clear();
    final backend = _ensureBackend();
    if (!await backend.available()) {
      _emit({
        'type': 'error',
        'code': backend.needsPermission ? 'permission_denied' : 'unavailable',
        'message': backend.needsPermission
            ? 'Microphone access is off for this app.'
            : 'This device has no speech recognition available.',
      });
      return false;
    }
    final vocabulary = await VoiceVocabularyService.instance.begin(auctionSlug);
    await _subscription?.cancel();
    _subscription = backend.events.listen(_onSpeechEvent);
    _listening = true;
    await backend.start(
      SpeechSessionOptions(
        localeId: _grammar.localeId,
        preferOnDevice: _grammar.preferOnDevice,
        // Ignored by the platform backend, which can't express biasing;
        // carried so the `biased`/`cloud` backends need no signature change.
        biasPhrases: [...vocabulary.lotNumbers, ...vocabulary.bidderNumbers],
      ),
    );
    return true;
  }

  Future<void> stop() async {
    _listening = false;
    VoiceVocabularyService.instance.end();
    await _backend?.stop();
    await _subscription?.cancel();
    _subscription = null;
    _emit({'type': 'state', 'listening': false});
  }

  void _onSpeechEvent(SpeechEvent event) {
    switch (event.type) {
      case SpeechEventType.state:
        _listening = event.listening;
        _emit({
          'type': 'state',
          'listening': event.listening,
          'on_device': isOnDevice,
        });
      case SpeechEventType.level:
        _emit({'type': 'level', 'level': event.level});
      case SpeechEventType.partial:
        // Partials drive the transcript line only. Nothing is written from
        // them: a half-recognized number lands in the field and is then
        // corrected, which reads as the app typing nonsense.
        _emit({'type': 'transcript', 'text': event.bestText, 'partial': true});
      case SpeechEventType.result:
        _emit({'type': 'transcript', 'text': event.bestText, 'partial': false});
        _handleResult(event);
      case SpeechEventType.error:
        _listening = false;
        _emit({
          'type': 'error',
          'code': event.errorKind?.name ?? 'unknown',
          'message': event.message,
        });
    }
  }

  void _handleResult(SpeechEvent event) {
    final parser = VoiceParser(
      grammar: _grammar,
      vocabulary: VoiceVocabularyService.instance.current,
    );
    final commands = parser.parse(event.alternates);
    if (commands.isEmpty) {
      return;
    }
    for (final command in commands) {
      final resolved = _withBlockers(command);
      if (_isDuplicate(resolved)) {
        continue;
      }
      _remember(resolved);
      _emit(resolved.toJson());
    }
  }

  /// Fill in what's holding back an auto-submit.
  ///
  /// An auctioneer says "sold" constantly, so the word alone can't be enough.
  /// A save needs all three fields present and — when the deployment leaves
  /// [VoiceGrammar.blockAutoSubmitWhenUnsure] on — confident. Otherwise the
  /// page is told what's missing and says so instead of saving.
  VoiceCommand _withBlockers(VoiceCommand command) {
    if (command.slot != VoiceSlot.sold) {
      return command;
    }
    final blockers = <String>[];
    if (!_grammar.autoSubmitOnSold) {
      blockers.add('disabled');
    }
    for (final slot in [VoiceSlot.lot, VoiceSlot.bidder, VoiceSlot.price]) {
      final state = _slots[slot];
      if (state == null || state.value.isEmpty) {
        blockers.add(slot.wireName);
        continue;
      }
      if (_grammar.blockAutoSubmitWhenUnsure &&
          state.confidence < _grammar.confidentAt) {
        blockers.add(slot.wireName);
      }
    }
    return VoiceCommand(
      slot: command.slot,
      value: command.value,
      confidence: command.confidence,
      heard: command.heard,
      candidates: command.candidates,
      blockedBy: blockers,
    );
  }

  bool _isDuplicate(VoiceCommand command) {
    final last = _lastEmitted[command.slot];
    if (last == null || last.value != command.value) {
      return false;
    }
    return DateTime.now().difference(last.at) < dedupeWindow;
  }

  void _remember(VoiceCommand command) {
    _lastEmitted[command.slot] = (value: command.value, at: DateTime.now());
    if (command.slot.isValueSlot) {
      _slots[command.slot] = (
        value: command.value,
        confidence: command.confidence,
      );
      return;
    }
    // A save or a clear resets the round; the page has emptied the fields and
    // may have auto-advanced to the next queued lot.
    if (command.slot == VoiceSlot.sold && command.blockedBy.isEmpty) {
      _slots.clear();
    } else if (command.slot == VoiceSlot.clear ||
        command.slot == VoiceSlot.unsold) {
      _slots.clear();
    } else if (command.slot == VoiceSlot.confirm) {
      // "Confirm" promotes whatever is unsure — the operator has looked at the
      // field and said it's right, which outranks any score we computed.
      for (final slot in _slots.keys.toList()) {
        _slots[slot] = (value: _slots[slot]!.value, confidence: 1);
      }
    }
  }

  void _emit(Map<String, dynamic> event) {
    try {
      _sink?.call(event);
    } on Object catch (e) {
      _log.w('Voice event delivery failed: $e');
    }
  }

  /// Current state, for `voiceGetState`.
  Future<Map<String, dynamic>> state() async {
    final supported = await isSupported();
    return {
      'supported': supported,
      'listening': _listening,
      'permission': !needsPermission,
      'backend': backendId,
      'on_device': isOnDevice,
      'confident_at': _grammar.confidentAt,
      'unsure_at': _grammar.unsureAt,
    };
  }

  @visibleForTesting
  void resetForTesting() {
    _slots.clear();
    _lastEmitted.clear();
    _grammar = bundledVoiceGrammar();
    _listening = false;
  }
}
