import '../../core/network/api_result.dart';
import '../models/episode_list_response.dart';
import '../models/home_models.dart';
import '../models/media_request_models.dart';
import '../models/movie_detail_models.dart';
import '../models/person_models.dart';
import '../models/player_models.dart';
import '../models/season_list_response.dart';
import '../models/user_info.dart';

/// Server-agnostic media API surface.
///
/// Every backend (fnOS, Emby family) implements this with the same result
/// types, so UI and player code stay unaware of which server it is talking to.
/// The signatures mirror [MediaRemoteDataSource] one-for-one on purpose: the
/// fnOS backend is a thin pass-through and the Emby backend translates the
/// remote payload into the same result models.
abstract class MediaBackend {
  /// Whether this backend can serve the given capability. The UI uses this to
  /// hide entries that only one server family implements (danmaku, intro
  /// skipping, netdisk direct links, IPTV).
  BackendCapabilities get capabilities;

  /// Headers the media player must send when opening a stream URL.
  Map<String, String> get playerHeaders;

  /// Absolute URL that streams an item's original file directly.
  ///
  /// fnOS routes this through `/v/api/v1/media/range/{guid}` and negotiates
  /// quality with a query parameter; Emby uses
  /// `/Videos/{id}/stream?static=true&api_key=`. Both are plain progressive
  /// HTTP endpoints that honour `Range`, which is what mpv needs.
  ///
  /// [directLinkQualityIndex] is only meaningful for fnOS netdisk media.
  String buildDirectStreamUrl(
    String mediaGuid, {
    int? directLinkQualityIndex,
  });

  /// Whether the backend holds a usable session right now. The shell gates
  /// user-info loading on this instead of inspecting fnOS storage keys, which
  /// Emby never writes.
  bool get hasSession;

  /// The signed-in user, as the shell needs it (guid for per-user settings,
  /// username for the account menu, admin flag for item-management entries).
  ///
  /// Part of the backend contract because fnOS reads it from
  /// `user/info` while Emby derives it from the authenticated session.
  Future<ApiResult<UserInfo>> getCurrentUser();

  /// Get list of media databases
  Future<ApiResult<List<MediaDbListResponse>>> getMediaDbList();

  /// Get media statistics summary
  Future<ApiResult<Map<String, int>>> getMediaSum();

  /// Get play list (recently watched)
  Future<ApiResult<List<PlayDetailResponse>>> getPlayList();

  /// Get item list by query
  Future<ApiResult<ItemListQueryResponse>> getItemList(
    ItemListQueryRequest request,
  );

  /// Get favorite item list by query
  Future<ApiResult<ItemListQueryResponse>> getFavoriteList(
    ItemListQueryRequest request,
  );

  /// Get item detail by guid
  Future<ApiResult<ItemResponse>> getItemDetail(String guid);

  /// Get stream list by guid
  Future<ApiResult<StreamListResponse?>> getStreamList(String guid);

  /// Get play info by item guid
  Future<ApiResult<PlayInfoResponse?>> getPlayInfo(ItemGuidRequest request);

  /// Get play info with an optional media override for player startup.
  Future<ApiResult<PlayInfoResponse?>> getPlayerPlayInfo(
    PlayInfoRequest request,
  );

  /// Get stream info for the selected media source.
  Future<ApiResult<StreamResponse>> getStreamInfo(StreamRequest request);

  /// Resolve the playable link for current stream parameters.
  Future<ApiResult<PlayPlayResponse>> playVideo(PlayPlayRequest request);

  /// Download external subtitle content for media_kit rendering.
  Future<ApiResult<String>> downloadExternalSubtitle(String guid);

  /// Search media items by keyword
  Future<ApiResult<List<MediaItem>>> search(String query);

  /// Get person detail by guid
  Future<ApiResult<PersonResponse>> getPerson(String guid);

  /// Get person works grouped by job
  Future<ApiResult<List<PersonItemList>>> getPersonItemList(
    PersonItemListRequest request,
  );

  /// Get person list by guid (cast & crew of an item)
  Future<ApiResult<List<PersonList>>> getPersonList(String guid);

  /// Get season list by guid
  Future<ApiResult<List<SeasonListResponse>>> getSeasonList(String guid);

  /// Get episode list by guid
  Future<ApiResult<List<EpisodeListResponse>>> getEpisodeList(String guid);

  /// Fetch media transcode status
  Future<ApiResult<MediaTranscodeResponse>> fetchTranscodeStatus(
    MediaPRequest request,
  );

  /// Reset media quality
  Future<ApiResult<MediaResetQualityResponse>> resetQuality(
    MediaPRequest request,
  );

  /// Reset media audio
  Future<ApiResult<MediaResetQualityResponse>> resetAudio(
    MediaPRequest request,
  );

  /// Reset media subtitle
  Future<ApiResult<MediaResetQualityResponse>> resetSubtitle(
    MediaPRequest request,
  );

  /// Quit media session
  Future<ApiResult<MediaResetQualityResponse>> quit(MediaPRequest request);

  /// Persist the current playback progress.
  Future<ApiResult<bool>> updatePlayRecord(PlayRecordRequest request);

  /// Remove a resume entry.
  Future<ApiResult<bool>> deletePlayRecord(String guid);

  /// Persist live-channel playback progress.
  Future<ApiResult<bool>> updateLivePlayRecord(LivePlayRecordRequest request);

  /// Save intro and outro skip settings for an item.
  Future<ApiResult<bool>> setSkipConfig(SetConfigByItemRequest request);

  /// Add favorite
  Future<ApiResult<bool>> addFavorite(String guid);

  /// Remove favorite
  Future<ApiResult<bool>> removeFavorite(String guid);

  /// Mark watched
  Future<ApiResult<bool>> markWatched(String guid);

  /// Mark unwatched
  Future<ApiResult<bool>> markUnwatched(String guid);

  /// Toggle favorite state
  Future<ApiResult<bool>> toggleFavorite(
    ItemGuidRequest request, {
    required bool isFavorite,
  });

  /// Toggle watched state
  Future<ApiResult<bool>> toggleWatched(
    ItemGuidRequest request, {
    required bool isWatched,
  });

  /// Prefetch item detail into the backend cache; failures are swallowed.
  Future<void> prefetchItemDetail(String guid);

  /// Drop cached detail entries for a guid.
  void invalidateDetailCache(String guid);

  /// Refresh item metadata
  Future<ApiResult<bool>> refreshItemMetadata(String itemGuid);

  /// Re-identify an item
  Future<ApiResult<bool>> rescrapItem(String itemGuid, String type);

  /// Delete an item
  Future<ApiResult<bool>> deleteItem(
    String guid, {
    required bool deleteFile,
  });
}

/// Feature flags a backend reports so shared UI can hide unsupported entries.
class BackendCapabilities {
  const BackendCapabilities({
    this.danmaku = false,
    this.smartSkip = false,
    this.liveTv = false,
    this.cloudDirectLink = false,
    this.serverTranscode = false,
    this.itemManagement = false,
    this.perUserSync = false,
  });

  /// fnOS + FlyNarwhal server: danmaku overlay.
  final bool danmaku;

  /// Intro/outro auto-skip driven by server-side analysis.
  final bool smartSkip;

  /// IPTV live channel libraries.
  final bool liveTv;

  /// Netdisk (Quark/Baidu) direct-link qualities.
  final bool cloudDirectLink;

  /// Server-side transcoding controlled through `/media/p`.
  final bool serverTranscode;

  /// Metadata refresh / rescrape / delete.
  final bool itemManagement;

  /// Per-user settings blob (`user/getData`).
  final bool perUserSync;
}
