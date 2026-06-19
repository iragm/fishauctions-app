/// A lot's printable label, parsed from `GET /api/mobile/labels/<lot_pk>/`.
///
/// The backend returns *data only* (no printer commands); rendering to a
/// printer language happens in `LabelRenderer`. Field types from the backend
/// are not guaranteed (a price may arrive as a number or a string, a lot
/// number as int or string), so every text field is coerced to a display
/// string here to keep the renderer crash-proof.
class LabelData {
  const LabelData({
    required this.lotPk,
    required this.lotNumber,
    required this.title,
    required this.quantity,
    required this.minimumBid,
    required this.buyNowPrice,
    required this.seller,
    required this.auction,
    required this.category,
    required this.iBredThisFish,
    required this.customField1,
  });

  factory LabelData.fromResponse(Map<String, dynamic> json) {
    final data = json['label_data'];
    final metadata = json['metadata'];
    if (data is! Map) {
      throw const FormatException('missing label_data');
    }
    final meta = metadata is Map ? metadata : const {};
    return LabelData(
      lotPk: _int(meta['lot_pk']),
      lotNumber: _str(data['lot_number']),
      title: _str(data['title']),
      quantity: _str(data['quantity']),
      minimumBid: _str(data['minimum_bid']),
      buyNowPrice: _str(data['buy_now_price']),
      seller: _str(data['seller']),
      auction: _str(data['auction']),
      category: _str(data['category']),
      iBredThisFish: _bool(data['i_bred_this_fish']),
      customField1: _str(data['custom_field_1']),
    );
  }

  final int? lotPk;
  final String lotNumber;
  final String title;
  final String quantity;
  final String minimumBid;
  final String buyNowPrice;
  final String seller;
  final String auction;
  final String category;
  final bool iBredThisFish;
  final String customField1;

  static String _str(Object? v) => v == null ? '' : v.toString();

  static bool _bool(Object? v) {
    if (v is bool) {
      return v;
    }
    if (v is num) {
      return v != 0;
    }
    final s = v?.toString().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static int? _int(Object? v) {
    if (v is int) {
      return v;
    }
    return int.tryParse(v?.toString() ?? '');
  }
}
