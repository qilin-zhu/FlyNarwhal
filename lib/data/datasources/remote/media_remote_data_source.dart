import 'dart:collection';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/dio_client.dart';
import '../../models/episode_list_response.dart';
import '../../models/home_models.dart';
import '../../models/media_request_models.dart';
import '../../models/movie_detail_models.dart';
import '../../models/person_models.dart';
import '../../models/player_models.dart';
import '../../models/season_list_response.dart';
import '../../backends/media_response_parser.dart';

/// 内存 LRU 缓存，附带 TTL 过期，用于 guid 详情类请求（getItemDetail/getStreamList 等）。
class _DetailCache {
  _DetailCache({int maxEntries = 64, Duration ttl = const Duration(minutes: 5)})
      : _maxEntries = maxEntries,
        _ttl = ttl;

  final int _maxEntries;
  final Duration _ttl;
  final LinkedHashMap<String, _CacheEntry> _map = LinkedHashMap<String, _CacheEntry>();

  dynamic get(String key) {
    final entry = _map[key];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expireAt)) {
      _map.remove(key);
      return null;
    }
    // 挪到最末尾实现 LRU
    _map.remove(key);
    _map[key] = entry;
    return entry.value;
  }

  void set(String key, dynamic value) {
    _map.remove(key);
    _map[key] = _CacheEntry(value: value, expireAt: DateTime.now().add(_ttl));
    while (_map.length > _maxEntries) {
      _map.remove(_map.keys.first);
    }
  }

  void invalidate(String guid) {
    final prefix = ':$guid';
    _map.removeWhere((key, value) => key.endsWith(prefix));
  }
}

class _CacheEntry {
  final dynamic value;
  final DateTime expireAt;

  _CacheEntry({required this.value, required this.expireAt});
}

/// Remote data source for media-related API calls
class MediaRemoteDataSource {
  final DioClient _dioClient;
  final _DetailCache _cache = _DetailCache();

  MediaRemoteDataSource(this._dioClient);

  /// Get list of media databases
  Future<ApiResult<List<MediaDbListResponse>>> getMediaDbList() async {
    final result = await _dioClient.get<List<MediaDbListResponse>>(
      ApiEndpoints.mediaDbList,
      converter: (data) => MediaResponseParser.parseMediaDbListResponse(data),
    );
    return result;
  }

  /// Get media statistics summary
  Future<ApiResult<Map<String, int>>> getMediaSum() async {
    final result = await _dioClient.get<Map<String, int>>(
      ApiEndpoints.mediaDbSum,
      converter: (data) => MediaResponseParser.parseMediaSumResponse(data),
    );
    return result;
  }

  /// Get play list (recently watched)
  Future<ApiResult<List<PlayDetailResponse>>> getPlayList() async {
    final result = await _dioClient.get<List<PlayDetailResponse>>(
      ApiEndpoints.playList,
      converter: (data) => MediaResponseParser.parsePlayListResponse(data),
    );
    return result;
  }

  /// Get item list by query
  Future<ApiResult<ItemListQueryResponse>> getItemList(
    ItemListQueryRequest request,
  ) async {
    final result = await _dioClient.post<ItemListQueryResponse>(
      ApiEndpoints.itemList,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseItemListResponse(data),
    );
    return result;
  }

  /// Get favorite item list by query
  Future<ApiResult<ItemListQueryResponse>> getFavoriteList(
    ItemListQueryRequest request,
  ) async {
    final result = await _dioClient.post<ItemListQueryResponse>(
      ApiEndpoints.favoriteList,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseItemListResponse(data),
    );
    return result;
  }

  /// Get item detail by guid
  Future<ApiResult<ItemResponse>> getItemDetail(String guid) async {
    final key = 'itemDetail:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<ItemResponse>) return cached;
    final result = await _dioClient.get<ItemResponse>(
      ApiEndpoints.itemByGuid(guid),
      converter: (data) => MediaResponseParser.parseItemDetailResponse(data),
    );
    if (result.isSuccess) _cache.set(key, result);
    return result;
  }

