import 'dart:collection';

import '../../../core/network/api_result.dart';
import '../../../core/network/ssl/ssl_trust_manager.dart';
import '../../../core/utils/log/app_talker.dart';
import '../../backends/media_response_parser.dart';
import '../../models/episode_list_response.dart';
import '../../models/home_models.dart';
import '../../models/media_request_models.dart';
import '../../models/movie_detail_models.dart';
import '../../models/person_models.dart';
import '../../models/player_models.dart';
import '../../models/season_list_response.dart';
import '../../models/user_info.dart';
import '../media_backend.dart';
import 'emby_api.dart';
import 'emby_mapper.dart';
import 'emby_tags.dart';
import 'emby_urls.dart';

/// Emby / Jellyfin backend.
///
/// Every method maps its remote payload through [EmbyMapper] into the fnOS
/// envelope shape and then reuses [MediaResponseParser], so result semantics
/// stay identical to the fnOS backend.
class EmbyMediaBackend implements MediaBackend {
  EmbyMediaBackend({
    required EmbyApi api,
    required String initialBaseUrl,
    Map<String, dynamic>? serverInfo,
    SslTrustManager? sslTrustManager,
    Future<void> Function(SslTrustEntry entry)? persistSslTrustEntry,
  })  : _api = api,
        _baseUrl = initialBaseUrl,
        _serverInfo = serverInfo ?? const <String, dynamic>{};

  final EmbyApi _api;
  final String _baseUrl;
  final Map<String, dynamic> _serverInfo;
  final _DetailCache _cache = _DetailCache();

