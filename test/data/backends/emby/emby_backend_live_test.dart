// Live end-to-end test against a real Emby-family server.
//
// Skipped unless `EMBY_BASE_URL`, `EMBY_USER`, `EMBY_PASS` are set, so the
// suite stays green offline:
//
//   EMBY_BASE_URL=https://demo.jellyfin.org/stable EMBY_USER=demo EMBY_PASS= \
//     dart test test/emby_backend_live_test.dart
//
// It drives [EmbyMediaBackend] through the same calls the app's view models
// make, so a failure here means a real screen would fail, not just a mapper.
import 'dart:io';

import 'package:fly_narwhal/data/backends/emby/emby_api.dart';
import 'package:fly_narwhal/data/backends/emby/emby_media_backend.dart';
import 'package:fly_narwhal/data/backends/media_backend.dart';
import 'package:fly_narwhal/data/models/home_models.dart' as fn;
import 'package:fly_narwhal/data/models/player_models.dart';
import 'package:fly_narwhal/data/models/media_request_models.dart';
import 'package:flutter_test/flutter_test.dart' hide Tags;

void main() {
  final baseUrl = Platform.environment['EMBY_BASE_URL'] ?? '';
  final username = Platform.environment['EMBY_USER'] ?? '';
  final password = Platform.environment['EMBY_PASS'] ?? '';

  if (baseUrl.isEmpty || username.isEmpty) {
    test('live emby backend skipped (set EMBY_BASE_URL / EMBY_USER)', () {},
        skip: 'no server configured');
    return;
  }

  late EmbyMediaBackend backend;
  late BackendCapabilities caps;

  setUpAll(() async {
    final auth = await EmbyApi.authenticate(
      baseUrl: baseUrl,
      username: username,
      password: password,
      deviceId: 'mtest-device',
    );
    final result = auth.dataOrNull;
    expect(result, isNotNull, reason: 'authenticate: ${auth.failureOrNull?.message}');
    backend = EmbyMediaBackend(
      api: EmbyApi(
        credentials: EmbyCredentials(
          baseUrl: baseUrl,
          accessToken: result!.accessToken,
          userId: result.userId,
          deviceId: 'mtest-device',
        ),
      ),
      initialBaseUrl: baseUrl,
    );
    caps = backend.capabilities;
  });

  test('backend reports Emby capabilities and a session', () {
    expect(backend.hasSession, isTrue);
    expect(caps.danmaku, isFalse);
    expect(caps.smartSkip, isFalse);
    expect(caps.liveTv, isFalse);
    expect(caps.cloudDirectLink, isFalse);
    expect(caps.serverTranscode, isFalse);
    expect(caps.itemManagement, isTrue);
  });

  test('player headers use the Jellyfin-compatible Authorization form', () {
    final headers = backend.playerHeaders;
    // Jellyfin 10.10+ rejects X-Emby-Token, so the MediaBrowser form is the
    // only one that works against both server families.
    expect(headers.keys, contains('Authorization'));
    expect(headers['Authorization'], startsWith('MediaBrowser Token='));
    expect(headers.containsKey('X-Emby-Token'), isFalse);
    expect(headers.containsKey('Cookie'), isFalse);
  });

  test('getCurrentUser resolves the signed-in account', () async {
    final result = await backend.getCurrentUser();
    expect(result.failureOrNull?.message, isNull,
        reason: 'getCurrentUser failed');
    final user = result.getOrThrow();
    expect(user.guid, isNotEmpty);
    expect(user.username, isNotEmpty);
  });

  test('direct stream URL is absolute and static-stream shaped', () {
    final url = backend.buildDirectStreamUrl('abc123');
    expect(url, startsWith(baseUrl.replaceAll(RegExp(r'/$'), '')));
    expect(url, contains('/Videos/abc123/stream'));
    expect(url, contains('static=true'));
    // Jellyfin 10.10+ matches query keys case-sensitively and 401s on the
    // snake_case spelling, while Emby 4.9 does the exact opposite. Both must
    // be present or one server family answers 401 to mpv's bare range GET.
    expect(url, contains('ApiKey='));
    expect(url, contains('api_key='));
    // The quality index is fnOS-only and must not leak into an Emby URL.
    expect(backend.buildDirectStreamUrl('abc123', directLinkQualityIndex: 3),
        isNot(contains('direct_link_quality_index')));
  });

  /// Walks a library until it reaches a playable item, exactly like the user
  /// drilling through folder cards. Folders carry the `fv_` prefix the UI
  /// uses to decide "navigate" vs "play".
  Future<fn.ItemListQueryResponse> browse(String guid, {int depth = 0}) async {
    final page = (await backend.getItemList(fn.ItemListQueryRequest(
      ancestorGuid: guid.startsWith('fv_') ? null : guid,
      parentGuid: guid.startsWith('fv_') ? guid : null,
      page: 1,
      pageSize: 20,
      sortColumn: 'sort_title',
      sortType: 'ASC',
      // The same type set `MediaType.libraryBrowse` sends for a real browse.
      tags: fn.Tags(
        type: const ['Movie', 'TV', 'Directory', 'Video', 'LiveChannel'],
      ),
    )))
        .getOrThrow();
    return page;
  }

  test('library list, folder drill-down, detail and playback negotiate',
      () async {
    final libraries = (await backend.getMediaDbList()).getOrThrow();
    expect(libraries, isNotEmpty, reason: 'no libraries on this server');

    final library = libraries.first;
    var page = await browse(library.guid);
    expect(page.list, isNotEmpty, reason: 'library "${library.title}" is empty');

    // Folders first: this is what the user sees on a fresh demo server.
    var guard = 0;
    while (page.list.every((i) => i.guid.startsWith('fv_')) && guard++ < 4) {
      page = await browse(page.list.first.guid);
      expect(page.list, isNotEmpty, reason: 'nested folder is empty');
    }

    final target = page.list.firstWhere(
      (i) => !i.guid.startsWith('fv_'),
      orElse: () => page.list.first,
    );
    final detail = (await backend.getItemDetail(target.guid)).getOrThrow();
    expect(detail.guid, isNotEmpty);
    expect(detail.title, isNotEmpty);

    // Play negotiation: play info -> stream info -> direct link.
    final playInfo = (await backend.getPlayerPlayInfo(
      PlayInfoRequest(itemGuid: detail.guid),
    ))
        .getOrThrow();
    expect(playInfo, isNotNull, reason: 'no play info for "${detail.title}"');
    final stream = (await backend.getStreamInfo(StreamRequest(
      mediaGuid: playInfo!.mediaGuid,
      header: Header(userAgent: const ['mtest']),
    )))
        .getOrThrow();
    expect(stream.videoStream, isNotNull);
    expect(stream.fileStream, isNotNull);
    expect(stream.qualities, isNotEmpty);

    final play = (await backend.playVideo(PlayPlayRequest(
      mediaGuid: stream.fileStream!.guid,
      videoGuid: stream.videoStream!.guid,
      videoEncoder: 'h264',
      resolution: stream.videoStream!.resolutionType,
      bitrate: stream.videoStream!.bps,
      audioGuid: stream.audioStreams?.first.guid ?? '',
    )))
        .getOrThrow();
    expect(play.playLink, startsWith('http'));
    expect(play.playLink, contains('/Videos/'));
  });

  test('direct-play URL serves ranged reads and progress is accepted',
      () async {
    // Reaches one episode the same way a user does: series -> season -> episode.
    final libraries = (await backend.getMediaDbList()).getOrThrow();
    final shows = libraries.where((l) => l.category == 'TV').toList();
    expect(shows, isNotEmpty, reason: 'no TV library on this server');

    final seriesPage = await browse(shows.first.guid);
    final series = seriesPage.list.firstWhere(
      (i) => !i.guid.startsWith('fv_'),
      orElse: () => seriesPage.list.first,
    );
    final seasons = (await backend.getSeasonList(series.guid)).getOrThrow();
    expect(seasons, isNotEmpty, reason: 'series "${series.title}" has no season');
    final episodes =
        (await backend.getEpisodeList(seasons.first.guid)).getOrThrow();
    expect(episodes, isNotEmpty, reason: 'season has no episode');

    final episode = episodes.first;
    final playInfo = (await backend.getPlayerPlayInfo(
      PlayInfoRequest(itemGuid: episode.guid),
    ))
        .getOrThrow()!;
    final stream = (await backend.getStreamInfo(StreamRequest(
      mediaGuid: playInfo.mediaGuid,
      header: Header(userAgent: const ['mtest']),
    )))
        .getOrThrow();

    // The URL the player hands to mpv must actually stream: byte ranges are
    // how seeking works, so a 200-without-ranges URL would look fine here and
    // still stutter in the app.
    final url = backend.buildDirectStreamUrl(playInfo.mediaGuid);
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Range', 'bytes=0-262143');
      final response = await request.close();
      final bytes = await response.fold<int>(0, (n, chunk) => n + chunk.length);
      expect(response.statusCode, 206, reason: 'server refused the range read');
      expect(bytes, greaterThan(0));
    } finally {
      client.close();
    }

    // Progress reporting: the player calls this every few seconds, so a
    // failure would silently lose resume positions.
    final progress = await backend.updatePlayRecord(PlayRecordRequest(
      itemGuid: episode.guid,
      mediaGuid: playInfo.mediaGuid,
      videoGuid: stream.videoStream?.guid ?? '',
      audioGuid: stream.audioStreams?.first.guid ?? '',
      resolution: stream.videoStream?.resolutionType ?? '',
      bitrate: stream.videoStream?.bps ?? 0,
      ts: 30,
      duration: 1500,
      deviceId: 'mtest-session',
      directLinkAudioIndex: -1,
      lan: '',
      deviceName: 'mtest',
    ));
    expect(progress.failureOrNull?.message, isNull,
        reason: 'updatePlayRecord failed');
  });

  test('transcode-session calls are safe no-ops on Emby', () async {
    // The player calls these on every quality change and on exit; they must
    // report success so the coordinator does not treat Emby as a failure.
    expect((await backend.resetQuality(MediaPRequest(playLink: ''))).isSuccess,
        isTrue);
    expect((await backend.resetAudio(MediaPRequest(playLink: ''))).isSuccess, isTrue);
    expect(
        (await backend.resetSubtitle(MediaPRequest(playLink: ''))).isSuccess, isTrue);
    expect((await backend.quit(MediaPRequest(playLink: ''))).isSuccess, isTrue);
    final status =
        (await backend.fetchTranscodeStatus(MediaPRequest(playLink: ''))).getOrThrow();
    expect(status.transcoded, isFalse);
  });
}