  /// Get stream list by guid
  Future<ApiResult<StreamListResponse?>> getStreamList(String guid) async {
    final key = 'streamList:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<StreamListResponse?>) return cached;
    final result = await _dioClient.get<StreamListResponse?>(
      ApiEndpoints.streamListByGuid(guid),
      converter: (data) => MediaResponseParser.parseOptionalStreamListResponse(data),
    );
    if (result.isSuccess) _cache.set(key, result);
    return result;
  }

  /// Get play info by item guid
  Future<ApiResult<PlayInfoResponse?>> getPlayInfo(
      ItemGuidRequest request) async {
    // Playback position is volatile state that changes as soon as any episode
    // is played; even a short-lived cache makes detail pages position the
    // episode list on a stale episode. Always fetch fresh.
    return _dioClient.post<PlayInfoResponse?>(
      ApiEndpoints.playInfo,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseOptionalPlayInfoResponse(data),
    );
  }

  /// Get play info with an optional media override for player startup.
  Future<ApiResult<PlayInfoResponse?>> getPlayerPlayInfo(
    PlayInfoRequest request,
  ) async {
    final result = await _dioClient.post<PlayInfoResponse?>(
      ApiEndpoints.playInfo,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseOptionalPlayInfoResponse(data),
    );
    return result;
  }

  /// Get stream info for the selected media source.
  Future<ApiResult<StreamResponse>> getStreamInfo(StreamRequest request) async {
    final result = await _dioClient.post<StreamResponse>(
      ApiEndpoints.stream,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseStreamResponse(data),
    );
    return result;
  }

  /// Resolve the playable link for current stream parameters.
  Future<ApiResult<PlayPlayResponse>> playVideo(PlayPlayRequest request) async {
    final result = await _dioClient.post<PlayPlayResponse>(
      ApiEndpoints.playPlay,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parsePlayPlayResponse(data),
    );
    return result;
  }

  /// Download external subtitle content for media_kit rendering.
  Future<ApiResult<String>> downloadExternalSubtitle(String guid) async {
    final result = await _dioClient.get<String>(
      ApiEndpoints.subtitleDownloadByGuid(guid),
    );
    return result;
  }

  /// Search media items by keyword (GET /v/api/v1/search/list?q=)
  Future<ApiResult<List<MediaItem>>> search(String query) async {
    final result = await _dioClient.get<List<MediaItem>>(
      ApiEndpoints.searchList,
      queryParameters: {'q': query},
      converter: (data) => MediaResponseParser.parseSearchResponse(data),
    );
    return result;
  }

  /// Get person detail by guid (GET /v/api/v1/person/{guid})
  Future<ApiResult<PersonResponse>> getPerson(String guid) async {
    final key = 'person:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<PersonResponse>) return cached;
    final result = await _dioClient.get<PersonResponse>(
      ApiEndpoints.personByGuid(guid),
      converter: (data) => MediaResponseParser.parsePersonResponse(data),
    );
    if (result.isSuccess) _cache.set(key, result);
    return result;
  }

  /// Get person works grouped by job (POST /v/api/v1/person/item/list)
  Future<ApiResult<List<PersonItemList>>> getPersonItemList(
    PersonItemListRequest request,
  ) async {
    final result = await _dioClient.post<List<PersonItemList>>(
      ApiEndpoints.personItemList,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parsePersonItemListResponse(data),
    );
    return result;
  }

  /// Get person list by guid
  Future<ApiResult<List<PersonList>>> getPersonList(String guid) async {
    final key = 'personList:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<List<PersonList>>) return cached;
    final result = await _dioClient.post<List<PersonList>>(
      ApiEndpoints.personListByGuid(guid),
      data: <String, dynamic>{},
      converter: (data) => MediaResponseParser.parsePersonListResponse(data),
    );
    if (result.isSuccess) _cache.set(key, result);
    return result;
  }

  /// Get season list by guid
  Future<ApiResult<List<SeasonListResponse>>> getSeasonList(String guid) async {
    final key = 'seasonList:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<List<SeasonListResponse>>) return cached;
    final result = await _dioClient.get<List<SeasonListResponse>>(
      ApiEndpoints.seasonListByGuid(guid),
      converter: (data) => MediaResponseParser.parseSeasonListResponse(data),
    );
    if (result.isSuccess) _cache.set(key, result);
    return result;
  }

