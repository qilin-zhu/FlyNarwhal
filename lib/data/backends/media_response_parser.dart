import '../../core/constants/app_constants.dart';
import '../../core/network/api_result.dart';
import '../models/base_response.dart';
import '../models/episode_list_response.dart';
import '../models/home_models.dart';
import '../models/movie_detail_models.dart';
import '../models/person_models.dart';
import '../models/player_models.dart';
import '../models/season_list_response.dart';

/// Parsers for the fnOS `/v/api/v1` response envelope.
///
/// Shared by every backend: the Emby family translates its payload into the
/// same envelope shape before parsing, which keeps result semantics (error
/// codes, optional payloads, tolerant empty lists) identical across servers.
class MediaResponseParser {
  const MediaResponseParser._();

  static List<MediaDbListResponse> parseMediaDbListResponse(dynamic data) {
    final baseResponse = FnBaseResponse<List<MediaDbListResponse>>.fromJson(
      data,
      (json) => (json as List)
          .map((e) => MediaDbListResponse.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data ?? [];
  }

  static Map<String, int> parseMediaSumResponse(dynamic data) {
    final baseResponse = FnBaseResponse<Map<String, int>>.fromJson(
      data,
      (json) => (json as Map<String, dynamic>)
          .map((key, value) => MapEntry(key, value as int)),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data ?? {};
  }

  static List<PlayDetailResponse> parsePlayListResponse(dynamic data) {
    final baseResponse = FnBaseResponse<List<PlayDetailResponse>>.fromJson(
      data,
      (json) => (json as List)
          .map((e) => PlayDetailResponse.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data ?? [];
  }

  static ItemListQueryResponse parseItemListResponse(dynamic data) {
    final baseResponse = FnBaseResponse<ItemListQueryResponse>.fromJson(
      data,
      (json) => ItemListQueryResponse.fromJson(json as Map<String, dynamic>),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data ?? ItemListQueryResponse();
  }

  static ItemResponse parseItemDetailResponse(dynamic data) {
    try {
      final baseResponse = FnBaseResponse<ItemResponse>.fromJson(
        data,
        (json) => ItemResponse.fromJson(json as Map<String, dynamic>),
      );
      if (baseResponse.code != ResponseCodes.success ||
          baseResponse.data == null) {
        throw Exception(
          'Item detail response invalid: '
          'code=${baseResponse.code}, msg=${baseResponse.msg}, '
          '${describeItemDetailData(data)}',
        );
      }
      return baseResponse.data!;
    } catch (e) {
      throw Exception(
        'Item detail parse failed: ${describeItemDetailData(data)}; error=$e',
      );
    }
  }

  static String describeItemDetailData(dynamic data) {
    final buffer = StringBuffer('type=${data.runtimeType}');
    if (data is Map) {
      final keys = data.keys.take(10).map((key) => key.toString()).join(', ');
      buffer.write(', keys=[$keys]');
      final payload = data['data'];
      buffer.write(', dataType=${payload.runtimeType}');
      if (payload is Map) {
        final payloadKeys =
            payload.keys.take(10).map((key) => key.toString()).join(', ');
        buffer.write(', dataKeys=[$payloadKeys]');
      }
    }
    return buffer.toString();
  }

  static StreamListResponse? parseOptionalStreamListResponse(dynamic data) {
    final baseResponse = FnBaseResponse<StreamListResponse>.fromJson(
      data,
      (json) => StreamListResponse.fromJson(json as Map<String, dynamic>),
    );
    return baseResponse.data;
  }

  static PlayInfoResponse? parseOptionalPlayInfoResponse(dynamic data) {
    final baseResponse = FnBaseResponse<PlayInfoResponse>.fromJson(
      data,
      (json) => PlayInfoResponse.fromJson(json as Map<String, dynamic>),
    );
    return baseResponse.data;
  }

  static StreamResponse parseStreamResponse(dynamic data) {
    final baseResponse = FnBaseResponse<StreamResponse>.fromJson(
      data,
      (json) => StreamResponse.fromJson(json as Map<String, dynamic>),
    );
    if (baseResponse.code != ResponseCodes.success ||
        baseResponse.data == null) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data!;
  }

  static PlayPlayResponse parsePlayPlayResponse(dynamic data) {
    final baseResponse = FnBaseResponse<PlayPlayResponse>.fromJson(
      data,
      (json) => PlayPlayResponse.fromJson(json as Map<String, dynamic>),
    );
    if (baseResponse.code != ResponseCodes.success ||
        baseResponse.data == null) {
      // Keep the business code in the message: callers (e.g. the player's
      // direct-link fallback) match on it, and the server may return an
      // empty msg which would otherwise produce an unreadable exception.
      final detail = 'code=${baseResponse.code} msg=${baseResponse.msg}';
      throw FailureInfo(
        message: detail,
        code: baseResponse.code,
        displayMessage: detail,
      );
    }
    return baseResponse.data!;
  }

  static List<MediaItem> parseSearchResponse(dynamic data) {
    final baseResponse = FnBaseResponse<List<MediaItem>>.fromJson(
      data,
      (json) => ((json as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data ?? const <MediaItem>[];
  }

  static PersonResponse parsePersonResponse(dynamic data) {
    final baseResponse = FnBaseResponse<PersonResponse>.fromJson(
      data,
      (json) => PersonResponse.fromJson(json as Map<String, dynamic>),
    );
    if (baseResponse.code != ResponseCodes.success) {
      // Keep the business code so callers can tell "person record missing"
      // (rendered as an empty state) apart from real failures.
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    if (baseResponse.data == null) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data!;
  }

  static List<PersonItemList> parsePersonItemListResponse(dynamic data) {
    final baseResponse = FnBaseResponse<PersonItemListQueryResponse>.fromJson(
      data,
      (json) => PersonItemListQueryResponse.fromJson(
          json as Map<String, dynamic>),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data?.list ?? const <PersonItemList>[];
  }

  static List<PersonList> parsePersonListResponse(dynamic data) {
    final baseResponse = FnBaseResponse<PersonListResponse>.fromJson(
      data,
      (json) => PersonListResponse.fromJson(json as Map<String, dynamic>),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data?.list ?? [];
  }

  static List<SeasonListResponse> parseSeasonListResponse(dynamic data) {
    final baseResponse = FnBaseResponse<List<SeasonListResponse>>.fromJson(
      data,
      (json) => ((json as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => SeasonListResponse.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data ?? const <SeasonListResponse>[];
  }

  static List<EpisodeListResponse> parseEpisodeListResponse(dynamic data) {
    if (data is List) {
      return data
          .map((e) => EpisodeListResponse.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    final baseResponse = FnBaseResponse<List<EpisodeListResponse>>.fromJson(
      data,
      (json) => ((json as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => EpisodeListResponse.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    if (baseResponse.code != ResponseCodes.success) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data ?? const <EpisodeListResponse>[];
  }

  static MediaTranscodeResponse parseMediaTranscodeResponse(dynamic data) {
    final baseResponse = FnBaseResponse<MediaTranscodeResponse>.fromJson(
      data,
      (json) => MediaTranscodeResponse.fromJson(json as Map<String, dynamic>),
    );
    if (baseResponse.code != ResponseCodes.success ||
        baseResponse.data == null) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    return baseResponse.data!;
  }

  static MediaResetQualityResponse parseMediaResetQualityResponse(dynamic data) {
    final baseResponse = FnBaseResponse<MediaResetQualityResponse>.fromJson(
      data,
      (json) =>
          MediaResetQualityResponse.fromJson(json as Map<String, dynamic>),
    );
    if (baseResponse.code != ResponseCodes.success ||
        baseResponse.data == null) {
      throw FailureInfo.fromResponse(
        code: baseResponse.code,
        msg: baseResponse.msg,
      );
    }
    final response = baseResponse.data!;
    if (!response.isSuccess) {
      throw Exception(response.describeFailure('media/p'));
    }
    return response;
  }

  static bool parseSuccessResponse(dynamic data) {
    if (data is bool) return data;
    if (data is Map) {
      if (data['code'] == ResponseCodes.success) return true;
      if (data['success'] == true) return true;
    }
    return false;
  }
}
