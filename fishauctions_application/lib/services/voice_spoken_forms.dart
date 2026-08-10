/// Turning written identifiers into the ways people say them, and back.
///
/// This is the piece that makes voice set-winners work on real auctions rather
/// than on the subset with tidy numeric data. `AuctionTOS.bidder_number` is a
/// `CharField(max_length=20)` that is routinely text, and in seller-dash
/// auctions that text spills into lot numbers — the backend builds them as
/// `f"{bidder_number}-{n}"[:9]`, so `BOB-1` and `3-1` are as normal as `42`.
///
/// So instead of transcribing freely and repairing the text afterwards (which
/// is what the old Vosk implementation did, and why it failed), we expand the
/// values we *know exist in this auction* into their spoken forms and match
/// the utterance against those. See `VOICE.md` §4.2.
library;

import 'dart:math' as math;

/// Digits as they're read one at a time. `oh` is here because people say it
/// far more often than `zero` inside an identifier ("one oh five").
const Map<String, int> kDigitWords = {
  'zero': 0,
  'oh': 0,
  'o': 0,
  'nought': 0,
  'one': 1,
  'won': 1,
  'two': 2,
  'to': 2,
  'too': 2,
  'three': 3,
  'four': 4,
  'for': 4,
  'fore': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'ate': 8,
  'nine': 9,
};

/// Cardinal number words. Includes the homophones a recognizer is likely to
/// emit instead ("to" for "two"), because correcting them here is free and the
/// vocabulary match is what ultimately decides.
const Map<String, int> kCardinalWords = {
  ...kDigitWords,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fourty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
};

const Map<String, int> _multipliers = {'hundred': 100, 'thousand': 1000};

/// Letters as words, for spelled-out identifiers ("bidder bee oh bee").
const Map<String, String> kLetterWords = {
  'ay': 'a',
  'eh': 'a',
  'bee': 'b',
  'be': 'b',
  'see': 'c',
  'sea': 'c',
  'dee': 'd',
  'ee': 'e',
  'ef': 'f',
  'eff': 'f',
  'gee': 'g',
  'aitch': 'h',
  'haitch': 'h',
  'eye': 'i',
  'jay': 'j',
  'kay': 'k',
  'el': 'l',
  'ell': 'l',
  'em': 'm',
  'en': 'n',
  // Also digit 0 in kDigitWords. Both readings are generated as candidates
  // and the vocabulary decides which one this auction actually has.
  'oh': 'o',
  'owe': 'o',
  'pee': 'p',
  'pea': 'p',
  'cue': 'q',
  'queue': 'q',
  'ar': 'r',
  'are': 'r',
  'ess': 's',
  'es': 's',
  'tee': 't',
  'tea': 't',
  'you': 'u',
  'yu': 'u',
  'vee': 'v',
  'double you': 'w',
  'ex': 'x',
  'why': 'y',
  'wye': 'y',
  'zee': 'z',
  'zed': 'z',
};

/// NATO spelling alphabet, letter → word. Auction staff who read identifiers
/// over a PA tend to use it, and it's unambiguous to a recognizer.
const Map<String, String> kNatoAlphabet = {
  'a': 'alpha',
  'b': 'bravo',
  'c': 'charlie',
  'd': 'delta',
  'e': 'echo',
  'f': 'foxtrot',
  'g': 'golf',
  'h': 'hotel',
  'i': 'india',
  'j': 'juliet',
  'k': 'kilo',
  'l': 'lima',
  'm': 'mike',
  'n': 'november',
  'o': 'oscar',
  'p': 'papa',
  'q': 'quebec',
  'r': 'romeo',
  's': 'sierra',
  't': 'tango',
  'u': 'uniform',
  'v': 'victor',
  'w': 'whiskey',
  'x': 'xray',
  'y': 'yankee',
  'z': 'zulu',
};

const List<String> _ones = [
  'zero',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
  'nine',
  'ten',
  'eleven',
  'twelve',
  'thirteen',
  'fourteen',
  'fifteen',
  'sixteen',
  'seventeen',
  'eighteen',
  'nineteen',
];

const List<String> _tens = [
  '',
  '',
  'twenty',
  'thirty',
  'forty',
  'fifty',
  'sixty',
  'seventy',
  'eighty',
  'ninety',
];

/// Words that carry no meaning inside an identifier but that recognizers and
/// speakers both insert. Dropped before matching.
const Set<String> kFillerWords = {
  'the',
  'a',
  'an',
  'and',
  'number',
  'is',
  'uh',
};

