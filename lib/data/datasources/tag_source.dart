import '../../core/network/api_result.dart';
import '../models/tag_models.dart';

/// Raw metadata source the shared tag UI needs, independent of server family.
///
/// The screens only ever consume fnOS-shaped models ([GenresResponse],
/// [QueryTagResponse], [TagListResponse]); each backend fills them from its own
/// endpoints. Kept as an interface so the repository/provider seam does not
/// have to know about Dio or about Emby at all.
abstract class TagSource {
  /// Genre catalogue: id + display name.
  Future<ApiResult<List<GenresResponse>>> getGenres({
    required String language,
    bool force = false,
  });

  /// Named lookup table (`iso6391`, `iso6392`, `iso3166`).
  Future<ApiResult<Map<String, String>>> getTag(
    String tag, {
    required String language,
    bool force = false,
  });

  /// Filter option set for the current browse scope.
  Future<ApiResult<TagListResponse>> getTagList({
    String? ancestorGuid,
    String? parentGuid,
    required int isFavorite,
    String? type,
  });
}
