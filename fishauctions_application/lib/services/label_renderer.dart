import 'dart:convert';
import 'dart:typed_data';

import '../models/label_data.dart';

/// Renders [LabelData] into printer commands.
///
/// The backend returns data only, and the target printer language is still
/// being finalised (TSPL / ZPL / ESC-POS). TSPL is implemented first: it is the
/// most common language for the 3"×2" thermal label printers in this class and
/// has first-class text + barcode commands, which is what the lot labels need.
/// When hardware is locked in, add a sibling `renderZpl` and pick by printer.
class LabelRenderer {
  const LabelRenderer._();

  /// TSPL commands for a 3"×2" landscape label at 203 dpi (≈609×406 dots).
  /// Includes a scannable Code 128 barcode of the lot number.
  static Uint8List renderTspl(LabelData data) {
    final lines = <String>['SIZE 3,2', 'GAP 0.12,0', 'DIRECTION 1', 'CLS'];

    final lot = _clean(data.lotNumber, 14);
    if (lot.isNotEmpty) {
      lines.add('TEXT 16,16,"4",0,2,2,"$lot"');
    }
    final title = _clean(data.title, 28);
    if (title.isNotEmpty) {
      lines.add('TEXT 16,86,"3",0,1,1,"$title"');
    }
    final seller = _clean(data.seller, 30);
    if (seller.isNotEmpty) {
      lines.add('TEXT 16,124,"2",0,1,1,"Seller: $seller"');
    }
    final auction = _clean(data.auction, 34);
    if (auction.isNotEmpty) {
      lines.add('TEXT 16,150,"2",0,1,1,"$auction"');
    }
    final price = _clean(_priceLine(data), 34);
    if (price.isNotEmpty) {
      lines.add('TEXT 16,184,"3",0,1,1,"$price"');
    }
    final extra = _clean(_extraLine(data), 42);
    if (extra.isNotEmpty) {
      lines.add('TEXT 16,222,"2",0,1,1,"$extra"');
    }
    final custom = _clean(data.customField1, 42);
    if (custom.isNotEmpty) {
      lines.add('TEXT 16,250,"2",0,1,1,"$custom"');
    }
    // Scannable lot barcode near the bottom. Skip if there's nothing to encode.
    final code = _clean(data.lotNumber, 24);
    if (code.isNotEmpty) {
      lines.add('BARCODE 16,286,"128",90,1,0,2,4,"$code"');
    }

    lines.add('PRINT 1,1');

    // TSPL expects CRLF-terminated commands. latin1 covers the printer's
    // default code page; _clean already stripped anything outside it.
    return latin1.encode('${lines.join('\r\n')}\r\n');
  }

  static String _priceLine(LabelData d) {
    final parts = <String>[];
    if (_hasValue(d.minimumBid)) {
      parts.add('Min \$${d.minimumBid}');
    }
    if (_hasValue(d.buyNowPrice)) {
      parts.add('BNP \$${d.buyNowPrice}');
    }
    return parts.join('  ');
  }

  static String _extraLine(LabelData d) {
    final parts = <String>[];
    if (_hasValue(d.category)) {
      parts.add(d.category);
    }
    if (_hasValue(d.quantity)) {
      parts.add('Qty: ${d.quantity}');
    }
    if (d.iBredThisFish) {
      parts.add('BRED');
    }
    return parts.join('  ');
  }

  static const _emptyTokens = {'', '0', '0.00', 'none', 'null'};

  static bool _hasValue(String s) =>
      !_emptyTokens.contains(s.trim().toLowerCase());

  /// Makes [text] safe to embed in a quoted TSPL string and fit the label:
  /// drops line breaks, neutralises quotes/backslashes that would break the
  /// command, maps anything outside latin1 to '?', then truncates.
  static String _clean(String text, int maxLen) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune == 0x0A || rune == 0x0D) {
        buffer.write(' '); // newline → space
      } else if (rune == 0x22) {
        buffer.write("'"); // " → ' (would terminate the TSPL string)
      } else if (rune == 0x5C) {
        buffer.write('/'); // \ → /
      } else if (rune >= 0x20 && rune <= 0xFF) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write('?');
      }
    }
    final cleaned = buffer.toString().trim();
    return cleaned.length <= maxLen ? cleaned : cleaned.substring(0, maxLen);
  }
}