  /// Get episode list by guid
  Future<ApiResult<List<EpisodeListResponse>>> getEpisodeList(
      String guid) async {
    final key = 'episodeList:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<List<EpisodeListResponse>>) return cached;
    final result = await _dioClient.get<List<EpisodeListResponse>>(
      ApiEndpoints.episodeListByGuid(guid),
      converter: (data) => MediaResponseParser.parseEpisodeListResponse(data),
    );
    if (result.isSuccess) _cache.set(key, result);
    return result;
  }

  /// Fetch media transcode status from unified media/p endpoint.
  Future<ApiResult<MediaTranscodeResponse>> fetchTranscodeStatus(
    MediaPRequest request,
  ) async {
    final result = await _dioClient.post<MediaTranscodeResponse>(
      ApiEndpoints.mediaP,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseMediaTranscodeResponse(data),
    );
    return result;
  }

  /// Reset media quality from unified media/p endpoint.
  Future<ApiResult<MediaResetQualityResponse>> resetQuality(
    MediaPRequest request,
  ) async {
    final result = await _dioClient.post<MediaResetQualityResponse>(
      ApiEndpoints.mediaP,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseMediaResetQualityResponse(data),
    );
    return result;
  }

  /// Reset media audio from unified media/p endpoint.
  Future<ApiResult<MediaResetQualityResponse>> resetAudio(
    MediaPRequest request,
  ) async {
    final result = await _dioClient.post<MediaResetQualityResponse>(
      ApiEndpoints.mediaP,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseMediaResetQualityResponse(data),
    );
    return result;
  }

  /// Reset media subtitle from unified media/p endpoint.
  Future<ApiResult<MediaResetQualityResponse>> resetSubtitle(
    MediaPRequest request,
  ) async {
    final result = await _dioClient.post<MediaResetQualityResponse>(
      ApiEndpoints.mediaP,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseMediaResetQualityResponse(data),
    );
    return result;
  }

  /// Quit media session from unified media/p endpoint.
  Future<ApiResult<MediaResetQualityResponse>> quit(
      MediaPRequest request) async {
    final result = await _dioClient.post<MediaResetQualityResponse>(
      ApiEndpoints.mediaP,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseMediaResetQualityResponse(data),
    );
    return result;
  }

