import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_config.dart';
import '../services/config_service.dart';

/// Deployment config from `GET /api/mobile/config/`, loaded once and cached by
/// [ConfigService]. Read `ref.read(configProvider.future)` to await it (e.g.
/// warming the Square SDK) or watch it in the UI.
final configProvider = FutureProvider<AppConfig>(
  (ref) => ConfigService.instance.load(),
);
