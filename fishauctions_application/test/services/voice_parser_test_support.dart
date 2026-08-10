import 'package:fishauctions_application/models/voice_command.dart';
import 'package:fishauctions_application/models/voice_vocabulary.dart';
import 'package:fishauctions_application/services/bundled_voice_grammar.dart';
import 'package:fishauctions_application/services/voice_parser.dart';

export 'package:fishauctions_application/models/voice_vocabulary.dart'
    show VoiceVocabulary;
export 'package:fishauctions_application/services/voice_parser.dart'
    show SpeechHypothesis, VoiceParser;

/// Fixtures shared by every test that drives [VoiceParser]. Extracted when the
/// settings tests needed the same two auctions — a second copy would have gone
/// stale the first time either one grew a field.

/// A numeric auction, the common case.
VoiceVocabulary numericAuction({bool wholeDollars = true}) => VoiceVocabulary(
  lotNumbers: const ['1', '12', '42', '105'],
  bidderNumbers: const ['4', '17', '50', '105'],
  onlyWholeDollarBids: wholeDollars,
);

/// A seller-dash auction with text bidder numbers — `AuctionTOS.bidder_number`
/// is a CharField and this is what it looks like when someone uses it.
VoiceVocabulary textAuction() => VoiceVocabulary(
  lotNumbers: const ['BOB-1', 'BOB-2', 'ANN-1', '3-1'],
  bidderNumbers: const ['BOB', 'ANN', '3'],
  onlyWholeDollarBids: true,
);

VoiceParser parserFor(VoiceVocabulary vocabulary) =>
    VoiceParser(grammar: bundledVoiceGrammar(), vocabulary: vocabulary);

List<VoiceCommand> heard(VoiceParser parser, String text, {double asr = -1}) =>
    parser.parse([SpeechHypothesis(text, confidence: asr)]);

VoiceCommand? slot(List<VoiceCommand> commands, VoiceSlot wanted) {
  for (final command in commands) {
    if (command.slot == wanted) {
      return command;
    }
  }
  return null;
}
