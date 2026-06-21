import 'dart:typed_data';

/// A 1-bit label raster ready for a thermal printer.
///
/// [data] is row-major, [bytesPerRow] bytes per row, MSB = leftmost pixel,
/// bit value 1 = black (heater on) — the packing every printer in this class
/// (and the D11s `GS v 0` raster) expects. For the Fichero D11s the printhead
/// is 96 px, so [bytesPerRow] is 12.
class LabelBitmap {
  LabelBitmap({
    required this.bytesPerRow,
    required this.rows,
    required this.data,
  }) : assert(bytesPerRow > 0, 'bytesPerRow must be positive'),
       assert(
         data.length == bytesPerRow * rows,
         'data length must equal bytesPerRow * rows',
       );

  final int bytesPerRow;
  final int rows;
  final Uint8List data;

  int get widthPx => bytesPerRow * 8;
}
