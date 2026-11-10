import '../../../core/network/api_result.dart';
import '../../../core/network/dio_client.dart';
import '../../datasources/remote/media_remote_data_source.dart';
import '../../models/episode_list_response.dart';
import '../../models/home_models.dart';
import '../../models/media_request_models.dart';
import '../../models/movie_detail_models.dart';
import '../../models/person_models.dart';
import '../../models/player_models.dart';
import '../../models/season_list_response.dart';
import '../../models/user_info.dart';
import '../media_backend.dart';

/// fnOS / 飞牛影视 backend.
///
/// A pure pass-through to [MediaRemoteDataSource]: the fnOS contract is the
/// native one, so nothing is translated. Behaviour must stay byte-identical
/// to pre-abstraction releases.
class FnosMediaBackend implements MediaBackend {
  FnosMediaBackend(
    this._dataSource, {
    String Function()? getBaseUrl,
    String Function()? getToken,
    String Function()? getCookie,
    Future<ApiResult<UserInfo>> Function()? getCurrentUser,
  })  : _getBaseUrl = getBaseUrl ?? (() => ''),
        _getToken = getToken ?? (() => ''),
        _getCookie = getCookie ?? (() => ''),
        _getCurrentUser = getCurrentUser ??
            (() async => ResultFailure<UserInfo>(
                  FailureInfo.fromMessage('No user loader configured'),
                ));

  final MediaRemoteDataSource _dataSource;

  /// Session accessors read lazily, so a server-address change or a fresh
  /// login is picked up without rebuilding the backend.
  final String Function() _getBaseUrl;
  final String Function() _getToken;
  final String Function() _getCookie;
  final Future<ApiResult<UserInfo>> Function() _getCurrentUser;

