import '../models/voice_command.dart';
import '../models/voice_grammar.dart';

/// The grammar the app falls back to when `GET /api/mobile/config/` carries no
/// `voice` block — a first run with no connectivity, or a deployment that
/// hasn't configured one.
///
/// Keep this in sync with the seed values in `BACKEND_SPEC.md` Part VOICE-3.
/// The served block is merged *over* this one field by field, so a deployment
/// can override a single anchor list without restating everything.
///
/// The first word of each list is canonical (quality 1.0); the rest are
/// synonyms (0.8). Synonyms are here because auctioneers don't share a script:
/// "buyer" and "bidder" are the same slot, and finding out which one a given
/// hall uses is what the served override exists for.
VoiceGrammar bundledVoiceGrammar() => const VoiceGrammar(
  anchors: {
    VoiceSlot.lot: ['lot', 'lot number', 'item'],
    VoiceSlot.bidder: ['bidder', 'buyer', 'bidder number', 'paddle'],
    VoiceSlot.price: ['dollars', 'dollar', 'bucks'],
    VoiceSlot.sold: ['sold', 'hammer'],
    VoiceSlot.unsold: ['no sale', 'unsold', 'pass'],
    VoiceSlot.undo: ['undo', 'scratch that'],
    VoiceSlot.clear: ['clear', 'cancel that', 'start over'],
    VoiceSlot.confirm: ['confirm', 'correct', 'yes'],
  },
);