/// Separator spoken between the parts of a compound identifier (`BOB-1`).
const Set<String> kSeparatorWords = {'dash', 'hyphen', 'slash', 'minus'};

/// Lowercase, strip anything that isn't a letter/digit/space, collapse runs of
/// whitespace. Every key in the spoken-form index and every phrase looked up
/// in it goes through this, so they can't disagree about punctuation.
///
/// One exception: a `.` **between two digits** survives. Recognizers hand back
/// prices already formatted ("25.50"), and stripping the point turns that into
/// the tokens `25 50`, which a cardinal parser reads as 75 — a wrong price
/// that looks entirely plausible.
String normalizePhrase(String input) {
  final cleaned = input
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9.]+'), ' ')
      // Drop any period that isn't a decimal point.
      .replaceAllMapped(RegExp(r'(?<![0-9])\.|\.(?![0-9])'), (_) => ' ')
      .trim();
  return cleaned.replaceAll(RegExp(r'\s+'), ' ');
}

/// [normalizePhrase] plus filler removal, as a token list.
List<String> tokenize(String input) {
  final tokens = normalizePhrase(input).split(' ');
  return [
    for (final token in tokens)
      if (token.isNotEmpty && !kFillerWords.contains(token)) token,
  ];
}

/// English cardinal words for [value], e.g. 105 → "one hundred five".
///
/// Deliberately omits "and" ("one hundred and five"): recognizers are
/// inconsistent about it and [tokenize] drops it anyway.
String cardinalToWords(int value) {
  if (value < 0) {
    return '';
  }
  if (value < 20) {
    return _ones[value];
  }
  if (value < 100) {
    final tens = _tens[value ~/ 10];
    final rest = value % 10;
    return rest == 0 ? tens : '$tens ${_ones[rest]}';
  }
  if (value < 1000) {
    final rest = value % 100;
    final head = '${_ones[value ~/ 100]} hundred';
    return rest == 0 ? head : '$head ${cardinalToWords(rest)}';
  }
  if (value < 1000000) {
    final rest = value % 1000;
    final head = '${cardinalToWords(value ~/ 1000)} thousand';
    return rest == 0 ? head : '$head ${cardinalToWords(rest)}';
  }
  return '';
}

/// Digit-by-digit reading of [digits], e.g. "105" → "one zero five".
///
/// [zeroAs] exists because "one oh five" is how people actually read an
/// identifier containing a zero; both readings get indexed.
String digitsToWords(String digits, {String zeroAs = 'zero'}) => [
  for (final rune in digits.split(''))
    rune == '0' ? zeroAs : _ones[int.tryParse(rune) ?? 0],
].join(' ');

/// Letter → the way it's said on its own, e.g. `b` → "bee". The inverse of
/// [kLetterWords], for generating the spelled-out form of a text identifier.
const Map<String, String> kLetterNames = {
  'a': 'ay',
  'b': 'bee',
  'c': 'see',
  'd': 'dee',
  'e': 'ee',
  'f': 'ef',
  'g': 'gee',
  'h': 'aitch',
  'i': 'eye',
  'j': 'jay',
  'k': 'kay',
  'l': 'el',
  'm': 'em',
  'n': 'en',
  'o': 'oh',
  'p': 'pee',
  'q': 'cue',
  'r': 'ar',
  's': 'ess',
  't': 'tee',
  'u': 'you',
  'v': 'vee',
  'w': 'double you',
  'x': 'ex',
  'y': 'why',
  'z': 'zee',
};

/// Parse a cardinal number spoken as words: "forty two" → 42, "one hundred
/// five" → 105.
///
/// This is the function the old implementation got wrong — it concatenated
/// digit strings, so "twenty five" became `205` and no recognizer, however
/// good, could have produced a correct price. Here `hundred` multiplies the
/// pending group and `thousand` flushes it.
int? parseCardinal(List<String> tokens) {
  if (tokens.isEmpty) {
    return null;
  }
  var total = 0;
  var group = 0;
  var sawAny = false;
  for (final token in tokens) {
    final literal = int.tryParse(token);
    if (literal != null) {
      // A recognizer that already emitted digits ("forty 2") — treat the
      // literal as a group on its own rather than trying to blend it.
      group += literal;
      sawAny = true;
      continue;
    }
    final multiplier = _multipliers[token];
    if (multiplier != null) {
      if (!sawAny) {
        return null;
      }
      if (multiplier == 100) {
        group *= 100;
      } else {
        total += (group == 0 ? 1 : group) * multiplier;
        group = 0;
      }
      continue;
    }
    final word = kCardinalWords[token];
    if (word == null) {
      return null;
    }
    group += word;
    sawAny = true;
  }
  return sawAny ? total + group : null;
}