  /// Persist the current playback progress.
  Future<ApiResult<bool>> updatePlayRecord(PlayRecordRequest request) async {
    final result = await _dioClient.post<bool>(
      ApiEndpoints.playRecord,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    return result;
  }

  /// 移除续播记录（对齐 Web `DELETE /play/record`），用于「从继续观看中移除」。
  Future<ApiResult<bool>> deletePlayRecord(String guid) async {
    final result = await _dioClient.delete<bool>(
      ApiEndpoints.playRecord,
      data: ItemGuidRequest(itemGuid: guid).toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    return result;
  }

  /// Persist live-channel (IPTV) playback progress.
  Future<ApiResult<bool>> updateLivePlayRecord(
      LivePlayRecordRequest request) async {
    final result = await _dioClient.post<bool>(
      ApiEndpoints.playRecord,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    return result;
  }

  /// Save intro and outro skip settings for an item.
  Future<ApiResult<bool>> setSkipConfig(SetConfigByItemRequest request) async {
    final result = await _dioClient.post<bool>(
      ApiEndpoints.configSetByItem,
      data: request.toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    return result;
  }

  /// Toggle favorite status (add)
  Future<ApiResult<bool>> addFavorite(String guid) async {
    final result = await _dioClient.put<bool>(
      ApiEndpoints.favorite,
      data: ItemGuidRequest(itemGuid: guid).toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    return result;
  }

  /// Toggle favorite status (remove)
  Future<ApiResult<bool>> removeFavorite(String guid) async {
    final result = await _dioClient.delete<bool>(
      ApiEndpoints.favorite,
      data: ItemGuidRequest(itemGuid: guid).toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    return result;
  }

  /// Toggle watched status (mark as watched)
  Future<ApiResult<bool>> markWatched(String guid) async {
    final result = await _dioClient.post<bool>(
      ApiEndpoints.watched,
      data: ItemGuidRequest(itemGuid: guid).toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    return result;
  }

  /// Toggle watched status (mark as unwatched)
  Future<ApiResult<bool>> markUnwatched(String guid) async {
    final result = await _dioClient.delete<bool>(
      ApiEndpoints.watched,
      data: ItemGuidRequest(itemGuid: guid).toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    return result;
  }

  /// Toggle favorite state
  Future<ApiResult<bool>> toggleFavorite(
    ItemGuidRequest request, {
    required bool isFavorite,
  }) async {
    final guid = request.itemGuid;
    final result = isFavorite
        ? await _dioClient.delete<bool>(
            ApiEndpoints.favorite,
            data: request.toJson(),
            converter: (data) => MediaResponseParser.parseSuccessResponse(data),
          )
        : await _dioClient.put<bool>(
            ApiEndpoints.favorite,
            data: request.toJson(),
            converter: (data) => MediaResponseParser.parseSuccessResponse(data),
          );
    if (result.isSuccess) _cache.invalidate(guid);
    return result;
  }

  /// Toggle watched state
  Future<ApiResult<bool>> toggleWatched(
    ItemGuidRequest request, {
    required bool isWatched,
  }) async {
    final guid = request.itemGuid;
    final result = isWatched
        ? await _dioClient.delete<bool>(
            ApiEndpoints.watched,
            data: request.toJson(),
            converter: (data) => MediaResponseParser.parseSuccessResponse(data),
          )
        : await _dioClient.post<bool>(
            ApiEndpoints.watched,
            data: request.toJson(),
            converter: (data) => MediaResponseParser.parseSuccessResponse(data),
          );
    if (result.isSuccess) _cache.invalidate(guid);
    return result;
  }

  /// 预取 item 详情，写入缓存；失败静默，不抛异常。
  Future<void> prefetchItemDetail(String guid) async {
    try {
      await getItemDetail(guid);
    } catch (_) {
      // 预取失败不报错
    }
  }

  /// 清除指定 guid 的所有详情缓存。
  void invalidateDetailCache(String guid) {
    _cache.invalidate(guid);
  }

  /// 刷新条目元数据（对齐 Web `POST /item/refresh`，文件夹“更多”菜单用）。
  Future<ApiResult<bool>> refreshItemMetadata(String itemGuid) async {
    final result = await _dioClient.post<bool>(
      ApiEndpoints.itemRefresh,
      data: ItemGuidRequest(itemGuid: itemGuid).toJson(),
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    if (result.isSuccess) _cache.invalidate(itemGuid);
    return result;
  }

  /// 重新识别条目（对齐 Web `POST /scrap/rescrap`）。[type] 为条目类型，
  /// 目录传 'Directory'。
  Future<ApiResult<bool>> rescrapItem(String itemGuid, String type) async {
    final result = await _dioClient.post<bool>(
      ApiEndpoints.scrapRescrap,
      data: <String, dynamic>{
        'item_guid': itemGuid,
        'type': type,
      },
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    if (result.isSuccess) _cache.invalidate(itemGuid);
    return result;
  }

  /// 删除条目（对齐 Web `DELETE /item/:guid`，载荷在 body 里）。
  /// [deleteFile] 为 true 时同时删除磁盘文件；默认 false 仅从媒体库移除。
  ///
  /// 载荷必须放 body：服务端按 body 计算 Authx 签名，用 query 参数会被判为
  /// invalid sign；Web 端同样只在 GET 时把参数放 query。
  Future<ApiResult<bool>> deleteItem(
    String guid, {
    required bool deleteFile,
  }) async {
    final result = await _dioClient.delete<bool>(
      ApiEndpoints.itemByGuid(guid),
      data: <String, dynamic>{'delete_file': deleteFile ? 1 : 0},
      converter: (data) => MediaResponseParser.parseSuccessResponse(data),
    );
    if (result.isSuccess) _cache.invalidate(guid);
    return result;
  }
}
