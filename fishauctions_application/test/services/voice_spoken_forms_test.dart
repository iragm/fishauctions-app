import 'package:fishauctions_application/services/voice_spoken_forms.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCardinal', () {
    test('reads multi-word numbers as one value', () {
      // The bug that made v1 unusable regardless of the recognizer: the old
      // parseSpokenNumber concatenated digit strings, so "twenty five" became
      // "205" and every two-word price was wrong.
      expect(parseCardinal(['twenty', 'five']), 25);
      expect(parseCardinal(['one', 'hundred', 'five']), 105);
      expect(parseCardinal(['one', 'hundred', 'twenty', 'five']), 125);
      expect(parseCardinal(['two', 'thousand']), 2000);
      expect(parseCardinal(['fifteen']), 15);
      expect(parseCardinal(['fifty']), 50);
    });

    test('accepts digits the recognizer already resolved', () {
      expect(parseCardinal(['42']), 42);
      expect(parseCardinal(['forty', '2']), 42);
    });

    test('rejects anything that is not a number', () {
      expect(parseCardinal(['bob']), isNull);
      expect(parseCardinal([]), isNull);
      expect(parseCardinal(['hundred']), isNull);
    });
  });

  group('parseDigitString', () {
    test('keeps leading zeros, because 007 is not 7', () {
      expect(parseDigitString(['oh', 'oh', 'seven']), '007');
      expect(parseDigitString(['one', 'oh', 'five']), '105');
      expect(parseDigitString(['four', 'two']), '42');
    });

    test('rejects non-digit words', () {
      expect(parseDigitString(['twenty', 'five']), isNull);
    });
  });

  group('parseSpelledLetters', () {
    test('reads letter names and NATO', () {
      expect(parseSpelledLetters(['bee', 'oh', 'bee']), 'bob');
      expect(parseSpelledLetters(['b', 'o', 'b']), 'bob');
      expect(parseSpelledLetters(['bravo', 'oscar', 'bravo']), 'bob');
    });

    test('refuses a single token, which is just a word', () {
      expect(parseSpelledLetters(['bee']), isNull);
    });
  });

  group('spokenFormsFor', () {
    test('covers cardinal, digit and literal readings of a number', () {
      final forms = spokenFormsFor('42');
      expect(forms, contains('42'));
      expect(forms, contains('forty two'));
      expect(forms, contains('four two'));
    });

    test('reads a four-digit id year-style as well', () {
      // 1725 is far more often "seventeen twenty five" than "one thousand
      // seven hundred twenty five".
      expect(spokenFormsFor('1725'), contains('seventeen twenty five'));
    });

    test('covers text bidder numbers, spoken and spelled', () {
      final forms = spokenFormsFor('BOB');
      expect(forms, contains('bob'));
      expect(forms, contains('b o b'));
      expect(forms, contains('bravo oscar bravo'));
    });

    test('covers seller-dash lot numbers, with and without the dash', () {
      // Lot.save() builds these as f"{bidder_number}-{n}"[:9], so a text
      // bidder number spills straight into the lot numbers.
      final forms = spokenFormsFor('BOB-1');
      expect(forms, contains('bob one'));
      expect(forms, contains('bob dash one'));
    });

    test('handles a numeric seller-dash lot number', () {
      final forms = spokenFormsFor('3-1');
      expect(forms, contains('three one'));
      expect(forms, contains('three dash one'));
    });

    test('stays bounded for compound values', () {
      expect(spokenFormsFor('BOB-12').length, lessThanOrEqualTo(24));
    });
  });

  group('normalizePhrase', () {
    test('keeps a decimal point between digits', () {
      // Stripping it turns "25.50" into the tokens "25 50", which a cardinal
      // parser reads as 75 — a wrong price that looks entirely plausible.
      expect(normalizePhrase('25.50'), '25.50');
      expect(normalizePhrase(r'$25.50!'), '25.50');
    });

    test('drops sentence punctuation', () {
      expect(normalizePhrase('Lot forty-two.'), 'lot forty two');
    });
  });

  group('boundedEditDistance', () {
    test('measures small edits and bails out on large ones', () {
      expect(boundedEditDistance('bidder', 'bidders', 1), 1);
      expect(boundedEditDistance('bidder', 'bidder', 1), 0);
      expect(boundedEditDistance('dollars', 'dollar', 1), 1);
      // "butter" is three edits from "bidder", not one — the bound short-
      // circuits rather than reporting the true distance.
      expect(boundedEditDistance('bidder', 'butter', 1), greaterThan(1));
      expect(boundedEditDistance('bidder', 'elephant', 1), greaterThan(1));
    });
  });
}