  String get _token => _getToken();
  String get _cookie => _getCookie();

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        danmaku: true,
        smartSkip: true,
        liveTv: true,
        cloudDirectLink: true,
        serverTranscode: true,
        itemManagement: true,
        perUserSync: true,
      );

  /// fnOS holds a session once login persists a token.
  @override
  bool get hasSession => _token.isNotEmpty;

  /// fnOS authenticates player streams with the `Trim-MC-token` cookie that the
  /// login flow persists, plus the raw token in `Authorization`.
  @override
  Map<String, String> get playerHeaders {
    final headers = <String, String>{};
    if (_cookie.isNotEmpty) {
      headers['Cookie'] = _cookie;
    }
    if (_token.isNotEmpty) {
      headers['Authorization'] = _token;
    }
    return headers;
  }

  /// fnOS streams the original file through the media range proxy. The base
  /// URL comes from the session, so the caller rebases it.
  @override
  String buildDirectStreamUrl(String mediaGuid, {int? directLinkQualityIndex}) {
    final base = _trimSlash(_getBaseUrl());
    final qualityQuery = directLinkQualityIndex != null
        ? '?direct_link_quality_index=$directLinkQualityIndex'
        : '';
    return '$base/v/api/v1/media/range/$mediaGuid$qualityQuery';
  }

  static String _trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  @override
  Future<ApiResult<List<MediaDbListResponse>>> getMediaDbList() =>
      _dataSource.getMediaDbList();

  @override
  Future<ApiResult<Map<String, int>>> getMediaSum() => _dataSource.getMediaSum();

  @override
  Future<ApiResult<List<PlayDetailResponse>>> getPlayList() =>
      _dataSource.getPlayList();

  @override
  Future<ApiResult<ItemListQueryResponse>> getItemList(
    ItemListQueryRequest request,
  ) =>
      _dataSource.getItemList(request);

  @override
  Future<ApiResult<ItemListQueryResponse>> getFavoriteList(
    ItemListQueryRequest request,
  ) =>
      _dataSource.getFavoriteList(request);

  @override
  Future<ApiResult<ItemResponse>> getItemDetail(String guid) =>
      _dataSource.getItemDetail(guid);

  @override
  Future<ApiResult<StreamListResponse?>> getStreamList(String guid) =>
      _dataSource.getStreamList(guid);

  @override
  Future<ApiResult<PlayInfoResponse?>> getPlayInfo(ItemGuidRequest request) =>
      _dataSource.getPlayInfo(request);

  @override
  Future<ApiResult<PlayInfoResponse?>> getPlayerPlayInfo(
    PlayInfoRequest request,
  ) =>
      _dataSource.getPlayerPlayInfo(request);

  @override
  Future<ApiResult<StreamResponse>> getStreamInfo(StreamRequest request) =>
      _dataSource.getStreamInfo(request);

  @override
  Future<ApiResult<PlayPlayResponse>> playVideo(PlayPlayRequest request) =>
      _dataSource.playVideo(request);

  @override
  Future<ApiResult<String>> downloadExternalSubtitle(String guid) =>
      _dataSource.downloadExternalSubtitle(guid);

  @override
  Future<ApiResult<List<MediaItem>>> search(String query) =>
      _dataSource.search(query);

  @override
  Future<ApiResult<PersonResponse>> getPerson(String guid) =>
      _dataSource.getPerson(guid);

  @override
  Future<ApiResult<List<PersonItemList>>> getPersonItemList(
    PersonItemListRequest request,
  ) =>
      _dataSource.getPersonItemList(request);

  @override
  Future<ApiResult<List<PersonList>>> getPersonList(String guid) =>
      _dataSource.getPersonList(guid);

  @override
  Future<ApiResult<List<SeasonListResponse>>> getSeasonList(String guid) =>
      _dataSource.getSeasonList(guid);

  @override
  Future<ApiResult<List<EpisodeListResponse>>> getEpisodeList(String guid) =>
      _dataSource.getEpisodeList(guid);

  @override
  Future<ApiResult<MediaTranscodeResponse>> fetchTranscodeStatus(
    MediaPRequest request,
  ) =>
      _dataSource.fetchTranscodeStatus(request);

  @override
  Future<ApiResult<MediaResetQualityResponse>> resetQuality(
    MediaPRequest request,
  ) =>
      _dataSource.resetQuality(request);

  @override
  Future<ApiResult<MediaResetQualityResponse>> resetAudio(
    MediaPRequest request,
  ) =>
      _dataSource.resetAudio(request);

  @override
  Future<ApiResult<MediaResetQualityResponse>> resetSubtitle(
    MediaPRequest request,
  ) =>
      _dataSource.resetSubtitle(request);

  @override
  Future<ApiResult<MediaResetQualityResponse>> quit(MediaPRequest request) =>
      _dataSource.quit(request);

  @override
  Future<ApiResult<bool>> updatePlayRecord(PlayRecordRequest request) =>
      _dataSource.updatePlayRecord(request);

  @override
  Future<ApiResult<bool>> deletePlayRecord(String guid) =>
      _dataSource.deletePlayRecord(guid);

  @override
  Future<ApiResult<bool>> updateLivePlayRecord(
    LivePlayRecordRequest request,
  ) =>
      _dataSource.updateLivePlayRecord(request);

  @override
  Future<ApiResult<bool>> setSkipConfig(SetConfigByItemRequest request) =>
      _dataSource.setSkipConfig(request);

  @override
  Future<ApiResult<bool>> addFavorite(String guid) =>
      _dataSource.addFavorite(guid);

  @override
  Future<ApiResult<bool>> removeFavorite(String guid) =>
      _dataSource.removeFavorite(guid);

  @override
  Future<ApiResult<bool>> markWatched(String guid) =>
      _dataSource.markWatched(guid);

  @override
  Future<ApiResult<bool>> markUnwatched(String guid) =>
      _dataSource.markUnwatched(guid);

  @override
  Future<ApiResult<bool>> toggleFavorite(
    ItemGuidRequest request, {
    required bool isFavorite,
  }) =>
      _dataSource.toggleFavorite(request, isFavorite: isFavorite);

  @override
  Future<ApiResult<bool>> toggleWatched(
    ItemGuidRequest request, {
    required bool isWatched,
  }) =>
      _dataSource.toggleWatched(request, isWatched: isWatched);

  @override
  Future<void> prefetchItemDetail(String guid) =>
      _dataSource.prefetchItemDetail(guid);

  @override
  void invalidateDetailCache(String guid) =>
      _dataSource.invalidateDetailCache(guid);

  @override
  Future<ApiResult<bool>> refreshItemMetadata(String itemGuid) =>
      _dataSource.refreshItemMetadata(itemGuid);

  @override
  Future<ApiResult<bool>> rescrapItem(String itemGuid, String type) =>
      _dataSource.rescrapItem(itemGuid, type);

  @override
  Future<ApiResult<bool>> deleteItem(String guid, {required bool deleteFile}) =>
      _dataSource.deleteItem(guid, deleteFile: deleteFile);

  /// fnOS exposes the signed-in user through `user/info`, which lives on a
  /// different data source. The provider graph supplies the loader so this
  /// backend stays constructible without a second dependency.
  @override
  Future<ApiResult<UserInfo>> getCurrentUser() => _getCurrentUser();

  /// Exposed so [MediaRemoteDataSource]-typed collaborators (player service,
  /// smart-analysis controller) can keep their existing constructor types.
  MediaRemoteDataSource get dataSource => _dataSource;

  /// Factory used by the provider graph.
  static FnosMediaBackend fromDioClient(
    DioClient dioClient, {
    String Function()? getToken,
    String Function()? getCookie,
    Future<ApiResult<UserInfo>> Function()? getCurrentUser,
  }) =>
      FnosMediaBackend(
        MediaRemoteDataSource(dioClient),
        getBaseUrl: () => dioClient.dio.options.baseUrl,
        getToken: getToken,
        getCookie: getCookie,
        getCurrentUser: getCurrentUser,
      );
}
