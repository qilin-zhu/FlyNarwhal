import 'emby_tags.dart';
import 'emby_urls.dart';

/// Translates Emby / Jellyfin DTOs into the fnOS result models.
///
/// The rest of the app is written against the fnOS shape (snake_case JSON with
/// `MediaType` string tags), so this mapper emits exactly that shape instead of
/// teaching every view model about a second server. Two conventions matter:
///
///  * Folders are prefixed `fv_` because folder drill-down is detected from
///    that prefix in the library and folder screens.
///  * Image fields carry absolute URLs; the poster widget passes absolute URLs
///    through untouched.
class EmbyMapper {
  const EmbyMapper._();

  static const String folderPrefix = 'fv_';

  /// Emby ticks are 100-nanosecond units.
  static const int ticksPerSecond = EmbyUrls.ticksPerSecond;

  static int secondsFromTicks(Object? ticks) =>
      EmbyUrls.secondsFromTicks(ticks);

  /// Strips the local folder prefix so the raw Emby id can be used in a path.
  static String rawId(String guid) {
    if (guid.startsWith(folderPrefix)) {
      return guid.substring(folderPrefix.length);
    }
    return guid;
  }

  /// Emby `CollectionType` → fnOS library category (`Movie`/`TV`/`Mix`/…).
  static String categoryOf(Map<String, dynamic> view) {
    switch (view['CollectionType']?.toString()) {
      case 'movies':
        return 'Movie';
      case 'tvshows':
        return 'TV';
      case 'mixed':
        return 'Mix';
      case 'music':
      case 'musicvideos':
      case 'books':
      case 'photos':
        return 'Others';
      default:
        return 'Mix';
    }
  }

  /// Emby `Type` → fnOS `MediaType` string.
  static String typeOf(Map<String, dynamic> item) {
    switch (item['Type']?.toString()) {
      case 'Movie':
        return 'Movie';
      case 'Series':
        return 'TV';
      case 'Season':
        return 'Season';
      case 'Episode':
        return 'Episode';
      case 'BoxSet':
        return 'Directory';
      case 'Folder':
      case 'CollectionFolder':
      case 'PhotoAlbum':
        return 'Directory';
      case 'MusicVideo':
      case 'Video':
        return 'Video';
      default:
        return 'Video';
    }
  }

  /// Emby guids for folders get the local `fv_` prefix; everything else keeps
  /// the bare id so route parameters stay readable.
  static String guidOf(Map<String, dynamic> item) {
    final id = item['Id']?.toString() ?? '';
    final type = typeOf(item);
    if (type == 'Directory') return '$folderPrefix$id';
    return id;
  }

