import '../models/command_palette_models.dart';
import 'api_service.dart';

class CommandPaletteService {
  CommandPaletteService._();
  static final CommandPaletteService instance = CommandPaletteService._();

  Future<List<PaletteGroup>> search(String q) async {
    final res = await ApiService.instance.dio.get(
      'command-palette/',
      queryParameters: q.isNotEmpty ? {'q': q} : null,
    );
    final rawGroups = res.data['groups'] as List<dynamic>? ?? [];
    return rawGroups
        .map((g) => PaletteGroup.fromJson(g as Map<String, dynamic>))
        .toList();
  }

  /// Upserts a search-session row. Returns the session id for subsequent calls.
  /// Errors are swallowed — logging is non-critical.
  Future<int?> log({
    int? id,
    String search = '',
    String result = 'pending',
    String resultType = '',
    String resultUrl = '',
    int? resultObjectId,
  }) async {
    try {
      final body = <String, dynamic>{
        'search': search,
        'result': result,
      };
      if (id != null) {
        body['id'] = id;
      }
      if (resultType.isNotEmpty) {
        body['result_type'] = resultType;
      }
      if (resultUrl.isNotEmpty) {
        body['result_url'] = resultUrl;
      }
      if (resultObjectId != null) {
        body['result_object_id'] = resultObjectId;
      }

      final res = await ApiService.instance.dio.post(
        'command-palette/log/',
        data: body,
      );
      return res.data['id'] as int?;
    } on Exception catch (_) {
      return id;
    }
  }
}
