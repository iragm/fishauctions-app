import 'package:fishauctions_application/utils/bi_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Bootstrap Icons → Material mapping shared by the command palette's
/// result rows and the navigation drawer's server-driven menu.
///
/// Both surfaces carry the website's own icon names through verbatim, so the
/// map has to survive names this build has never heard of — a new navbar link
/// with a new icon must not be able to break a drawer.
void main() {
  test('maps the names the website actually uses', () {
    expect(biIcon('bi-hammer'), Icons.gavel);
    expect(biIcon('bi-star-fill'), Icons.star);
    expect(biIcon('bi-box-arrow-right'), Icons.logout);
  });

  test('an unknown name falls back rather than throwing', () {
    // Including the shapes a malformed payload produces.
    expect(biIcon('bi-something-invented-next-tuesday'), biIconFallback);
    expect(biIcon(''), biIconFallback);
    expect(biIcon('star'), biIconFallback);
  });

  test('every mapped icon is a const IconData from the Icons family', () {
    // Release builds tree-shake the icon font down to the glyphs they can
    // prove are referenced, and they can only prove it for constant IconData.
    // Anything built from a runtime codepoint renders tofu — or fails the
    // build outright. This checks the observable half of that rule: the
    // fallback and everything reachable through it come from MaterialIcons.
    for (final name in <String>[
      'bi-grid',
      'bi-people',
      'bi-cash-coin',
      'bi-shield-lock',
      'bi-question-circle',
    ]) {
      expect(biIcon(name).fontFamily, 'MaterialIcons', reason: name);
    }
    expect(biIconFallback.fontFamily, 'MaterialIcons');
  });
}
