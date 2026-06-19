import '../models/label_data.dart';
import 'api_service.dart';

/// Fetches a lot's label data from the mobile API. Requires a valid JWT
/// (attached by the Dio auth interceptor); a 401 surfaces as a DioException for
/// the caller to handle.
class LabelService {
  LabelService._();
  static final LabelService instance = LabelService._();

  Future<LabelData> fetchLabel(int lotPk) async {
    final res = await ApiService.instance.dio.get<Map<String, dynamic>>(
      'labels/$lotPk/',
    );
    return LabelData.fromResponse(res.data ?? const {});
  }
}
