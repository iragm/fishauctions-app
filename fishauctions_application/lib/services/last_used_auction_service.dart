import 'package:dio/dio.dart';

import '../models/last_used_auction.dart';
import 'api_service.dart';

/// Fetches the user's last-used auction for the command palette's AR entry
/// (BACKEND_SPEC.md "AR Command Palette Entry — Last-Used-Auction Lookup").
///
/// Degrades like the other optional mobile endpoints: a 404 (this backend
/// build predates the endpoint) disables further attempts for the process,
/// and any failure just means the AR entry doesn't get injected — never a
/// crash or a stalled palette.
class LastUsedAuctionService {
  LastUsedAuctionService._();
  static final LastUsedAuctionService instance = LastUsedAuctionService._();

  bool _available = true;

  Future<LastUsedAuction?> fetch() async {
    if (!_available) {
      return null;
    }
    try {
      final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
        'auctions/last-used/',
      );
      final data = res.data;
      return data == null ? null : LastUsedAuction.fromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        _available = false;
      }
      return null;
    }
  }
}
