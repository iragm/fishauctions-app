import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../models/voice_command.dart';
import '../models/voice_grammar.dart';
import '../models/voice_settings.dart';
import 'bundled_voice_grammar.dart';
import 'microphone.dart';
import 'speech_backend.dart';
import 'voice_bias_phrases.dart';
import 'voice_parser.dart';
import 'voice_settings_service.dart';
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

  /// What `/api/mobile/config/` served, untouched. The operator's overrides
  /// are applied on read in [grammar] rather than folded in here, so a
  /// deployment retuning its grammar still reaches a device whose owner has
  /// moved one unrelated slider.
  VoiceGrammar _served = bundledVoiceGrammar();

  /// The last value accepted per slot, and how sure we were. Drives the
  /// `blocked_by` list on a `sold`, which is the whole reason a "sold" heard
  /// mid-chant can't quietly record a wrong bidder.
  final Map<VoiceSlot, ({String value, double confidence})> _slots = {};
  final Map<VoiceSlot, ({String value, DateTime at})> _lastEmitted = {};

  /// The newest partial transcript, and the clock that decides it has
  /// settled. See [_onPartial].
  List<SpeechHypothesis> _partial = const [];
  Timer? _partialTimer;

  /// What the utterance in progress has already written from a settled
  /// partial, per slot — so its final result doesn't write the same thing
  /// again — and whether it has already asked the recognizer to finish.
  final Map<VoiceSlot, String> _committed = {};
  bool _finishRequested = false;

  bool get isListening => _listening;
  bool _listening = false;

  String get backendId => _backend?.id ?? 'platform';

  bool get isOnDevice => _backend?.isOnDevice ?? false;

  /// Whether this build/device/deployment can do voice at all. Drives the
  /// page's decision to reveal the microphone button, so a phone with no
  /// recognition service — or a deployment that turned voice off — shows no
  /// dead control.
  ///
  /// **Permission is not part of this answer, and asking for it here is a
  /// bug.** The page calls `voiceGetState` on load, so anything this touches
  /// happens before the user has shown any interest in voice at all. It used
  /// to run `SpeechToText.initialize()`, which on Android both raises the
  /// microphone dialog *and* reports the permission as the device's
  /// capability — so the dialog appeared on page load and the answer was
  /// `supported: false` on every phone that had not already granted it.
  Future<bool> isSupported() async {
    if (!grammar.enabled) {
      return false;
    }
    return _ensureBackend().isCapable();
  }

  /// True when the only thing missing is the OS permission, so the caller can
  /// say "allow the microphone" rather than "this device can't". Only
  /// meaningful once a session has been attempted — nothing before [start]
  /// looks at permissions.
  bool get needsPermission => _backend?.needsPermission ?? false;

  /// Apply the deployment's served grammar. Merged over the bundled default
  /// field by field, so overriding one anchor list doesn't require restating
  /// the rest.
  void applyConfig(Object? voiceBlock) {
    if (voiceBlock is Map<String, dynamic>) {
      _served = VoiceGrammar.fromJson(voiceBlock, fallback: _served);
    }
  }

  /// The grammar actually in force: what the deployment served, with this
  /// operator's device-local overrides on top.
  ///
  /// Computed on read rather than stored, so a setting changed mid-auction
  /// takes effect on the *next utterance* rather than the next session. That
  /// is the whole point of the settings panel — the operator is tuning while
  /// the auction runs, and "stop voice, change it, start voice" would make
  /// them stop selling to do it.
  VoiceGrammar get grammar =>
      VoiceSettingsService.instance.current.applyTo(_served);

  /// The backend named by [VoiceGrammar.backend].
  ///
  /// Only `platform` exists today, and an unrecognised id resolves to it
  /// rather than disabling voice — a config written for a build that has
  /// `biased` or `cloud` should degrade on an older app, not break it. This is
  /// the seam the other backends slot into; nothing above it changes.
  ///
  /// Comes from [Microphone] rather than being constructed here: palette
  /// dictation listens through the same recognizer, and two of them contend
  /// for one platform service rather than giving you two.
  SpeechBackend _ensureBackend() => _backend ??= Microphone.instance.backend;

  /// The backend the served grammar asks for, brought up if it isn't already.
  ///
  /// Async and separate from [_ensureBackend] because `biased` has to ask the
  /// platform whether it exists on this build before it can be chosen, and
  /// nothing on the `voiceGetState` path may wait on a channel — that call
  /// runs when the page loads and decides whether the microphone button
  /// appears at all. So capability questions live here, on the Listen tap.
  Future<SpeechBackend> _selectBackend() async {
    final wanted = grammar.backend;
    final backend = await Microphone.instance.backendFor(wanted);
    if (backend.id != wanted) {
      _log.i('Voice backend "$wanted" unavailable; using ${backend.id}');
    }
    return _backend = backend;
  }

  /// Start listening for [auctionSlug], reporting everything to [sink].
  ///
  /// **This is the microphone permission's one and only prompt point.** It runs
  /// from the page's Listen button, which is the first moment the user has said
  /// they want voice at all.
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
    _forgetUtterance();
    // Before `grammar` is read for anything: the getter is synchronous, so an
    // unloaded store would silently run the session on the deployment's
    // defaults and make the panel look like it had done nothing.
    await VoiceSettingsService.instance.load();
    final backend = await _selectBackend();
    final readiness = await backend.prepare();
    if (readiness != SpeechReadiness.ready) {
      _emit({
        'type': 'error',
        'code': readiness.errorCode,
        'message': readiness.message,
      });
      return false;
    }
    // Evicts palette dictation if it was listening. Deliberate: a tap on
    // Listen is the operator saying this is what the microphone is for now.
    await Microphone.instance.claim('voice', stop);
    final vocabulary = await VoiceVocabularyService.instance.begin(auctionSlug);
    await _subscription?.cancel();
    _subscription = backend.events.listen(_onSpeechEvent);
    _listening = true;
    final inForce = grammar;
    await backend.start(
      SpeechSessionOptions(
        localeId: inForce.localeId,
        preferOnDevice: inForce.preferOnDevice,
        // Ignored by the `platform` backend, which has no way to express
        // biasing — `speech_to_text` exposes neither iOS `contextualStrings`
        // nor Android's `EXTRA_BIASING_STRINGS`. Built and carried anyway so
        // the `biased` backend is a backend swap rather than a rewrite, and
        // so the selection logic can be tested long before native code exists.
        biasPhrases: VoiceBiasPhrases.build(
          vocabulary: vocabulary,
          grammar: inForce,
        ),
      ),
    );
    return true;
  }

  Future<void> stop() async {
    _listening = false;
    // Switching the microphone off is cancelling: a partial still settling
    // was never finished, and writing it now would be the app typing on its
    // own after the operator stopped it.
    _forgetUtterance();
    VoiceVocabularyService.instance.end();
    Microphone.instance.release('voice');
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
        // A partial still changing writes nothing: a half-recognized number
        // lands in the field and is then corrected, which reads as the app
        // typing nonsense. One that has stopped changing is another matter —
        // see [_onPartial].
        _emit({'type': 'transcript', 'text': event.bestText, 'partial': true});
        _onPartial(event);
      case SpeechEventType.result:
        _handleResult(event);
      case SpeechEventType.error:
        _forgetUtterance();
        _listening = false;
        _emit({
          'type': 'error',
          'code': event.errorKind?.name ?? 'unknown',
          'message': event.message,
        });
    }
  }

  /// Write the values in a partial that has stopped changing, instead of
  /// waiting for the final result.
  ///
  /// **The final is what made voice feel broken.** A recognizer only
  /// produces one when the silence window runs out, and that window is kept
  /// long (three seconds) because every utterance that ends costs a
  /// restart's worth of deafness — the next anchor keyword, spoken into it,
  /// is lost. So "lot one" sat on the transcript line for five or six seconds
  /// before the field filled. A partial that hasn't changed for
  /// [VoiceGrammar.commitAfter] is a speaker who has stopped talking, and the
  /// same parser reads it the same way.
  ///
  /// Only values are written from a partial. A value written early and then
  /// corrected by the final is a field that changes once; a "sold" acted on
  /// early is a sale. So an action in a settled partial only asks the
  /// recognizer for its final now — the save still waits on the real
  /// transcript, it just stops waiting for three seconds of silence first.
  void _onPartial(SpeechEvent event) {
    final wait = grammar.commitAfter;
    if (wait == null) {
      return;
    }
    _partial = event.alternates;
    _partialTimer?.cancel();
    _partialTimer = Timer(wait, _commitPartial);
  }

  void _commitPartial() {
    _partialTimer = null;
    if (!_listening || _partial.isEmpty) {
      return;
    }
    final commands = _parse(_partial);
    var heardAction = false;
    final written = <VoiceCommand>[];
    for (final command in commands) {
      if (!command.slot.isValueSlot) {
        heardAction = true;
        continue;
      }
      if (_committed[command.slot] == command.value) {
        continue;
      }
      _committed[command.slot] = command.value;
      if (_isDuplicate(command)) {
        continue;
      }
      _remember(command);
      _emit(command.toJson());
      written.add(command);
    }
    if (written.isNotEmpty) {
      _log.i(
        'Voice settled on "${_partial.first.text}" → ${written.join(', ')}',
      );
    }
    if (heardAction && !_finishRequested) {
      _finishRequested = true;
      _backend?.finishUtterance();
    }
  }

  /// Drop the utterance in progress: its settling clock, what it has written
  /// early, and its request to finish.
  void _forgetUtterance() {
    _partialTimer?.cancel();
    _partialTimer = null;
    _partial = const [];
    _committed.clear();
    _finishRequested = false;
  }

  List<VoiceCommand> _parse(List<SpeechHypothesis> alternates) => VoiceParser(
    grammar: grammar,
    vocabulary: VoiceVocabularyService.instance.current,
  ).parse(alternates);

  void _handleResult(SpeechEvent event) {
    // The final supersedes anything still settling. Whatever this utterance
    // wrote early is read before it's forgotten, so the final doesn't write
    // it a second time.
    final committed = Map<VoiceSlot, String>.of(_committed);
    _forgetUtterance();
    final commands = _parse(event.alternates);
    // Logged on both branches, and deliberately at the same level. From the
    // outside "the app misheard me" and "the app never got a final result at
    // all" look identical — the page shows a transcript either way — and the
    // only place the difference is visible is here. An empty parse with the
    // alternates beside it is the difference between a grammar problem, a
    // vocabulary that failed to load, and a recognizer that isn't reporting.
    final vocabulary = VoiceVocabularyService.instance.current;
    final heard = [
      for (final alternate in event.alternates) '"${alternate.text}"',
    ].join(', ');
    _log.i(
      commands.isEmpty
          ? 'Voice heard $heard → nothing matched '
                '(${vocabulary.lotNumbers.length} lots, '
                '${vocabulary.bidderNumbers.length} bidders in the vocabulary)'
          : 'Voice heard $heard → ${commands.join(', ')}',
    );
    final fresh = [
      for (final command in commands)
        if (committed[command.slot] != command.value && !_isDuplicate(command))
          command,
    ];
    // The page matches a final transcript itself when no command follows it
    // (its fallback for a build that can't match). One whose every command
    // already reached the page — written from the settled partial, or sent
    // moments ago — must not be matched again: that fallback would fill the
    // same fields twice, and a "sold" in it would be a second save. Reported
    // as a partial, which the page shows and never acts on.
    _emit({
      'type': 'transcript',
      'text': event.bestText,
      'partial': commands.isNotEmpty && fresh.isEmpty,
    });
    for (final command in fresh) {
      final resolved = _withBlockers(command);
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
    if (!grammar.autoSubmitOnSold) {
      blockers.add('disabled');
    }
    for (final slot in [VoiceSlot.lot, VoiceSlot.bidder, VoiceSlot.price]) {
      final state = _slots[slot];
      if (state == null || state.value.isEmpty) {
        blockers.add(slot.wireName);
        continue;
      }
      if (grammar.blockAutoSubmitWhenUnsure &&
          state.confidence < grammar.confidentAt) {
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
  ///
  /// `supported` and `permission` are independent on purpose: a phone that can
  /// do voice but hasn't been asked for the microphone yet is the *normal*
  /// state on first visit, and it must still reveal the button — tapping it is
  /// what earns the prompt.
  Future<Map<String, dynamic>> state() async {
    final supported = await isSupported();
    return {
      'supported': supported,
      'listening': _listening,
      'permission': supported && await _ensureBackend().hasPermission(),
      'backend': backendId,
      'on_device': isOnDevice,
      'confident_at': grammar.confidentAt,
      'unsure_at': grammar.unsureAt,
      ...await settingsState(),
    };
  }

  /// What the settings panel renders itself from — the values *in force*, the
  /// slider's endpoints, and which controls are worth showing at all.
  ///
  /// The effective values rather than the stored overrides, because the panel
  /// has to show the operator where they actually are: a fresh device has no
  /// overrides and its controls still need positions, and they come from the
  /// deployment's grammar.
  ///
  /// `bias_supported` is the same idea as `supported` on the microphone
  /// button. The low-price tie-break works today with no native code — it
  /// picks between readings the recognizer already offered — but the phrase
  /// biasing that would *also* improve it needs a `SpeechBackend` that can
  /// express it, and a page shouldn't have to know which builds have one.
  Future<Map<String, dynamic>> settingsState() async {
    // The one place the stored settings are guaranteed to have been read: the
    // panel asks for this before it can draw itself, and `state()` folds it in
    // so `voiceGetState` on page load warms the cache too.
    await VoiceSettingsService.instance.load();
    final inForce = grammar;
    return {
      'settings': {
        'confident_at': inForce.confidentAt,
        'prefer_on_device': inForce.preferOnDevice,
        'bias_low_prices': inForce.biasLowPrices,
      },
      'settings_range': {
        'confident_min': VoiceSettings.minConfidentAt,
        'confident_max': VoiceSettings.maxConfidentAt,
      },
      'bias_supported': _backend?.supportsPhraseBias ?? false,
    };
  }

  /// Store settings from the panel and report what is now in force.
  ///
  /// Takes effect on the next utterance — [grammar] is computed on read — so
  /// the operator can tune while selling rather than stopping to do it.
  Future<Map<String, dynamic>> updateSettings(Object? raw) async {
    if (raw is Map) {
      await VoiceSettingsService.instance.save(
        VoiceSettings.fromJson(Map<String, dynamic>.from(raw)),
      );
    }
    return settingsState();
  }

  @visibleForTesting
  void resetForTesting() {
    _slots.clear();
    _lastEmitted.clear();
    _forgetUtterance();
    _served = bundledVoiceGrammar();
    _listening = false;
    _backend = null;
    _sink = null;
  }

  /// Drive the session with a stand-in recognizer. The seam exists for one
  /// invariant in particular: `voiceGetState` must answer without asking the
  /// OS for anything (see [isSupported]), and nothing but a fake backend can
  /// prove a prompt didn't happen.
  @visibleForTesting
  SpeechBackend? get backendForTesting => _backend;

  @visibleForTesting
  set backendForTesting(SpeechBackend? backend) => _backend = backend;
}
