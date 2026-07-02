import '../models/club_menu_item.dart';
import 'api_service.dart';

/// Fetches the signed-in user's clubs for the drawer menu. Backed by the
/// JWT-authenticated `GET /api/mobile/clubs/mine/`, which rebuilds the list the
/// web navbar's Clubs dropdown shows (hidden in-app).
class ClubsService {
  ClubsService._();
  static final ClubsService instance = ClubsService._();

  Future<List<ClubMenuItem>> myClubs() async {
    final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
      'clubs/mine/',
    );
    final raw = res.data?['clubs'] as List<dynamic>? ?? [];
    return raw
        .map((e) => ClubMenuItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