/// Parse a digit-at-a-time reading: "four two" → "42", "one oh five" → "105".
///
/// Returns the digits as a *string* so leading zeros survive — bidder "007" is
/// a different bidder from "7".
String? parseDigitString(List<String> tokens) {
  if (tokens.isEmpty) {
    return null;
  }
  final buffer = StringBuffer();
  for (final token in tokens) {
    if (RegExp(r'^\d+$').hasMatch(token)) {
      buffer.write(token);
      continue;
    }
    final digit = kDigitWords[token];
    if (digit == null) {
      return null;
    }
    buffer.write(digit);
  }
  final result = buffer.toString();
  return result.isEmpty ? null : result;
}

/// Parse spelled-out letters: "bee oh bee" → "bob", "b o b" → "bob".
///
/// Rejects anything that isn't letter-shaped, so ordinary words can't be
/// mistaken for a spelling.
String? parseSpelledLetters(List<String> tokens) {
  if (tokens.length < 2) {
    return null;
  }
  final buffer = StringBuffer();
  for (final token in tokens) {
    if (token.length == 1 && RegExp(r'^[a-z]$').hasMatch(token)) {
      buffer.write(token);
      continue;
    }
    final nato = kNatoAlphabet.entries
        .where((e) => e.value == token)
        .map((e) => e.key)
        .firstOrNull;
    if (nato != null) {
      buffer.write(nato);
      continue;
    }
    final letter = kLetterWords[token];
    if (letter == null) {
      return null;
    }
    buffer.write(letter);
  }
  final result = buffer.toString();
  return result.isEmpty ? null : result;
}

/// One run of an identifier: `BOB-1` is [`bob`, `1`], with the separator
/// remembered so "bob dash one" can be indexed alongside "bob one".
class _Segment {
  const _Segment(this.text, {required this.isDigits});

  final String text;
  final bool isDigits;
}

List<_Segment> _segment(String value) {
  final matches = RegExp('[0-9]+|[a-z]+').allMatches(value.toLowerCase());
  return [
    for (final match in matches)
      _Segment(
        match.group(0)!,
        isDigits: RegExp(r'^\d+$').hasMatch(match.group(0)!),
      ),
  ];
}

/// Every reasonable way [segment] might be spoken.
List<String> _segmentForms(_Segment segment) {
  final forms = <String>{segment.text};
  if (segment.isDigits) {
    forms.add(digitsToWords(segment.text));
    if (segment.text.contains('0')) {
      forms.add(digitsToWords(segment.text, zeroAs: 'oh'));
    }
    // Cardinal only for values a person would actually say as one number.
    // "one two three four five" is how a five-digit id gets read, not
    // "twelve thousand three hundred forty five".
    if (segment.text.length <= 4) {
      final numeric = int.tryParse(segment.text);
      // A leading zero means it's an id, not a quantity: "007" is read out.
      if (numeric != null && !segment.text.startsWith('0')) {
        final words = cardinalToWords(numeric);
        if (words.isNotEmpty) {
          forms.add(words);
        }
        // Year-style pair reading: 1725 is far more often "seventeen twenty
        // five" than "one thousand seven hundred twenty five".
        if (segment.text.length == 4) {
          final head = cardinalToWords(numeric ~/ 100);
          final tail = numeric % 100;
          forms.add(
            tail < 10
                ? '$head oh ${cardinalToWords(tail)}'
                : '$head ${cardinalToWords(tail)}',
          );
        }
      }
    }
    return forms.toList();
  }
  // Short letter runs are as likely to be spelled as pronounced. All three
  // spellings are indexed because all three happen: bare letters as the
  // recognizer transcribes them ("b o b"), letter names as a person says them
  // ("bee oh bee"), and NATO for anyone used to reading ids over a PA.
  if (segment.text.length <= 6) {
    final letters = segment.text.split('');
    forms
      ..add(letters.join(' '))
      ..add(letters.map((c) => kLetterNames[c] ?? c).join(' '))
      ..add(letters.map((c) => kNatoAlphabet[c] ?? c).join(' '));
  }
  return forms.toList();
}

