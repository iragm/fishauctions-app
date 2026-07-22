import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/club_menu_item.dart';
import '../services/clubs_service.dart';
import 'auth_provider.dart';

/// The signed-in user's clubs for the drawer's Clubs menu. Empty when signed
/// out, and re-fetched whenever auth changes (it watches [authProvider], so a
/// sign-in/out refreshes it). A fetch error surfaces as an [AsyncError] the
/// drawer treats as "no clubs" — it falls back to the plain browse link.
final myClubsProvider = FutureProvider<List<ClubMenuItem>>((ref) async {
  final user = ref.watch(authProvider).value;
  if (user == null) {
    return const <ClubMenuItem>[];
  }
  return ClubsService.instance.myClubs();
});