  static Map<String, dynamic> _userData(Map<String, dynamic> item) {
    final raw = item['UserData'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  static bool _isPlayed(Map<String, dynamic> userData) {
    return userData['Played'] == true;
  }

  static bool _isFavorite(Map<String, dynamic> userData) {
    return userData['IsFavorite'] == true;
  }

  static String? _imageUrl(
    String baseUrl,
    Map<String, dynamic> item, {
    String kind = 'Primary',
    int? maxWidth,
  }) {
    final id = item['Id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final imageTags = item['ImageTags'];
    final ownTag =
        imageTags is Map ? imageTags[kind]?.toString() : null;
    if (ownTag != null) {
      return EmbyUrls.image(baseUrl, id,
          kind: kind, maxWidth: maxWidth, tag: ownTag);
    }
    // Backdrops live in a separate array (`BackdropImageTags`) instead of
    // `ImageTags`, so they need their own lookup before giving up.
    if (kind == 'Backdrop') {
      final backdrops = item['BackdropImageTags'];
      if (backdrops is! List || backdrops.isEmpty) return null;
      return EmbyUrls.image(baseUrl, id,
          kind: 'Backdrop', maxWidth: maxWidth, tag: backdrops.first.toString());
    }
    return null;
  }

  static String? _primaryImage(String baseUrl, Map<String, dynamic> item,
      {int maxWidth = 400}) {
    return _imageUrl(baseUrl, item, kind: 'Primary', maxWidth: maxWidth);
  }

  /// Genre ids for the shared tag/name lookup the detail pages use.
  ///
  /// Emby reports genre *names* on the item; the fnOS contract carries ids that
  /// the UI resolves through `tag/genres`. Registering the names in
  /// [EmbyGenreIndex] keeps both sides pointing at the same id.
  static List<int> _genreIds(Map<String, dynamic> item) {
    final names = (item['Genres'] as List?) ?? const [];
    return EmbyGenreIndex.idsFor(
      names.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty),
    );
  }

  /// Clearart/logo treatment: Emby stores it as an extra `Primary`-style image
  /// under `ImageTags.Logo`, the same slot fnOS exposes as `logos`.
  static String? _logoImage(String baseUrl, Map<String, dynamic> item) {
    final imageTags = item['ImageTags'];
    final tag = imageTags is Map ? imageTags['Logo']?.toString() : null;
    if (tag == null || tag.isEmpty) return null;
    return EmbyUrls.image(baseUrl, item['Id']?.toString() ?? '',
        kind: 'Logo', maxWidth: 800, tag: tag);
  }

  static String? _releaseDate(Map<String, dynamic> item) {
    final premiere = item['PremiereDate']?.toString();
    if (premiere != null && premiere.isNotEmpty) {
      final year = item['ProductionYear'];
      if (premiere.length >= 10) return premiere.substring(0, 10);
      if (year != null) return '$year-01-01';
      return null;
    }
    final year = item['ProductionYear'];
    return year == null ? null : '$year-01-01';
  }

  /// Media libraries (`Users/{id}/Views`).
  static List<Map<String, dynamic>> toMediaDbList(
    List<dynamic> views,
    String baseUrl,
  ) {
    return views.whereType<Map>().map((raw) {
      final view = Map<String, dynamic>.from(raw);
      final poster = _primaryImage(baseUrl, view, maxWidth: 400);
      return <String, dynamic>{
        'guid': view['Id']?.toString() ?? '',
        'title': view['Name']?.toString() ?? '',
        'posters': poster == null ? <String>[] : <String>[poster],
        'category': categoryOf(view),
        'view_type': 0,
      };
    }).toList();
  }

  /// One list row (`MediaItem`).
  static Map<String, dynamic> toMediaItem(
    Map<String, dynamic> item,
    String baseUrl, {
    String? ancestorGuid,
    String? ancestorName,
    String? ancestorCategory,
  }) {
    final userData = _userData(item);
    final type = typeOf(item);
    final poster = _primaryImage(baseUrl, item);
    final runtimeSeconds = secondsFromTicks(item['RunTimeTicks']);
    final childCount = item['ChildCount'] ?? item['RecursiveItemCount'];
    final episodeNumber = item['IndexNumber'] ?? 0;
    final seasonNumber =
        type == 'Episode' ? (item['ParentIndexNumber'] ?? 0) : 0;
    final seriesName = item['SeriesName']?.toString();

    return <String, dynamic>{
      'guid': guidOf(item),
      'title': item['Name']?.toString() ?? '',
      'type': type,
      'poster': poster,
      'poster_list': poster == null ? <String>[] : <String>[poster],
      'poster_width': 400,
      'poster_height': 600,
      'is_favorite': _isFavorite(userData) ? 1 : 0,
      'watched': _isPlayed(userData) ? 1 : 0,
      'vote_average':
          item['CommunityRating'] == null ? '' : '${item['CommunityRating']}',
      'release_date': _releaseDate(item),
      'season_number': seasonNumber,
      'episode_number': type == 'Episode' ? episodeNumber : 0,
      'first_air_date': _releaseDate(item),
      'status': item['Status']?.toString(),
      'overview': item['Overview']?.toString(),
      if (ancestorGuid != null) 'ancestor_guid': ancestorGuid,
      if (ancestorName != null) 'ancestor_name': ancestorName,
      if (ancestorCategory != null) 'ancestor_category': ancestorCategory,
      'duration': runtimeSeconds,
      if (type == 'TV' && seriesName == null) 'number_of_item': childCount,
      'tv_title': seriesName,
    }..removeWhere((key, value) => value == null);
  }

  /// `item/list` response.
  static Map<String, dynamic> toItemListQuery(
    Map<String, dynamic> payload,
    String baseUrl, {
    String? ancestorGuid,
    String? ancestorName,
    String? ancestorCategory,
    String? mdbName,
    List<Map<String, dynamic>>? jumpList,
  }) {
    final items = (payload['Items'] as List?) ?? const [];
    return <String, dynamic>{
      'list': items.whereType<Map>().map((raw) {
        return toMediaItem(
          Map<String, dynamic>.from(raw),
          baseUrl,
          ancestorGuid: ancestorGuid,
          ancestorName: ancestorName,
          ancestorCategory: ancestorCategory,
        );
      }).toList(),
      'total': payload['TotalRecordCount'] ?? items.length,
      'mdb_name': mdbName ?? ancestorName,
      'jump_list': jumpList ?? <Map<String, dynamic>>[],
    };
  }

  /// Breadcrumb + library name for a folder drill-down.
  ///
  /// Emby returns ancestors nearest-first, one entry per containing folder plus
  /// a synthetic user-root row. fnOS expects the opposite reading order, with
  /// the library first (empty `fv_guid`, so the header click falls back to the
  /// library route) and the current folder last (the header title).
  static Map<String, dynamic> folderTrail(
    List<dynamic> ancestors, {
    required String folderId,
    required String folderName,
  }) {
    final chain = ancestors.whereType<Map>().toList();
    final libraryIndex =
        chain.indexWhere((entry) => entry['Type'] == 'CollectionFolder');
    final library = libraryIndex >= 0 ? chain[libraryIndex] : null;
    final libraryName =
        library?['Name']?.toString().isNotEmpty == true
            ? library!['Name'].toString()
            : folderName;

    final intermediates = libraryIndex > 0
        ? chain.sublist(0, libraryIndex).reversed
            .where((entry) => entry['Name']?.toString().isNotEmpty == true)
            .map((entry) => <String, dynamic>{
                  'fv_guid': '$folderPrefix${entry['Id']}',
                  'base_name': entry['Name'].toString(),
                })
            .toList()
        : <Map<String, dynamic>>[];

    return <String, dynamic>{
      'library_guid': library?['Id']?.toString() ?? '',
      'mdb_name': libraryName,
      'jump_list': <Map<String, dynamic>>[
        <String, dynamic>{'fv_guid': '', 'base_name': libraryName},
        ...intermediates,
        <String, dynamic>{
          'fv_guid': '$folderPrefix$folderId',
          'base_name': folderName,
        },
      ],
    };
  }

  /// Full detail payload (`ItemResponse`).
  static Map<String, dynamic> toItemResponse(
    Map<String, dynamic> item,
    String baseUrl, {
    String? ancestorGuid,
    String? ancestorName,
    String? ancestorCategory,
  }) {
    final userData = _userData(item);
    final type = typeOf(item);
    final poster = _primaryImage(baseUrl, item, maxWidth: 600);
    final backdrop = _imageUrl(baseUrl, item, kind: 'Backdrop', maxWidth: 1920);
    final providerIds = item['ProviderIds'] as Map?;
    final studios = (item['Studios'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];

    return <String, dynamic>{
      'guid': guidOf(item),
      'imdb_id': providerIds?['Imdb']?.toString(),
      'trim_id': item['Id']?.toString() ?? '',
      'tv_title': item['SeriesName']?.toString() ?? item['Name']?.toString() ?? '',
      'parent_title': item['SeasonName']?.toString() ?? '',
      'title': item['Name']?.toString() ?? '',
      'original_title': item['OriginalTitle']?.toString(),
      'backdrops': backdrop,
      'posters': poster ?? '',
      'logos': _logoImage(baseUrl, item),
      'genres': _genreIds(item),
      'poster_width': 600,
      'poster_height': 900,
      'vote_average':
          item['CommunityRating'] == null ? '' : '${item['CommunityRating']}',
      'content_ratings': item['OfficialRating']?.toString(),
      'release_date': _releaseDate(item),
      'production_countries': (item['ProductionLocations'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      'overview': item['Overview']?.toString(),
      'is_favorite': _isFavorite(userData) ? 1 : 0,
      'is_watched': _isPlayed(userData) ? 1 : 0,
      'watched_ts': secondsFromTicks(item['RunTimeTicks']),
      'season_number': item['ParentIndexNumber'] ?? 0,
      'number_of_seasons': item['ChildCount'] ?? 1,
      'number_of_episodes': item['RecursiveItemCount'] ?? item['ChildCount'] ?? 0,
      'local_number_of_episodes':
          item['RecursiveItemCount'] ?? item['ChildCount'] ?? 0,
      'local_number_of_seasons': item['ChildCount'] ?? 1,
      'can_play': 1,
      'type': type,
      'play_error': '',
      'parent_guid': item['SeriesId']?.toString() ??
          item['SeasonId']?.toString() ??
          item['ParentId']?.toString() ??
          '',
      'ancestor_name': ancestorName ??
          (studios.isEmpty ? '' : studios.first['Name']?.toString() ?? ''),
      'ancestor_category': ancestorCategory,
      'ancestor_guid': ancestorGuid,
      'play_item_guid': item['Id']?.toString() ?? '',
      'duration': secondsFromTicks(item['RunTimeTicks']),
      'logic_type': 0,
      'episode_number': type == 'Episode' ? (item['IndexNumber'] ?? 0) : 0,
      'air_date': _releaseDate(item),
    }..removeWhere((key, value) => value == null);
  }

  /// Seasons of a series (`SeasonListResponse`).
  static List<Map<String, dynamic>> toSeasonList(
    List<dynamic> seasons,
    String baseUrl, {
    required Map<String, dynamic> series,
  }) {
    final seriesId = series['Id']?.toString() ?? '';
    final seriesName = series['Name']?.toString() ?? '';
    final ancestorGuid = series['ParentId']?.toString() ?? seriesId;
    final ancestorName = ((series['Studios'] as List?)?.firstOrNull is Map)
        ? ((series['Studios'] as List).first as Map)['Name']?.toString() ?? ''
        : '';

    return seasons.whereType<Map>().map((raw) {
      final season = Map<String, dynamic>.from(raw);
      final userData = _userData(season);
      final seasonNumber = season['IndexNumber'] ?? 0;
      final seasonTitle = season['Name']?.toString() ?? '第 $seasonNumber 季';
      // Season folders hardly ever carry their own artwork (the server only
      // scrapes the series), so the card borrows the series poster instead of
      // rendering a placeholder for a show that has a perfectly good cover.
      final poster = _primaryImage(baseUrl, season) ??
          _imageUrl(baseUrl, series, kind: 'Primary', maxWidth: 400);
      return <String, dynamic>{
        'guid': season['Id']?.toString() ?? '',
        'lan': '',
        'imdb_id': null,
        'trim_id': season['Id']?.toString() ?? '',
        'tv_title': seriesName,
        'parent_guid': seriesId,
        'parent_title': series['SeasonName']?.toString() ?? '',
        'title': seasonTitle,
        'type': 'Season',
        'poster': poster,
        'poster_width': 400,
        'poster_height': 600,
        'is_favorite': _isFavorite(userData) ? 1 : 0,
        'watched': _isPlayed(userData) ? 1 : 0,
        'watched_ts': 0,
        'vote_average': '',
        'media_stream': <String, dynamic>{},
        'season_number': seasonNumber,
        'episode_number': 0,
        'air_date': _releaseDate(season),
        'number_of_seasons': series['ChildCount'] ?? 1,
        'number_of_episodes': season['ChildCount'] ?? 0,
        'local_number_of_seasons': series['ChildCount'] ?? 1,
        'local_number_of_episodes': season['ChildCount'] ?? 0,
        'status': series['Status']?.toString() ?? '',
        'overview': season['Overview']?.toString(),
        'ancestor_guid': ancestorGuid,
        'ancestor_name': ancestorName,
        'ancestor_category': 'TV',
        'ts': secondsFromTicks(userData['PlaybackPositionTicks']),
        'duration': secondsFromTicks(season['RunTimeTicks']),
        'single_child_guid': '',
        'file_name': '',
      };
    }).toList();
  }

  /// Episodes of a season (`EpisodeListResponse`).
  static List<Map<String, dynamic>> toEpisodeList(
    List<dynamic> episodes,
    String baseUrl, {
    required Map<String, dynamic> season,
    Map<String, dynamic>? series,
  }) {
    final seasonId = season['Id']?.toString() ?? '';
    final seriesId =
        season['SeriesId']?.toString() ?? series?['Id']?.toString() ?? '';
    final seriesName =
        season['SeriesName']?.toString() ?? series?['Name']?.toString() ?? '';
    final seasonName = season['Name']?.toString() ?? '';

    return episodes.whereType<Map>().map((raw) {
      final episode = Map<String, dynamic>.from(raw);
      final userData = _userData(episode);
      // Episode stills are frequently missing (unaired, just added, or the
      // server only scraped the series), so fall back to the series poster —
      // the fnOS card always renders something, and an empty slot for every
      // episode looked like a broken grid.
      final poster = _primaryImage(baseUrl, episode) ??
          (series == null
              ? null
              : _imageUrl(baseUrl, series, kind: 'Primary', maxWidth: 400)) ??
          _imageUrl(baseUrl, season, kind: 'Primary', maxWidth: 400);
      // Emby leaves RunTimeTicks off the episode row for library entries it has
      // not probed; the media source usually still has it.
      final runtime = secondsFromTicks(
        episode['RunTimeTicks'] ?? _firstSource(episode)?['RunTimeTicks'],
      );
      return <String, dynamic>{
        'guid': episode['Id']?.toString() ?? '',
        'lan': '',
        'imdb_id': null,
        'trim_id': episode['Id']?.toString() ?? '',
        'tv_title': seriesName,
        'parent_guid': seasonId,
        'parent_title': seasonName,
        'title': episode['Name']?.toString() ?? '',
        'type': 'Episode',
        'poster': poster,
        'poster_width': 400,
        'poster_height': 600,
        'runtime': runtime ~/ 60,
        'is_favorite': _isFavorite(userData) ? 1 : 0,
        'watched': _isPlayed(userData) ? 1 : 0,
        'watched_ts': 0,
        'vote_average':
            episode['CommunityRating'] == null ? '' : '${episode['CommunityRating']}',
        'media_stream': <String, dynamic>{},
        'season_number': episode['ParentIndexNumber'] ?? 0,
        'episode_number': episode['IndexNumber'] ?? 0,
        'air_date': _releaseDate(episode),
        'number_of_seasons': series?['ChildCount'] ?? 1,
        'number_of_episodes': season['ChildCount'] ?? 0,
        'local_number_of_seasons': series?['ChildCount'] ?? 1,
        'local_number_of_episodes': season['ChildCount'] ?? 0,
        'status': series?['Status']?.toString() ?? '',
        'overview': episode['Overview']?.toString(),
        'ancestor_guid': season['ParentId']?.toString() ?? seriesId,
        'ancestor_name': seasonName,
        'ancestor_category': 'TV',
        'ts': secondsFromTicks(userData['PlaybackPositionTicks']),
        'duration': runtime,
        'single_child_guid': '',
        'video_guid': null,
        'file_name': '',
      };
    }).toList();
  }

  /// `play/list` (continue watching).
  static List<Map<String, dynamic>> toPlayDetailList(
    List<dynamic> items,
    String baseUrl,
  ) {
    return items.whereType<Map>().map((raw) {
      final item = Map<String, dynamic>.from(raw);
      final userData = _userData(item);
      final type = typeOf(item);
      // Episodes often have no own artwork; the fnOS contract falls back to
      // the series poster for the card, and the resolution badge comes from
      // the first video stream (absent on strm sources).
      final poster = _primaryImage(baseUrl, item) ??
          _seriesPrimaryImage(baseUrl, item);
      final videoStream = _firstVideoStream(item);
      return <String, dynamic>{
        'guid': guidOf(item),
        'title': item['Name']?.toString() ?? '',
        'type': type,
        'poster': poster,
        'media_stream': <String, dynamic>{
          if (videoStream != null)
            'resolutions': <String>[
              resolutionLabelFromHeight(
                      (videoStream['Height'] as num?)?.toInt() ?? 0) ??
                  '',
            ].where((e) => e.isNotEmpty).toList(),
          'audio_type': null,
          'color_range_type': null,
        },
        'is_favorite': _isFavorite(userData) ? 1 : 0,
        'watched': _isPlayed(userData) ? 1 : 0,
        'vote_average':
            item['CommunityRating'] == null ? '' : '${item['CommunityRating']}',
        'season_number': item['ParentIndexNumber'] ?? 0,
        'episode_number': type == 'Episode' ? (item['IndexNumber'] ?? 0) : 0,
        'tv_title': item['SeriesName']?.toString(),
        'duration': secondsFromTicks(item['RunTimeTicks']),
        'ts': secondsFromTicks(userData['PlaybackPositionTicks']),
        'status': item['Status']?.toString(),
        'parent_guid': item['SeriesId']?.toString() ??
            item['SeasonId']?.toString() ??
            item['ParentId']?.toString(),
      }..removeWhere((key, value) => value == null);
    }).toList();
  }

  /// First `Media` source of an item, or null when the payload carries none.
  static Map<String, dynamic>? _firstSource(Map<String, dynamic> item) {
    final sources = item['MediaSources'];
    if (sources is! List || sources.isEmpty) return null;
    final source = sources.first;
    return source is Map ? Map<String, dynamic>.from(source) : null;
  }

  /// First `Video` stream of the item's first media source, or null when the
  /// source carries no stream metadata (strm entries open lazily server-side).
  static Map<String, dynamic>? _firstVideoStream(Map<String, dynamic> item) {
    final sources = item['MediaSources'];
    if (sources is! List || sources.isEmpty) return null;
    final source = sources.first;
    if (source is! Map) return null;
    final streams = source['MediaStreams'];
    if (streams is! List) return null;
    for (final raw in streams) {
      if (raw is Map && raw['Type'] == 'Video') {
        return Map<String, dynamic>.from(raw);
      }
    }
    return null;
  }

  /// Series poster for episodes without own artwork. The media source's
  /// `SeriesId` points at the parent show, whose Primary image the card can
  /// borrow exactly like the fnOS contract does with its poster fallback.
  static String? _seriesPrimaryImage(String baseUrl, Map<String, dynamic> item) {
    final seriesId = item['SeriesId']?.toString() ?? '';
    if (seriesId.isEmpty) return null;
    return EmbyUrls.image(baseUrl, seriesId,
        kind: 'Primary', maxWidth: 400);
  }

  /// Playback negotiation (`PlayInfoResponse`).
  static Map<String, dynamic> toPlayInfo(
    Map<String, dynamic> item,
    String baseUrl, {
    required Map<String, dynamic> source,
    Map<String, dynamic>? series,
  }) {
    final userData = _userData(item);
    final streams = (source['MediaStreams'] as List?) ?? const [];
    final video = streams.whereType<Map>().where((s) => s['Type'] == 'Video');
    final audio = streams.whereType<Map>().where((s) => s['Type'] == 'Audio');
    final target = video.isNotEmpty
        ? video.first
        : (streams.isNotEmpty ? streams.firstWhere((s) => s is Map) : null);
    final audioIndex = source['DefaultAudioStreamIndex'] ??
        (audio.isNotEmpty ? audio.first['Index'] : null);

    return <String, dynamic>{
      'grand_guid': series?['Id']?.toString() ??
          item['SeriesId']?.toString() ??
          item['Id']?.toString() ??
          '',
      'guid': item['Id']?.toString() ?? '',
      'parent_guid': item['SeriesId']?.toString() ??
          item['SeasonId']?.toString() ??
          item['ParentId']?.toString() ??
          '',
      'ts': secondsFromTicks(userData['PlaybackPositionTicks']),
      'type': typeOf(item),
      'video_guid': video.isNotEmpty
          ? 'v${video.first['Index'] ?? 0}'
          : 'v${target is Map ? target['Index'] ?? 0 : 0}',
      'audio_guid': audioIndex == null ? '' : 'a$audioIndex',
      'subtitle_guid': '',
      'media_guid': item['Id']?.toString() ?? '',
      'item': toItemResponse(item, baseUrl),
      'direct_link_audio_index': -1,
      'play_config': <String, dynamic>{'guid': '', 'skip_opening': 0, 'skip_ending': 0},
    };
  }

  /// Stream negotiation (`StreamResponse` + `StreamListResponse`).
  static Map<String, dynamic> toStreamResponse(
    Map<String, dynamic> item,
    String baseUrl, {
    required Map<String, dynamic> source,
  }) {
    final streams = ((source['MediaStreams'] as List?) ?? const [])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final videoStreams =
        streams.where((s) => s['Type'] == 'Video').toList();
    final audioStreams =
        streams.where((s) => s['Type'] == 'Audio').toList();
    final subtitleStreams =
        streams.where((s) => s['Type'] == 'Subtitle').toList();
    final itemId = item['Id']?.toString() ?? '';
    final mediaGuid = itemId;
    final sourceId = source['Id']?.toString() ?? itemId;
    final runtimeSeconds = secondsFromTicks(source['RunTimeTicks'] ?? item['RunTimeTicks']);
    final primary = videoStreams.isNotEmpty ? videoStreams.first : null;
    final width = primary?['Width'] is num ? (primary!['Width'] as num).toInt() : 0;
    final height = primary?['Height'] is num ? (primary!['Height'] as num).toInt() : 0;
    final bitrate = source['Bitrate'] is num ? (source['Bitrate'] as num).toInt() : 0;

    return <String, dynamic>{
      'video_stream': primary == null
          ? null
          : _videoStreamJson(
              primary,
              mediaGuid: mediaGuid,
              durationSeconds: runtimeSeconds,
              fallbackWidth: width,
              fallbackHeight: height,
              fallbackBps: bitrate,
            ),
      'audio_streams': audioStreams
          .map((s) => _audioStreamJson(s, mediaGuid: mediaGuid,
              durationSeconds: runtimeSeconds))
          .toList(),
      'subtitle_streams': subtitleStreams
          .map((s) => _subtitleStreamJson(s, mediaGuid: mediaGuid, itemId: itemId))
          .toList(),
      'file_stream': <String, dynamic>{
        'guid': sourceId,
        'path': source['Path']?.toString() ?? '',
        'file_name': _fileName(source['Path']?.toString(), item['Name']?.toString()),
        'size': source['Size'] is num ? (source['Size'] as num).toInt() : 0,
        'timestamp': 0,
        'type': 0,
        'can_play': 1,
        'play_error': '',
        'create_time': 0,
        'update_time': 0,
        'file_birth_time': 0,
        'progress_thumb_hash_dir': '',
      },
      'qualities': <Map<String, dynamic>>[
        <String, dynamic>{
          'bitrate': bitrate,
          'resolution': _resolutionLabel(width, height),
          'progressive': true,
          'is_m3u8': false,
        },
      ],
    };
  }

  static String _fileName(String? path, String? title) {
    if (path != null && path.isNotEmpty) {
      final parts = path.split(RegExp(r'[/\\]'));
      if (parts.isNotEmpty && parts.last.isNotEmpty) return parts.last;
    }
    return title ?? '';
  }

  /// `1920x1080` → `1080p`, matching the fnOS resolution labels.
  static String _resolutionLabel(int width, int height) =>
      resolutionLabelFromHeight(height) ?? '1080p';

  /// Height → fnOS resolution bucket, or `null` when the item carries no
  /// dimensions at all.
  ///
  /// Split out from [_resolutionLabel] because the filter rows must be able to
  /// tell "unknown" from "1080p": reporting a guess there would insert a
  /// `1080p` option into a library that has none.
  static String? resolutionLabelFromHeight(int height) {
    if (height >= 2000) return '4K';
    if (height >= 1000) return '1080p';
    if (height >= 700) return '720p';
    if (height > 0) return '${height}p';
    return null;
  }

  /// fnOS `color_range` filter value for a video stream (`SDR` / `HDR` /
  /// `DolbyVision`).
  static String? colorRangeOf(Map<String, dynamic> stream) {
    final range = videoRangeOf(stream);
    if (range == null) return null;
    if (range.dvProfile > 0) return 'DolbyVision';
    return range.isSdr ? 'SDR' : 'HDR';
  }

  /// Parsed `VideoRange` / `VideoRangeType` / `ExtendedVideo*` metadata.
  ///
  /// Emby and Jellyfin disagree on where this lives, and both fields can be
  /// absent depending on the server version:
  ///
  ///  * Emby 4.9 (verified against a live 4.9.0.46 server) sends only
  ///    `VideoRange` ("SDR" / "HDR 10" / "HLG" / "DolbyVision") plus
  ///    `ExtendedVideoType` + `ExtendedVideoSubType` ("DoviProfile50"). It
  ///    never sends `VideoRangeType`.
  ///  * Jellyfin 10.9+ sends `VideoRangeType` ("SDR" / "HDR10" / "HLG" /
  ///    "DOVI" / "DOVIWithHDR10" / "DOVIProfile5").
  ///
  /// Reading only `VideoRangeType` therefore made every Emby HDR and Dolby
  /// Vision stream look like SDR: `color_range_type` came back as "SDR", so
  /// the player picked the direct-play link and mpv was handed raw BT.2020 PQ
  /// (or IPTPQc2) samples that it then rendered as if they were BT.709 —
  /// washed out and oversaturated. That is the wrong-colour symptom.
  static MediaVideoRange? videoRangeOf(Map<String, dynamic> stream) {
    final rangeType = stream['VideoRangeType']?.toString() ?? '';
    final videoRange = stream['VideoRange']?.toString() ?? '';
    final extended = stream['ExtendedVideoType']?.toString() ?? '';
    final subType = stream['ExtendedVideoSubType']?.toString() ?? '';
    final transfer = stream['ColorTransfer']?.toString() ?? '';
    final primaries = stream['ColorPrimaries']?.toString() ?? '';

    final joined = <String>[
      rangeType,
      videoRange,
      extended,
      subType,
      transfer,
      primaries,
      stream['DisplayTitle']?.toString() ?? '',
    ].join(' ').toUpperCase();
    if (joined.trim().isEmpty) return null;

    // Transfer function / primaries alone already identify HDR even when the
    // server leaves every range field empty: PQ (smpte2084), HLG
    // (arib-std-b67) and BT.2020 primaries never occur on an SDR stream.
    final isHdrTransfer =
        transfer.toLowerCase() == 'smpte2084' ||
            transfer.toLowerCase() == 'arib-std-b67' ||
            primaries.toLowerCase().startsWith('bt2020');
    final dvProfile = _dvProfileFromFields(stream, joined);
    final isDv = dvProfile > 0;
    final isHdr = isDv ||
        isHdrTransfer ||
        joined.contains('HDR') ||
        joined.contains('HLG') ||
        joined.contains('PQ');

    // fnOS only knows SDR / HDR / DolbyVision, so Emby's "HDR 10" and "HLG"
    // both collapse to "HDR" here. The exact transfer function is not lost:
    // mpv reads it from the bitstream itself, and the detail page shows the
    // raw value from the stream payload.
    return MediaVideoRange(
      label: isDv ? 'DolbyVision' : (isHdr ? 'HDR' : 'SDR'),
      isSdr: !isHdr,
      dvProfile: dvProfile,
    );
  }

  /// fnOS `audio_type` filter value for an audio stream.
  ///
  /// fnOS buckets audio into `DolbyAtmos` / `DolbySurround` / `Stereo` /
  /// `Others`; Emby only exposes a codec and a channel count, so the bucket is
  /// derived from those.
  static String audioProfileOf(Map<String, dynamic> stream) {
    final codec = stream['Codec']?.toString().toLowerCase() ?? '';
    final profile = stream['Profile']?.toString().toLowerCase() ?? '';
    final title = stream['DisplayTitle']?.toString().toLowerCase() ?? '';
    final channels =
        stream['Channels'] is num ? (stream['Channels'] as num).toInt() : 2;

    final isAtmos = title.contains('atmos') || profile.contains('atmos');
    if (isAtmos) return 'DolbyAtmos';
    final isDolby =
        codec.startsWith('eac3') || codec.startsWith('ac3') || codec == 'truehd';
    if (isDolby) return channels > 2 ? 'DolbySurround' : 'Others';
    return channels == 2 ? 'Stereo' : 'Others';
  }

  static Map<String, dynamic> _videoStreamJson(
    Map<String, dynamic> stream, {
    required String mediaGuid,
    required int durationSeconds,
    required int fallbackWidth,
    required int fallbackHeight,
    required int fallbackBps,
  }) {
    final width = stream['Width'] is num ? (stream['Width'] as num).toInt() : fallbackWidth;
    final height = stream['Height'] is num ? (stream['Height'] as num).toInt() : fallbackHeight;
    final bitrate = stream['BitRate'] is num ? (stream['BitRate'] as num).toInt() : fallbackBps;
    final range = videoRangeOf(stream);
    return <String, dynamic>{
      'media_guid': mediaGuid,
      'title': stream['DisplayTitle']?.toString() ?? '',
      'guid': 'v${stream['Index'] ?? 0}',
      'resolution_type': _resolutionLabel(width, height),
      'color_range_type': range?.label ?? 'SDR',
      'codec_name': stream['Codec']?.toString() ?? '',
      'codec_type': 'video',
      'color_range': stream['ColorRange']?.toString() ?? '',
      'profile': stream['Profile']?.toString() ?? '',
      'index': (stream['Index'] is num) ? (stream['Index'] as num).toInt() : 0,
      'width': width,
      'height': height,
      'coded_width': width,
      'coded_height': height,
      'display_aspect_ratio': stream['AspectRatio']?.toString() ?? '',
      'pix_fmt': stream['PixelFormat']?.toString() ?? '',
      'level': stream['Level'] is num ? '${stream['Level']}' : '',
      'color_space': stream['ColorSpace']?.toString() ?? '',
      'color_transfer': stream['ColorTransfer']?.toString() ?? '',
      'color_primaries': stream['ColorPrimaries']?.toString() ?? '',
      'duration': durationSeconds,
      'dv_profile': range?.dvProfile ?? 0,
      'refs': 0,
      'r_frame_rate': stream['RealFrameRate'] is num ? '${stream['RealFrameRate']}' : '',
      'avg_frame_rate': stream['AverageFrameRate'] is num ? '${stream['AverageFrameRate']}' : '',
      'bits_per_raw_sample': stream['BitDepth'] is num ? '${stream['BitDepth']}' : '',
      'bps': bitrate,
      'progressive': stream['IsInterlaced'] == true ? 0 : 1,
      'bit_depth': stream['BitDepth'] is num ? (stream['BitDepth'] as num).toInt() : 8,
      'wrapper': '',
      'create_time': 0,
      'update_time': 0,
      'rotation': 0,
      'ext1': 0,
      'is_bluray': false,
    };
  }

  /// Dolby Vision profile, read from whichever field the server fills in.
  ///
  /// Emby 4.9 never sends `DvProfile`; it encodes the profile in
  /// `ExtendedVideoSubType` as `DoviProfile50` / `DoviProfile76` /
  /// `DoviProfile81` / `DoviProfile84`, i.e. `DoviProfile<major><minor>` with
  /// the minor digit appended. `DoviProfile50` is profile 5.0, `81` is 8.1.
  /// Jellyfin instead appends the profile to `VideoRangeType` (`DOVIProfile5`)
  /// or only says `DOVI`. Profile 5 matters most: it has no HDR10 fallback and
  /// its IPTPQc2 primaries render green/purple unless tone-mapped.
  static int _dvProfileFromFields(Map<String, dynamic> stream, String joined) {
    final reported = stream['DvProfile'];
    if (reported is num && reported > 0) return reported.toInt();
    if (!joined.contains('DOVI') &&
        !joined.contains('DOLBYVISION') &&
        !joined.contains('DOLBY VISION')) {
      return 0;
    }
    // `DoviProfile50` → 5, `DoviProfile81` → 8 (major only; the minor digit
    // does not change how the stream has to be rendered).
    final subType = stream['ExtendedVideoSubType']?.toString() ?? '';
    final profileMatch =
        RegExp(r'PROFILE\s*(\d+)', caseSensitive: false).firstMatch(subType) ??
            RegExp(r'PROFILE\s*(\d+)', caseSensitive: false)
                .firstMatch(joined);
    if (profileMatch != null) {
      final raw = profileMatch.group(1)!;
      // Two-digit forms are "<major><minor>"; a single digit is a bare profile.
      final major = raw.length > 1 ? raw.substring(0, 1) : raw;
      final parsed = int.tryParse(major);
      if (parsed != null && parsed > 0) return parsed;
    }
    // "DOVI" alone carries no number; assume 8 (the HDR10-compatible profile),
    // which is what nearly every non-profile-5 release uses.
    return 8;
  }

  static Map<String, dynamic> _audioStreamJson(
    Map<String, dynamic> stream, {
    required String mediaGuid,
    required int durationSeconds,
  }) {
    return <String, dynamic>{
      'media_guid': mediaGuid,
      'title': stream['DisplayTitle']?.toString() ?? '',
      'guid': 'a${stream['Index'] ?? 0}',
      'audio_type': stream['Codec']?.toString() ?? '',
      'codec_name': stream['Codec']?.toString() ?? '',
      'codec_type': 'audio',
      'language': stream['Language']?.toString() ?? '',
      'channels': stream['Channels'] is num ? (stream['Channels'] as num).toInt() : 2,
      'profile': stream['Profile']?.toString() ?? '',
      'sample_rate': stream['SampleRate'] is num ? '${stream['SampleRate']}' : '',
      'is_default': stream['IsDefault'] == true ? 1 : 0,
      'channel_layout': stream['ChannelLayout']?.toString() ?? '',
      'duration': durationSeconds,
      'index': stream['Index'] is num ? (stream['Index'] as num).toInt() : 0,
      'bits_per_raw_sample': stream['BitDepth'] is num ? '${stream['BitDepth']}' : '',
      'bps': stream['BitRate'] is num ? (stream['BitRate'] as num).toInt() : 0,
      'create_time': 0,
      'update_time': 0,
      'is_fake': false,
    };
  }

  static Map<String, dynamic> _subtitleStreamJson(
    Map<String, dynamic> stream, {
    required String mediaGuid,
    required String itemId,
  }) {
    final index = stream['Index'] is num ? (stream['Index'] as num).toInt() : 0;
    final isExternal = stream['IsExternal'] == true;
    final deliveryUrl = stream['DeliveryUrl']?.toString() ?? '';
    return <String, dynamic>{
      'media_guid': mediaGuid,
      'title': stream['DisplayTitle']?.toString() ?? '',
      // `<index>@<itemId>`: the guid is the only thing the subtitle download
      // path receives, and Emby addresses subtitles per item.
      'guid': 's$index@$itemId',
      'codec_name': stream['Codec']?.toString() ?? '',
      'codec_type': 'subtitle',
      'language': stream['Language']?.toString() ?? '',
      'forced': stream['IsForced'] == true ? 1 : 0,
      'index': index,
      'is_default': stream['IsDefault'] == true ? 1 : 0,
      'is_external': isExternal ? 1 : 0,
      'format': stream['Codec']?.toString() ?? '',
      'trim_id': '',
      'source_id': '',
      'Source': deliveryUrl,
      'create_time': 0,
      'update_time': 0,
      'extra_file': 0,
      // Bitmap subtitles (PGS/DVD) must be burned in by the server or rendered
      // by mpv from the container; the client cannot wrap them as text.
      'is_bitmap': _isBitmap(stream) ? 1 : 0,
      'file_size': 0,
    };
  }

  static bool _isBitmap(Map<String, dynamic> stream) {
    final codec = (stream['Codec']?.toString() ?? '').toLowerCase();
    return codec == 'pgssub' ||
        codec == 'dvdsub' ||
        codec == 'dvbsub' ||
        codec == 'hdmv_pgs_subtitle';
  }

  /// `person/list` (cast & crew of one item).
  static List<Map<String, dynamic>> toPersonList(
    Map<String, dynamic> item,
    String baseUrl,
  ) {
    final people = ((item['People'] as List?) ?? const []).whereType<Map>();
    var order = 0;
    return people.map((person) {
      final profileTag = person['PrimaryImageTag']?.toString();
      return <String, dynamic>{
        'item_guid': item['Id']?.toString() ?? '',
        'person_guid': person['Id']?.toString() ?? '',
        'role': person['Role']?.toString() ?? '',
        'job': person['Type']?.toString() ?? '',
        'order': order++,
        'department': person['Type']?.toString() ?? '',
        'trim_id': '',
        'imdb_id': '',
        'tmdb_id': 0,
        'lan': '',
        'name': person['Name']?.toString() ?? '',
        'original_name': '',
        'also_know_as': '',
        'biography': '',
        'known_for_department': person['Type']?.toString() ?? '',
        'profile_path': profileTag == null
            ? ''
            : EmbyUrls.image(
                baseUrl,
                person['Id']?.toString() ?? '',
                maxWidth: 300,
                tag: profileTag,
              ),
        'gender': 0,
      };
    }).toList();
  }

  /// `person/{guid}` (one person's bio page).
  static Map<String, dynamic> toPersonResponse(
    Map<String, dynamic> person,
    String baseUrl,
  ) {
    final tag = person['ImageTags'] is Map
        ? (person['ImageTags'] as Map)['Primary']?.toString()
        : null;
    return <String, dynamic>{
      'guid': person['Id']?.toString() ?? '',
      'name': person['Name']?.toString() ?? '',
      'imdb_id': null,
      'original_name': null,
      'profile': tag == null
          ? null
          : EmbyUrls.image(baseUrl, person['Id']?.toString() ?? '',
              maxWidth: 400, tag: tag),
      'biography': person['Overview']?.toString(),
      'is_favorite': 0,
    };
  }

  /// `person/item/list` (a person's works, split by job).
  static Map<String, dynamic> toPersonItemList(
    Map<String, dynamic> payload,
    String baseUrl,
    List<Map<String, dynamic>> credits,
  ) {
    final items = (payload['Items'] as List?) ?? const [];
    return <String, dynamic>{
      'list': items.whereType<Map>().map((raw) {
        final item = Map<String, dynamic>.from(raw);
        final userData = _userData(item);
        final poster = _primaryImage(baseUrl, item);
        return <String, dynamic>{
          'guid': guidOf(item),
          'title': item['Name']?.toString() ?? '',
          'poster': poster,
          'poster_width': 400,
          'poster_height': 600,
          'release_date': _releaseDate(item),
          'vote_average': item['CommunityRating'] == null
              ? ''
              : '${item['CommunityRating']}',
          'is_favorite': _isFavorite(userData) ? 1 : 0,
          'watched': _isPlayed(userData) ? 1 : 0,
          'duration': secondsFromTicks(item['RunTimeTicks']),
          'status': item['Status']?.toString(),
          'type': typeOf(item),
        }..removeWhere((key, value) => value == null);
      }).toList(),
      'total': payload['TotalRecordCount'] ?? items.length,
    };
  }

  /// `media/sum` counters (`total`/`movie`/`tv`/`video`).
  static Map<String, int> toMediaSum(Map<String, dynamic> counts) {
    int read(String key) =>
        counts[key] is num ? (counts[key] as num).toInt() : 0;
    final movies = read('MovieCount');
    final series = read('SeriesCount');
    final episodes = read('EpisodeCount');
    final videos = read('VideoCount') + read('MusicVideoCount');
    return <String, int>{
      'total': read('ItemCount'),
      'movie': movies,
      'tv': series,
      'video': videos,
      'live': 0,
      'episode': episodes,
    };
  }
}

/// Dynamic range of one video stream, derived from whichever metadata fields
/// the server actually fills in.
///
/// [label] is the fnOS-compatible bucket (`SDR` / `HDR` / `DolbyVision`);
/// [dvProfile] is 0 for anything that is not Dolby Vision.
class MediaVideoRange {
  const MediaVideoRange({
    required this.label,
    required this.isSdr,
    required this.dvProfile,
  });

  final String label;
  final bool isSdr;
  final int dvProfile;

  bool get isDolbyVision => dvProfile > 0;
}