/// Cap on generated forms per value. A compound identifier's forms multiply
/// (3 × 3 × 2 separators = 18 for `BOB-1`), and past this point the extra
/// variants are noise that only widens the chance of a false match.
const int kMaxFormsPerValue = 24;

/// Every spoken form of one vocabulary value, normalized and de-duplicated.
///
/// `42`    → {"42", "four two", "forty two"}
/// `BOB`   → {"bob", "b o b", "bravo oscar bravo"}
/// `BOB-1` → the cross product of those with {"1", "one"}, with and without a
///           spoken "dash".
List<String> spokenFormsFor(String value) {
  final segments = _segment(value);
  if (segments.isEmpty) {
    return const [];
  }
  var combos = <String>[''];
  for (var i = 0; i < segments.length; i++) {
    final forms = _segmentForms(segments[i]);
    final next = <String>[];
    for (final combo in combos) {
      for (final form in forms) {
        if (i == 0) {
          next.add(form);
          continue;
        }
        next
          ..add('$combo $form')
          // Compound identifiers are read both ways, and which one an
          // operator uses is not predictable from the data.
          ..add('$combo dash $form');
      }
    }
    combos = next;
    if (combos.length > kMaxFormsPerValue * 4) {
      combos = combos.sublist(0, kMaxFormsPerValue * 4);
    }
  }
  final normalized = <String>{};
  for (final combo in combos) {
    final form = normalizePhrase(combo);
    if (form.isNotEmpty) {
      normalized.add(form);
    }
    if (normalized.length >= kMaxFormsPerValue) {
      break;
    }
  }
  return normalized.toList();
}

/// Consonants a recognizer transcribing American English confuses because the
/// *speaker* doesn't distinguish them, mapped to a shared class id.
///
/// These are the voiced/voiceless pairs, and the reason they matter here is
/// intervocalic flapping: "bidder" and "bitter" are both [ˈbɪɾɚ] in ordinary
/// American speech, and so are "ladder"/"latter" and "coated"/"coded". No
/// amount of acoustic model quality separates them, because there is nothing
/// in the audio to separate — which is why "bitter" came back for "bidder"
/// often enough to be reported as the thing voice set-winners gets wrong.
///
/// Vowels are deliberately absent. They carry most of the distinctions between
/// the identifiers this grammar has to keep apart, and blurring them would
/// make anchors fire on ordinary speech, which is the failure the closed
/// grammar exists to prevent.
const _voicingClass = <String, int>{
  't': 0,
  'd': 0,
  's': 1,
  'z': 1,
  'p': 2,
  'b': 2,
  'k': 3,
  'g': 3,
  'f': 4,
  'v': 4,
};

final _voicingClassByCode = <int, int>{
  for (final entry in _voicingClass.entries)
    entry.key.codeUnitAt(0): entry.value,
};

bool _sameVoicingClass(int a, int b) {
  final classA = _voicingClassByCode[a];
  return classA != null && classA == _voicingClassByCode[b];
}

/// Levenshtein distance, bounded: returns [limit] + 1 as soon as it's clear
/// the real distance exceeds [limit]. The fuzzy pass runs this against every
/// key in the index on every utterance, so the early exit matters.
///
/// [ignoreVoicing] makes a substitution within [_voicingClass] free, which
/// turns "bitter"/"bidder" into a distance of zero rather than two. Off by
/// default, and deliberately not used when matching *values*: a bidder number
/// is picked out of a closed set where these letters are doing real work, and
/// the whole point of a vocabulary is that "ten" and "den" are not the same
/// answer. Anchors are the opposite case — a fixed handful of words, where
/// missing one costs the operator a whole re-spoken command.
int boundedEditDistance(
  String a,
  String b,
  int limit, {
  bool ignoreVoicing = false,
}) {
  if ((a.length - b.length).abs() > limit) {
    return limit + 1;
  }
  if (a == b) {
    return 0;
  }
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    var best = current[0];
    for (var j = 1; j <= b.length; j++) {
      final left = a.codeUnitAt(i - 1);
      final right = b.codeUnitAt(j - 1);
      final cost =
          left == right || (ignoreVoicing && _sameVoicingClass(left, right))
          ? 0
          : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
      best = math.min(best, current[j]);
    }
    if (best > limit) {
      return limit + 1;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}