  /// The FlyNarwhal sidecar server (danmaku, smart skip) is configured
  /// independently of the media backend, so it stays available on Emby — the
  /// player matches episodes by title/season rather than backend guid. Emby
  /// has no IPTV libraries and no netdisk provider integration. Item
  /// management is available.
  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
        danmaku: true,
        smartSkip: true,
        itemManagement: true,
      );

  /// Emby authenticates streams with an `Authorization` header; the URL itself
  /// also carries `ApiKey`, which mpv follows across range requests.
  @override
  Map<String, String> get playerHeaders =>
      EmbyUrls.authorizationHeaders(_api.credentials.accessToken);

  /// Emby serves the original file through `/Videos/{id}/stream?static=true`,
  /// which honours `Range` exactly like the fnOS media range proxy.
  ///
  /// `MediaSourceId` is the *media source's* id, not the item id. Emby returns
  /// it as `mediasource_<itemId>` for lazily opened sources (strm / cloud) and
  /// answers `400 Value cannot be null. (Parameter 'mediaSource')` when handed
  /// the item id instead. Only the query parameter takes that id: the path
  /// segment stays the item id, and `/Videos/mediasource_<itemId>/…` answers
  /// `500 Unrecognized Guid format.`
  ///
  /// Every transcode URL also carries a `PlaySessionId`. Without one Emby
  /// still builds the playlists, but it stamps `?PlaySessionId=` (empty) onto
  /// each segment URI, and every segment request then fails with
  /// `400 Value cannot be null. (Parameter 'key')`.
  @override
  String buildDirectStreamUrl(String mediaGuid, {int? directLinkQualityIndex}) {
    final raw = EmbyMapper.rawId(mediaGuid);
    final id = _itemIdFor(raw);
    return _api.streamUrl(id, mediaSourceId: _mediaSourceIdFor(id));
  }

  /// Item id that owns [mediaGuid].
  ///
  /// Every playback request is addressed by `file_stream.guid`, which this
  /// backend fills with the *media source* id (`mediasource_<itemId>`). The
  /// `/Videos/{id}/…` path segment needs the item id, so the source id has to
  /// be mapped back; using it verbatim answers `500 Unrecognized Guid format.`
  ///
  /// The cached pair from [getStreamInfo] is authoritative; stripping Emby's
  /// `mediasource_` prefix is the fallback for a source that was never cached
  /// (a quality switch after a restart, say).
  String _itemIdFor(String mediaGuid) {
    final raw = EmbyMapper.rawId(mediaGuid);
    final cached = _lastMediaSource;
    if (cached != null && cached.$2 == raw) {
      return cached.$1;
    }
    const sourcePrefix = 'mediasource_';
    if (raw.startsWith(sourcePrefix)) {
      final stripped = raw.substring(sourcePrefix.length);
      if (stripped.isNotEmpty) return stripped;
    }
    return raw;
  }

  /// Media source id reported by the last [getStreamInfo] for [itemId].
  ///
  /// Falls back to the item id only when the cached source belongs to another
  /// item, which is the shape servers that use the item id as source id
  /// (older Jellyfin) expect. A single entry suffices: getStreamInfo always
  /// runs for the item about to play, and the URL builders are called for that
  /// same item immediately afterwards.
  String _mediaSourceIdFor(String itemId) {
    final cached = _lastMediaSource;
    if (cached == null || cached.$1 != itemId || cached.$2.isEmpty) {
      return itemId;
    }
    return cached.$2;
  }

  /// Emby holds a session once an access token and user id are present.
  @override
  bool get hasSession =>
      _api.credentials.accessToken.isNotEmpty &&
      _api.credentials.userId.isNotEmpty;

  String get userId => _api.credentials.userId;

  Map<String, dynamic> get serverInfo => _serverInfo;

  EmbyApi get api => _api;

  static const String _itemFields = 'PrimaryImageAspectRatio,Overview,Genres,'
      'ProductionYear,PremiereDate,RunTimeTicks,UserData,ChildCount,'
      'RecursiveItemCount,OfficialRating,CommunityRating,DateCreated,'
      'MediaSources,MediaStreams,ProviderIds,ProductionLocations,Status,'
      'SeriesId,SeasonId,SeriesName,SeasonName,IndexNumber,ParentIndexNumber';

  static const String _videoTypes = 'Movie,Series,Episode,Video,BoxSet,Folder,'
      'CollectionFolder,MusicVideo,Person,PhotoAlbum';

  // ---------------------------------------------------------------- libraries

  @override
  Future<ApiResult<List<MediaDbListResponse>>> getMediaDbList() async {
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Views',
      query: {'Fields': 'PrimaryImageAspectRatio,ChildCount'},
    );
    return result.map((payload) {
      final items = (payload['Items'] as List?) ?? const [];
      return MediaResponseParser.parseMediaDbListResponse(
        _envelope(EmbyMapper.toMediaDbList(items, _baseUrl)),
      );
    });
  }

  @override
  Future<ApiResult<Map<String, int>>> getMediaSum() async {
    final result = await _api.get<Map<String, dynamic>>(
      '/Items/Counts',
      query: {'UserId': userId},
    );
    return result.map((payload) {
      return MediaResponseParser.parseMediaSumResponse(
        _envelope(EmbyMapper.toMediaSum(payload)),
      );
    });
  }

  @override
  Future<ApiResult<List<PlayDetailResponse>>> getPlayList() async {
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/Resume',
      query: {
        'Limit': 20,
        'MediaTypes': 'Video',
        'Fields': _itemFields,
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary,Backdrop',
      },
    );
    return result.map((payload) {
      final items = (payload['Items'] as List?) ?? const [];
      return MediaResponseParser.parsePlayListResponse(
        _envelope(EmbyMapper.toPlayDetailList(items, _baseUrl)),
      );
    });
  }

  // ------------------------------------------------------------------- browse

  @override
  Future<ApiResult<ItemListQueryResponse>> getItemList(
    ItemListQueryRequest request,
  ) async {
    final ancestorGuid = request.ancestorGuid;
    final parentGuid = request.parentGuid;
    final scopedGuid = (ancestorGuid != null && ancestorGuid.isNotEmpty)
        ? ancestorGuid
        : (parentGuid != null && parentGuid.isNotEmpty ? parentGuid : null);
    final parentId = scopedGuid == null ? null : EmbyMapper.rawId(scopedGuid);
    if (parentId == null) {
      return Success(ItemListQueryResponse());
    }

    final includeTypes = _includeItemTypes(request.tags.type);
    // Library-root galleries (no fv_ prefix) render real titles as poster
    // cards, not the physical folder tree: Emby organises libraries into
    // subfolders (韩国电影/日本电影/…), so a non-recursive listing shows only
    // unnamed folder shells and the fnOS category root disappears. Recursing
    // from the library root and filtering to the leaf types the card grid can
    // play or open restores the expected rows (凡人修仙传, 灵山恶灾, …).
    // Folder drill-downs (fv_*) keep the non-recursive parent listing.
    final isLibraryRoot = !(scopedGuid?.startsWith(EmbyMapper.folderPrefix) ??
        true) &&
        (ancestorGuid?.isNotEmpty == true);
    final recursive = isLibraryRoot;

    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items',
      query: {
        'ParentId': parentId,
        'Recursive': recursive,
        'IncludeItemTypes':
            recursive ? _leafItemTypes(includeTypes) : includeTypes,
        'Fields': _itemFields,
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary,Backdrop',
        'SortBy': _sortBy(request.sortColumn),
        'SortOrder': request.sortType.toUpperCase() == 'ASC'
            ? 'Ascending'
            : 'Descending',
        ..._tagFilters(request.tags),
        'StartIndex': (request.page - 1) * request.pageSize,
        'Limit': request.pageSize,
      },
    );

    // A folder drill-down needs the container's own name and its ancestor chain:
    // the folder screen renders the last jump entry as the page title and the
    // preceding ones as breadcrumbs. Without it the header falls back to the
    // localized "Folder" placeholder even though the server knows the name.
    // Its library id also replaces the folder id as `ancestor_guid`, because
    // that field drives the breadcrumb root and the per-library settings key.
    final trail = scopedGuid != null &&
            scopedGuid.startsWith(EmbyMapper.folderPrefix)
        ? await _folderTrail(parentId)
        : null;
    final ancestorGuidForItems =
        (trail?['library_guid'] as String?)?.isNotEmpty == true
            ? trail!['library_guid'] as String
            : scopedGuid;

    return result.map((payload) {
      return MediaResponseParser.parseItemListResponse(
        _envelope(EmbyMapper.toItemListQuery(
          payload,
          _baseUrl,
          ancestorGuid: ancestorGuidForItems,
          ancestorCategory: includeTypes.contains('Series') ? 'TV' : null,
          mdbName: trail?['mdb_name'] as String?,
          jumpList: trail?['jump_list'] as List<Map<String, dynamic>>?,
        )),
      );
    });
  }

  /// Name + ancestor chain for a folder, cached with the detail entry.
  Future<Map<String, dynamic>?> _folderTrail(String folderId) async {
    final key = 'folderTrail:$folderId';
    final cached = _cache.get(key);
    if (cached is Map<String, dynamic>) return cached;

    final detail = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$folderId',
    );
    final item = detail.dataOrNull;
    if (item == null) return null;
    final name = item['Name']?.toString() ?? '';
    if (name.isEmpty) return null;

    final ancestors =
        await _api.get<List<dynamic>>('/Items/$folderId/Ancestors', query: {
      'UserId': userId,
    });
    final trail = EmbyMapper.folderTrail(
      ancestors.dataOrNull ?? const [],
      folderId: folderId,
      folderName: name,
    );
    _cache.set(key, trail);
    return trail;
  }

  @override
  Future<ApiResult<ItemListQueryResponse>> getFavoriteList(
    ItemListQueryRequest request,
  ) async {
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items',
      query: {
        'Recursive': true,
        'Filters': 'IsFavorite',
        'IncludeItemTypes': _includeItemTypes(request.tags.type),
        'Fields': _itemFields,
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary,Backdrop',
        'SortBy': _sortBy(request.sortColumn),
        'SortOrder': request.sortType.toUpperCase() == 'ASC'
            ? 'Ascending'
            : 'Descending',
        'StartIndex': (request.page - 1) * request.pageSize,
        'Limit': request.pageSize,
      },
    );
    return result.map((payload) {
      return MediaResponseParser.parseItemListResponse(
        _envelope(EmbyMapper.toItemListQuery(payload, _baseUrl)),
      );
    });
  }

  /// fnOS filter tags → Jellyfin query parameters.
  ///
  /// The shared filter bar speaks fnOS (`genres` is an int id, `decade` is a
  /// label such as `2010s`, resolution buckets are strings), so every selected
  /// option has to be translated or the selection would only change the UI
  /// while the request stayed unfiltered.
  static Map<String, dynamic> _tagFilters(Tags tags) {
    final query = <String, dynamic>{};
    final genreName = EmbyGenreIndex.nameOf(tags.genres);
    if (genreName != null && genreName.isNotEmpty) {
      query['Genres'] = genreName;
    }
    final (minHeight, maxHeight) = EmbyTags.heightRange(tags.resolution) ??
        (null, null);
    if (minHeight != null) query['MinHeight'] = minHeight;
    if (maxHeight != null) query['MaxHeight'] = maxHeight;
    final years = EmbyTags.yearsFilter(tags.decade);
    if (years != null) query['Years'] = years;
    if (tags.locate != null && tags.locate!.isNotEmpty) {
      query['ProductionLocations'] = tags.locate;
    }
    final watched = EmbyTags.watchedFilter(tags.watched);
    if (watched != null) query['Filters'] = watched;
    return query;
  }

  static String _includeItemTypes(List<String> types) {    if (types.isEmpty) return _videoTypes;
    final mapped = <String>{};
    for (final type in types) {
      switch (type) {
        case 'Movie':
          mapped.add('Movie');
          break;
        case 'TV':
          mapped.add('Series');
          break;
        case 'Directory':
          mapped.addAll(['Folder', 'BoxSet', 'CollectionFolder', 'PhotoAlbum']);
          break;
        case 'Video':
          mapped.addAll(['Video', 'MusicVideo']);
          break;
        case 'Episode':
          mapped.add('Episode');
          break;
        case 'Season':
          mapped.add('Season');
          break;
        default:
          break;
      }
    }
    return mapped.isEmpty ? _videoTypes : mapped.join(',');
  }

  /// fnOS sort columns → Emby `SortBy`.
  /// The leaf item types a library-root gallery can render. Folders are
  /// excluded: they are the physical organisation layer, not playable cards.
  static String _leafItemTypes(String includeTypes) {
    final leaves = includeTypes
        .split(',')
        .where((t) =>
            t != 'Folder' && t != 'BoxSet' && t != 'CollectionFolder' &&
            t != 'PhotoAlbum')
        .toList();
    return leaves.join(',');
  }

  static String _sortBy(String column) {    switch (column) {
      case 'sort_title':
        return 'SortName';
      case 'create_time':
        return 'DateCreated';
      case 'release_date':
        return 'PremiereDate';
      case 'vote_average':
        return 'CommunityRating';
      case 'watched_ts':
        return 'DatePlayed';
      default:
        return 'SortName';
    }
  }

  // ------------------------------------------------------------------- detail

  @override
  Future<ApiResult<ItemResponse>> getItemDetail(String guid) async {
    final key = 'itemDetail:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<ItemResponse>) return cached;

    final id = EmbyMapper.rawId(guid);
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$id',
      query: {'Fields': _itemFields},
    );
    final mapped = result.map((payload) {
      return MediaResponseParser.parseItemDetailResponse(
        _envelope(EmbyMapper.toItemResponse(payload, _baseUrl)),
      );
    });
    if (mapped.isSuccess) _cache.set(key, mapped);
    return mapped;
  }

  @override
  Future<ApiResult<StreamListResponse?>> getStreamList(String guid) async {
    final key = 'streamList:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<StreamListResponse?>) return cached;

    final id = EmbyMapper.rawId(guid);
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$id',
      query: {'Fields': _itemFields},
    );
    final mapped = result.map((payload) {
      final sources = (payload['MediaSources'] as List?) ?? const [];
      if (sources.isEmpty) {
        return MediaResponseParser.parseOptionalStreamListResponse(
          _envelope(null),
        );
      }
      final streams = EmbyMapper.toStreamResponse(
        payload,
        _baseUrl,
        source: Map<String, dynamic>.from(sources.first as Map),
      );
      return MediaResponseParser.parseOptionalStreamListResponse(_envelope({
        'files': <dynamic>[streams['file_stream']],
        'video_streams': <dynamic>[
          if (streams['video_stream'] != null) streams['video_stream'],
        ],
        'audio_streams': streams['audio_streams'],
        'subtitle_streams': streams['subtitle_streams'],
      }));
    });
    if (mapped.isSuccess) _cache.set(key, mapped);
    return mapped;
  }

  // ----------------------------------------------------------------- playback

  @override
  Future<ApiResult<PlayInfoResponse?>> getPlayInfo(
    ItemGuidRequest request,
  ) async {
    return _negotiatePlayInfo(request.itemGuid, mediaGuid: null);
  }

  @override
  Future<ApiResult<PlayInfoResponse?>> getPlayerPlayInfo(
    PlayInfoRequest request,
  ) async {
    return _negotiatePlayInfo(request.itemGuid, mediaGuid: request.mediaGuid);
  }

  Future<ApiResult<PlayInfoResponse?>> _negotiatePlayInfo(
    String guid, {
    String? mediaGuid,
  }) async {
    final id = EmbyMapper.rawId(guid);
    final detail = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$id',
      query: {'Fields': _itemFields},
    );
    if (!detail.isSuccess) {
      return ResultFailure(detail.failureOrNull!);
    }
    final item = detail.dataOrNull!;
    final sources = (item['MediaSources'] as List?) ?? const [];
    final source = sources.isEmpty
        ? await _fetchPlaybackSource(id)
        : Map<String, dynamic>.from(sources.first as Map);
    if (source.isEmpty) {
      return Success(null);
    }

    Map<String, dynamic>? series;
    final seriesId = item['SeriesId']?.toString();
    if (seriesId != null && seriesId.isNotEmpty) {
      final seriesResult = await _api.get<Map<String, dynamic>>(
        '/Users/$userId/Items/$seriesId',
        query: {'Fields': _itemFields},
      );
      series = seriesResult.dataOrNull;
    }

    return Success(MediaResponseParser.parseOptionalPlayInfoResponse(
      _envelope(EmbyMapper.toPlayInfo(
        item,
        _baseUrl,
        source: source,
        series: series,
      )),
    ));
  }

  /// `PlaybackInfo` is the authoritative source for stream lists, but it does
  /// not return `Path`/`Size`. Fetch the item's `MediaSources` when the plain
  /// detail payload lacks them.
  Future<Map<String, dynamic>> _fetchPlaybackSource(
    String itemId, {
    bool autoOpenLiveStream = false,
    String? mediaSourceId,
  }) async {
    final result = await _api.post<Map<String, dynamic>>(
      '/Items/$itemId/PlaybackInfo',
      query: {'UserId': userId},
      body: {
        'UserId': userId,
        'StartTimeTicks': 0,
        'AutoOpenLiveStream': autoOpenLiveStream,
        'IsPlayback': true,
        'MaxStreamingBitrate': 120000000,
        if (mediaSourceId != null && mediaSourceId.isNotEmpty)
          'MediaSourceId': mediaSourceId,
      },
    );
    final payload = result.dataOrNull;
    if (payload == null) return const <String, dynamic>{};
    final sources = (payload['MediaSources'] as List?) ?? const [];
    if (sources.isEmpty) return const <String, dynamic>{};
    return Map<String, dynamic>.from(sources.first as Map);
  }

  @override
  Future<ApiResult<StreamResponse>> getStreamInfo(StreamRequest request) async {
    final id = EmbyMapper.rawId(request.mediaGuid);
    final detail = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$id',
      query: {'Fields': _itemFields},
    );
    if (!detail.isSuccess) {
      return ResultFailure(detail.failureOrNull!);
    }
    final item = detail.dataOrNull!;
    final sources = (item['MediaSources'] as List?) ?? const [];
    var source = sources.isEmpty
        ? await _fetchPlaybackSource(id)
        : Map<String, dynamic>.from(sources.first as Map);
    // strm / lazily-opened sources (CloudDrive2, 115, …) carry no MediaStreams
    // in the plain detail payload: Emby resolves them only when a playback
    // session actually opens. Without stream metadata the player cannot build
    // its video_stream and aborts with "Missing video_stream or file_stream"
    // — even though /Videos/{id}/stream serves the resolved file perfectly
    // (verified: ranged GET returns 206 with real media bytes). Probe
    // PlaybackInfo with live-stream opening; if the server still returns no
    // streams, synthesise a minimal video stream so the session can proceed
    // to the direct stream URL, which Emby serves by direct play.
    if ((source['MediaStreams'] as List?)?.whereType<Map>().any(
            (s) => s['Type'] == 'Video') !=
        true) {
      final opened = await _fetchPlaybackSource(
        id,
        autoOpenLiveStream: true,
        mediaSourceId: source['Id']?.toString(),
      );
      if (opened.isNotEmpty &&
          (opened['MediaStreams'] as List?)?.whereType<Map>().any(
                (s) => s['Type'] == 'Video',
              ) ==
          true) {
        source = opened;
      }
      if ((source['MediaStreams'] as List?)?.whereType<Map>().any(
            (s) => s['Type'] == 'Video',
          ) !=
          true) {
        source = _syntheticSource(item, source);
      }
    }
    if (source.isEmpty) {
      return ResultFailure(
        FailureInfo.fromMessage('No playable media source on this item'),
      );
    }
    // Cache video stream metadata so playVideo can tell a real h264 source
    // from one that merely received the default encoder.
    final sourceId = source['Id']?.toString() ?? '';
    if (sourceId.isNotEmpty) {
      _lastMediaSource = (id, sourceId);
    }
    // A new getStreamInfo marks the start of a playback session, so the
    // PlaySessionId is renewed here rather than on every playVideo call.
    _playSessionId = 'flynarwhal${DateTime.now().microsecondsSinceEpoch}';
    _playSessionItemId = id;
    _lastStreamVideoMeta
      ..clear()
      ..addEntries(
        (source['MediaStreams'] as List? ?? const [])
            .whereType<Map>()
            .where((s) => s['Type'] == 'Video')
            .map((s) {
          // One shared reader for every server dialect: Emby 4.9 only sends
          // VideoRange/ExtendedVideoSubType, Jellyfin sends VideoRangeType.
          final range = EmbyMapper.videoRangeOf(s.cast<String, dynamic>());
          return MapEntry(
            'v${s['Index'] ?? 0}',
            (s['Codec']?.toString() ?? '', range?.dvProfile ?? 0),
          );
        }),
      );
    return Success(MediaResponseParser.parseStreamResponse(
      _envelope(EmbyMapper.toStreamResponse(item, _baseUrl, source: source)),
    ));
  }

  /// Minimal MediaSource when Emby never materialises stream metadata for a
  /// lazily opened (strm / cloud) item. RunTimeTicks from the item keeps the
  /// progress bar sane; the codec stays unknown on purpose (mpv probes it).
  static Map<String, dynamic> _syntheticSource(
    Map<String, dynamic> item,
    Map<String, dynamic> original,
  ) {
    return <String, dynamic>{
      ...original,
      'Id': original['Id']?.toString() ?? item['Id']?.toString(),
      'MediaStreams': <Map<String, dynamic>>[
        <String, dynamic>{
          'Type': 'Video',
          'Index': 0,
          'Codec': original['Container']?.toString() ?? '',
          'DisplayTitle': item['Name']?.toString() ?? '',
        },
      ],
      'RunTimeTicks':
          original['RunTimeTicks'] ?? item['RunTimeTicks'],
      'Bitrate': original['Bitrate'],
    }..removeWhere((key, value) => value == null);
  }

  /// The fnOS play/play negotiation starts a server transcode session. On
  /// Emby the equivalent is the HLS master URL:
  /// `/Videos/{id}/master.m3u8?VideoCodec=…`.
  ///
  /// This method must *always* return an HLS link, because it is also the
  /// fallback the player reaches for after a direct link failed to produce a
  /// frame ([PlayerSessionCoordinator.requestHlsPlayLink]) and the path a
  /// quality switch takes. Returning the `static=true` stream URL here turns
  /// that fallback into a no-op: the player reopens the very URL that just
  /// failed and the user sees a load error instead of a working transcode.
  ///
  /// Direct play is decided one level up, in
  /// `PlayerSessionCoordinator.supportsDirectLink`, which calls
  /// [buildDirectStreamUrl] and never this method.
  @override
  Future<ApiResult<PlayPlayResponse>> playVideo(PlayPlayRequest request) async {
    final id = _itemIdFor(request.mediaGuid);
    final source = _lastStreamVideoMeta[request.videoGuid];
    final sourceCodec = (source?.$1 ?? '').toLowerCase();
    final requestedEncoder = request.videoEncoder.toLowerCase();
    // Keep the encoder the client asked for unless it would be a pointless
    // re-encode of an already-matching source.
    final videoCodec = requestedEncoder == 'h264' || sourceCodec == 'h264'
        ? 'h264'
        : 'hevc';
    final url = _api.transcodeUrl(
      id,
      playSessionId: _playSessionFor(id),
      mediaSourceId: _mediaSourceIdFor(id),
      videoCodec: videoCodec,
      videoBitrate: request.bitrate > 0 ? request.bitrate : null,
      startTicks: request.startTimestamp > 0
          ? request.startTimestamp * EmbyMapper.ticksPerSecond
          : null,
    );
    return Success(MediaResponseParser.parsePlayPlayResponse(
      _envelope(<String, dynamic>{'play_link': url}),
    ));
  }

  /// Codec and Dolby Vision profile of the video streams returned by the most
  /// recent getStreamInfo call, keyed by `v<index>`. Populated by
  /// getStreamInfo so playVideo can pick the transcode encoder without
  /// re-fetching the item.
  final Map<String, (String, int)> _lastStreamVideoMeta = {};

  /// Stable `PlaySessionId` for the item currently being transcoded.
  ///
  /// Emby writes this value into every segment URI of the playlist it returns,
  /// and the player then requests those segments itself, so it has to survive
  /// quality switches and seeks within one playback. [getStreamInfo] renews it
  /// when a playback session starts.
  String? _playSessionId;
  String? _playSessionItemId;

  String _playSessionFor(String itemId) {
    final cached = _playSessionId;
    if (cached != null && _playSessionItemId == itemId) {
      return cached;
    }
    final generated = 'flynarwhal${DateTime.now().microsecondsSinceEpoch}';
    _playSessionId = generated;
    _playSessionItemId = itemId;
    return generated;
  }

  /// `(itemId, MediaSources[].Id)` captured by the most recent getStreamInfo.
  ///
  /// This id is what `/Videos/{id}/stream` and `/Videos/{id}/master.m3u8` expect
  /// in `MediaSourceId`. Emby reports it as `mediasource_<itemId>`, so passing
  /// the item id makes Emby resolve no media source and reject the request.
  (String, String)? _lastMediaSource;

  @override
  Future<ApiResult<MediaTranscodeResponse>> fetchTranscodeStatus(
    MediaPRequest request,
  ) async {
    // Emby transcoding is decided per request; there is no session to poll.
    return Success(MediaResponseParser.parseMediaTranscodeResponse(_envelope({
      'bitrate': 0,
      'reqid': request.reqId ?? '',
      'resolution': '',
      'result': 'succ',
      'transcoded': false,
      'transcoding_reason': <int>[],
      'video': {
        'decode_method': 0,
        'dropped_frames': 0,
        'dynamic_range': '',
        'encode_method': 0,
        'encoder': '',
        'selected_gpu': '',
        'transcoding_rate': '',
      },
    })));
  }

  @override
  Future<ApiResult<MediaResetQualityResponse>> resetQuality(
    MediaPRequest request,
  ) =>
      _noopMediaP(request, 'media.resetQuality');

  @override
  Future<ApiResult<MediaResetQualityResponse>> resetAudio(
    MediaPRequest request,
  ) =>
      _noopMediaP(request, 'media.resetAudio');

  @override
  Future<ApiResult<MediaResetQualityResponse>> resetSubtitle(
    MediaPRequest request,
  ) =>
      _noopMediaP(request, 'media.resetSubtitle');

  @override
  Future<ApiResult<MediaResetQualityResponse>> quit(MediaPRequest request) =>
      _noopMediaP(request, 'media.quit');

  Future<ApiResult<MediaResetQualityResponse>> _noopMediaP(
    MediaPRequest request,
    String action,
  ) async {
    AppTalker.info('Emby', '$action is a no-op: no server-side session');
    return Success(MediaResponseParser.parseMediaResetQualityResponse(
      _envelope(<String, dynamic>{
        'hlsTime': 0,
        'reqid': request.reqId ?? '',
        'result': 'succ',
        'updateM3u8': false,
        'errno': 0,
      }),
    ));
  }

  // ----------------------------------------------------------------- subtitles

  @override
  Future<ApiResult<String>> downloadExternalSubtitle(String guid) async {
    // The mapper hands out `s<index>@<itemId>`, so the owning item is known
    // without another round trip; the stream list on that item names the
    // delivery URL for the index.
    final index = _subtitleIndexFromGuid(guid);
    final itemId = _subtitleItemId(guid);
    if (itemId.isEmpty) {
      return ResultFailure(
        FailureInfo.fromMessage('Subtitle guid carries no item id: $guid'),
      );
    }
    final detail = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$itemId',
      query: {'Fields': _itemFields},
    );
    final item = detail.dataOrNull;
    if (item == null) {
      return ResultFailure(FailureInfo.fromMessage('Subtitle item not found'));
    }
    final sources = (item['MediaSources'] as List?) ?? const [];
    final medias = <Map>[
      ...sources.whereType<Map>(),
      if (item['MediaStreams'] is List) item,
    ];
    Map? subtitle;
    Map? source;
    for (final media in medias) {
      final streams = (media['MediaStreams'] as List?) ?? const [];
      for (final raw in streams.whereType<Map>()) {
        if (raw['Type'] == 'Subtitle' && raw['Index'] == index) {
          subtitle = raw;
          source = media;
          break;
        }
      }
      if (subtitle != null) break;
    }
    if (subtitle == null) {
      return ResultFailure(
        FailureInfo.fromMessage('Subtitle stream $index not found'),
      );
    }
    final deliveryUrl = subtitle['DeliveryUrl']?.toString() ?? '';
    final path = deliveryUrl.isNotEmpty
        ? deliveryUrl
        : '/Videos/$itemId/${source?['Id'] ?? itemId}/Subtitles/$index/0/Stream.$_subtitleExtension(subtitle)';
    final response = await _api.getText(
      path.startsWith('/') ? path : '/$path',
    );
    return response;
  }

  /// Subtitle guids are `s<index>@<itemId>`; the index addresses the stream
  /// inside the item, the tail names the item that owns it.
  static int _subtitleIndexFromGuid(String guid) {
    final match = RegExp(r'^s(\d+)').firstMatch(guid);
    return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
  }

  static String _subtitleItemId(String guid) {
    final parts = guid.split('@');
    return parts.length > 1 ? EmbyMapper.rawId(parts[1]) : '';
  }

  static String _subtitleExtension(Map subtitle) {
    final codec = (subtitle['Codec']?.toString() ?? '').toLowerCase();
    switch (codec) {
      case 'subrip':
      case 'srt':
        return 'srt';
      case 'ass':
      case 'ssa':
        return 'ass';
      case 'webvtt':
      case 'vtt':
        return 'vtt';
      default:
        return 'srt';
    }
  }

  // -------------------------------------------------------------------- search

  @override
  Future<ApiResult<List<MediaItem>>> search(String query) async {
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items',
      query: {
        'SearchTerm': query,
        'Recursive': true,
        'IncludeItemTypes': _videoTypes,
        'Fields': _itemFields,
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary',
        'Limit': 40,
      },
    );
    return result.map((payload) {
      final items = (payload['Items'] as List?) ?? const [];
      return MediaResponseParser.parseSearchResponse(_envelope(
        items.whereType<Map>().map((raw) {
          final item = Map<String, dynamic>.from(raw);
          final mapped = EmbyMapper.toMediaItem(item, _baseUrl);
          mapped['guid'] = EmbyMapper.guidOf(item);
          return mapped;
        }).toList(),
      ));
    });
  }

  // -------------------------------------------------------------------- people

  @override
  Future<ApiResult<PersonResponse>> getPerson(String guid) async {
    final key = 'person:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<PersonResponse>) return cached;

    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/${EmbyMapper.rawId(guid)}',
    );
    final mapped = result.map((payload) {
      return MediaResponseParser.parsePersonResponse(
        _envelope(EmbyMapper.toPersonResponse(payload, _baseUrl)),
      );
    });
    if (mapped.isSuccess) _cache.set(key, mapped);
    return mapped;
  }

  @override
  Future<ApiResult<List<PersonItemList>>> getPersonItemList(
    PersonItemListRequest request,
  ) async {
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items',
      query: {
        'PersonIds': EmbyMapper.rawId(request.personGuid),
        'Recursive': true,
        'IncludeItemTypes': 'Movie,Series',
        'Fields': _itemFields,
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary',
        'SortBy': 'PremiereDate',
        'SortOrder': 'Descending',
        'StartIndex': (request.page - 1) * request.pageSize,
        'Limit': request.pageSize,
      },
    );
    return result.map((payload) {
      return MediaResponseParser.parsePersonItemListResponse(
        _envelope(EmbyMapper.toPersonItemList(payload, _baseUrl, const [])),
      );
    });
  }

  @override
  Future<ApiResult<List<PersonList>>> getPersonList(String guid) async {
    final key = 'personList:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<List<PersonList>>) return cached;

    final id = EmbyMapper.rawId(guid);
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$id',
      query: {'Fields': 'People'},
    );
    if (!result.isSuccess) {
      return ResultFailure(result.failureOrNull!);
    }
    final item = result.dataOrNull!;
    if (((item['People'] as List?) ?? const []).isNotEmpty) {
      final mapped = _mapPeople(item);
      _cache.set(key, mapped);
      return mapped;
    }
    // Seasons carry no cast of their own: Emby keeps `People` on the series
    // only, so the season page's cast row stayed empty. Borrow the series cast
    // rather than dropping the row from a page that has one on fnOS.
    final parents = <Object?>[
      item['SeriesId'],
      item['ParentId'],
    ].map((e) => e?.toString()).whereType<String>().where((e) => e.isNotEmpty);
    for (final parentId in parents) {
      final parent = await _api.get<Map<String, dynamic>>(
        '/Users/$userId/Items/$parentId',
        query: {'Fields': 'People'},
      );
      final parentItem = parent.dataOrNull;
      if (parentItem == null) continue;
      if (((parentItem['People'] as List?) ?? const []).isEmpty) continue;
      final mapped = _mapPeople(parentItem);
      _cache.set(key, mapped);
      return mapped;
    }
    final empty = _mapPeople(item);
    _cache.set(key, empty);
    return empty;
  }

  ApiResult<List<PersonList>> _mapPeople(Map<String, dynamic> item) {
    return Success(
      MediaResponseParser.parsePersonListResponse(_envelope({
        'list': EmbyMapper.toPersonList(item, _baseUrl),
        'total': ((item['People'] as List?) ?? const []).length,
      })),
    );
  }

  // -------------------------------------------------------------- season/episode

  @override
  Future<ApiResult<List<SeasonListResponse>>> getSeasonList(String guid) async {
    final key = 'seasonList:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<List<SeasonListResponse>>) return cached;

    final seriesId = EmbyMapper.rawId(guid);
    final seriesResult = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$seriesId',
      query: {'Fields': _itemFields},
    );
    if (!seriesResult.isSuccess) {
      return ResultFailure(seriesResult.failureOrNull!);
    }
    final series = seriesResult.dataOrNull!;
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items',
      query: {
        'ParentId': seriesId,
        'IncludeItemTypes': 'Season',
        'Recursive': false,
        'Fields': _itemFields,
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
      },
    );
    final mapped = result.map((payload) {
      final seasons = (payload['Items'] as List?) ?? const [];
      return MediaResponseParser.parseSeasonListResponse(_envelope(
        EmbyMapper.toSeasonList(seasons, _baseUrl, series: series),
      ));
    });
    if (mapped.isSuccess) _cache.set(key, mapped);
    return mapped;
  }

  @override
  Future<ApiResult<List<EpisodeListResponse>>> getEpisodeList(String guid) async {
    final key = 'episodeList:$guid';
    final cached = _cache.get(key);
    if (cached is ApiResult<List<EpisodeListResponse>>) return cached;

    final parentId = EmbyMapper.rawId(guid);
    final seasonResult = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items/$parentId',
      query: {'Fields': _itemFields},
    );
    if (!seasonResult.isSuccess) {
      return ResultFailure(seasonResult.failureOrNull!);
    }
    final season = seasonResult.dataOrNull!;
    // Episode stills and season folders are often unscraped on a real server
    // while the series has artwork, so the mapper needs the series item to fall
    // back to. The season already names its parent, avoiding a second lookup.
    Map<String, dynamic>? series;
    final seriesId = season['SeriesId']?.toString();
    if (seriesId != null && seriesId.isNotEmpty) {
      final seriesResult = await _api.get<Map<String, dynamic>>(
        '/Users/$userId/Items/$seriesId',
        query: {'Fields': _itemFields},
      );
      series = seriesResult.dataOrNull;
    }
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$userId/Items',
      query: {
        'ParentId': parentId,
        'IncludeItemTypes': 'Episode',
        'Recursive': false,
        'Fields': _itemFields,
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary',
        'SortBy': 'ParentIndexNumber,IndexNumber',
        'SortOrder': 'Ascending',
      },
    );
    final mapped = result.map((payload) {
      final episodes = (payload['Items'] as List?) ?? const [];
      return MediaResponseParser.parseEpisodeListResponse(_envelope(
        EmbyMapper.toEpisodeList(episodes, _baseUrl, season: season, series: series),
      ));
    });
    if (mapped.isSuccess) _cache.set(key, mapped);
    return mapped;
  }

  // ------------------------------------------------------------- playback state

  @override
  Future<ApiResult<bool>> updatePlayRecord(PlayRecordRequest request) async {
    final id = EmbyMapper.rawId(request.itemGuid);
    final result = await _api.post<dynamic>(
      '/Sessions/Playing/Progress',
      body: {
        'ItemId': id,
        // `/Sessions/Playing*` takes the media source id here, and Emby
        // rejects progress reports whose MediaSourceId matches no source.
        'MediaSourceId': _mediaSourceIdFor(id),
        'PositionTicks': request.ts * EmbyMapper.ticksPerSecond,
        'IsPaused': false,
        'CanSeek': true,
        'PlayMethod': 'DirectStream',
        'PlaySessionId': request.deviceId,
      },
    );
    return result.map((_) => true);
  }

  @override
  Future<ApiResult<bool>> deletePlayRecord(String guid) async {
    final id = EmbyMapper.rawId(guid);
    final result = await _api.post<dynamic>(
      '/Users/$userId/PlayedItems/$id/Delete',
    );
    return result.map((_) => true);
  }

  @override
  Future<ApiResult<bool>> updateLivePlayRecord(
    LivePlayRecordRequest request,
  ) async {
    // No IPTV libraries in the Emby backend; accept the call so shared player
    // code paths do not special-case the server family.
    return Success(true);
  }

  @override
  Future<ApiResult<bool>> setSkipConfig(SetConfigByItemRequest request) async {
    // Intro/outro skipping needs server-side analysis; unsupported.
    return Success(true);
  }

  // ------------------------------------------------------------- library state

  @override
  Future<ApiResult<bool>> addFavorite(String guid) => _setFavorite(guid, true);

  @override
  Future<ApiResult<bool>> removeFavorite(String guid) =>
      _setFavorite(guid, false);

  @override
  Future<ApiResult<bool>> markWatched(String guid) => _setWatched(guid, true);

  @override
  Future<ApiResult<bool>> markUnwatched(String guid) =>
      _setWatched(guid, false);

  @override
  Future<ApiResult<bool>> toggleFavorite(
    ItemGuidRequest request, {
    required bool isFavorite,
  }) =>
      // `isFavorite` is the *current* state: toggling flips it.
      _setFavorite(request.itemGuid, !isFavorite);

  @override
  Future<ApiResult<bool>> toggleWatched(
    ItemGuidRequest request, {
    required bool isWatched,
  }) =>
      _setWatched(request.itemGuid, !isWatched);

  Future<ApiResult<bool>> _setFavorite(String guid, bool favorite) async {
    final id = EmbyMapper.rawId(guid);
    final result = favorite
        ? await _api.post<dynamic>('/Users/$userId/FavoriteItems/$id')
        : await _api.delete<dynamic>('/Users/$userId/FavoriteItems/$id');
    if (result.isSuccess) _cache.invalidate(guid);
    return result.map((_) => true);
  }

  Future<ApiResult<bool>> _setWatched(String guid, bool watched) async {
    final id = EmbyMapper.rawId(guid);
    final result = watched
        ? await _api.post<dynamic>('/Users/$userId/PlayedItems/$id')
        : await _api.delete<dynamic>('/Users/$userId/PlayedItems/$id');
    if (result.isSuccess) _cache.invalidate(guid);
    return result.map((_) => true);
  }

  @override
  Future<void> prefetchItemDetail(String guid) async {
    try {
      await getItemDetail(guid);
    } catch (_) {
      // Prefetch is best-effort.
    }
  }

  @override
  void invalidateDetailCache(String guid) => _cache.invalidate(guid);

  @override
  Future<ApiResult<bool>> refreshItemMetadata(String itemGuid) async {
    final result = await _api.post<dynamic>(
      '/Items/${EmbyMapper.rawId(itemGuid)}/Refresh',
      query: {
        'MetadataRefreshMode': 'FullRefresh',
        'ImageRefreshMode': 'FullRefresh',
        'ReplaceAllImages': false,
      },
    );
    if (result.isSuccess) _cache.invalidate(itemGuid);
    return result.map((_) => true);
  }

  @override
  Future<ApiResult<bool>> rescrapItem(String itemGuid, String type) =>
      refreshItemMetadata(itemGuid);

  @override
  Future<ApiResult<bool>> deleteItem(
    String guid, {
    required bool deleteFile,
  }) async {
    final result = await _api.delete<dynamic>(
      '/Items/${EmbyMapper.rawId(guid)}',
    );
    if (result.isSuccess) _cache.invalidate(guid);
    return result.map((_) => true);
  }

  /// Reads the authenticated user. Emby has no `user/info` endpoint, and its
  /// `/Users/{id}` route parses the id as a Guid, so `/Users/Me` — a Jellyfin
  /// convenience route — 500s with "Unrecognized Guid format." there. The
  /// stored user id from authentication is a real Guid on both servers, so
  /// resolve the profile through it.
  @override
  Future<ApiResult<UserInfo>> getCurrentUser() async {
    final id = _api.credentials.userId;
    final result = await _api.get<Map<String, dynamic>>(
      id.isEmpty ? '/Users/Me' : '/Users/$id',
    );
    return result.map((payload) {
      final policy = payload['Policy'];
      final isAdmin = policy is Map &&
          (policy['IsAdministrator'] == true ||
              policy['IsAdministrator']?.toString() == 'true');
      return UserInfo(
        guid: payload['Id']?.toString() ?? _api.credentials.userId,
        username: payload['Name']?.toString() ?? '',
        isAdmin: isAdmin ? 1 : 0,
      );
    });
  }

  /// Builds the fnOS success envelope the shared parsers expect.
  static Map<String, dynamic> _envelope(Object? data) => <String, dynamic>{
        'code': 0,
        'msg': '',
        'data': data,
      };

  /// Factory that authenticates and returns a ready backend.
  static Future<ApiResult<EmbyMediaBackend>> connect({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceId,
    SslTrustManager? sslTrustManager,
    Future<void> Function(SslTrustEntry entry)? persistSslTrustEntry,
  }) async {
    final auth = await EmbyApi.authenticate(
      baseUrl: baseUrl,
      username: username,
      password: password,
      deviceId: deviceId,
    );
    final result = auth.dataOrNull;
    if (result == null) {
      return ResultFailure(auth.failureOrNull ??
          FailureInfo.fromMessage('Emby login failed'));
    }
    final credentials = EmbyCredentials(
      baseUrl: baseUrl,
      accessToken: result.accessToken,
      userId: result.userId,
      deviceId: deviceId,
    );
    return Success(EmbyMediaBackend(
      api: EmbyApi(
        credentials: credentials,
        sslTrustManager: sslTrustManager,
        persistSslTrustEntry: persistSslTrustEntry,
      ),
      initialBaseUrl: baseUrl,
      serverInfo: {
        'product_name': result.productName,
        'server_name': result.serverName,
        'server_version': result.serverVersion,
        'server_id': result.serverId,
        'user_name': result.userName,
      },
    ));
  }
}

/// Minimal LRU with TTL, mirroring the fnOS data source cache so both backends
/// expire detail entries on the same schedule.
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
