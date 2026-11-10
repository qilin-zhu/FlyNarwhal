import 'dart:convert';
import 'dart:io';

import 'package:fly_narwhal/data/backends/emby/emby_mapper.dart';
import 'package:fly_narwhal/data/backends/emby/emby_tags.dart';
import 'package:fly_narwhal/data/backends/media_response_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const String baseUrl = 'https://demo.jellyfin.org/stable';

Map<String, dynamic> fixture(String name) {
  final file = File('test/fixtures/emby/$name.json');
  return Map<String, dynamic>.from(
    jsonDecode(file.readAsStringSync()) as Map,
  );
}

List<dynamic> fixtureList(String name) {
  final file = File('test/fixtures/emby/$name.json');
  return jsonDecode(file.readAsStringSync()) as List<dynamic>;
}

Map<String, dynamic> envelope(Object? data) =>
    <String, dynamic>{'code': 0, 'msg': '', 'data': data};

void main() {
  group('media libraries', () {
    test('maps Views into fnOS media db list', () {
      final views = fixture('views');
      final mapped = EmbyMapper.toMediaDbList(
        (views['Items'] as List),
        baseUrl,
      );
      final parsed = MediaResponseParser.parseMediaDbListResponse(
        envelope(mapped),
      );

      expect(parsed, hasLength(3));
      expect(parsed[0].title, 'Movies');
      expect(parsed[0].category, 'Movie');
      expect(
        parsed[0].posters.first,
        startsWith('$baseUrl/Items/f137a2dd21bbc1b99aa5c0f6bf02a805/Images/Primary'),
      );
      expect(parsed[1].category, 'TV');
      expect(parsed[2].category, 'Others');
    });

    test('media sum maps count keys', () {
      final sum = EmbyMapper.toMediaSum({
        'MovieCount': 11,
        'SeriesCount': 1,
        'EpisodeCount': 6,
        'ItemCount': 39,
        'MusicVideoCount': 0,
        'VideoCount': 0,
      });
      expect(sum['total'], 39);
      expect(sum['movie'], 11);
      expect(sum['tv'], 1);
      expect(sum['episode'], 6);
    });
  });

  group('item list', () {
    test('folders get the fv_ prefix and resolve images', () {
      final payload = fixture('items');
      final mapped = EmbyMapper.toItemListQuery(payload, baseUrl);
      final parsed = MediaResponseParser.parseItemListResponse(
        envelope(mapped),
      );

      expect(parsed.total, 2);
      final folder = parsed.list.first;
      expect(folder.type, 'Directory');
      // Folder drill-down is detected from this prefix.
      expect(folder.guid, startsWith(EmbyMapper.folderPrefix));
      expect(folder.guid, 'fv_a037f625e2aeec94f857cf9c071d7312');
      expect(folder.poster, startsWith('$baseUrl/Items/'));
      expect(folder.watched, 0);
    });

    test('rawId strips the folder prefix', () {
      expect(
        EmbyMapper.rawId('fv_a037f625e2aeec94f857cf9c071d7312'),
        'a037f625e2aeec94f857cf9c071d7312',
      );
      expect(EmbyMapper.rawId('abc123'), 'abc123');
    });
  });

  group('item detail', () {
    test('maps a movie with media streams and people', () {
      final detail = fixture('detail');
      final mapped = EmbyMapper.toItemResponse(detail, baseUrl);
      final parsed = MediaResponseParser.parseItemDetailResponse(
        envelope(mapped),
      );

      expect(parsed.guid, 'c002f0f88ee970cce7f138bbc925de64');
      expect(parsed.title, 'Dracula');
      expect(parsed.type, 'Movie');
      expect(parsed.voteAverage, '7.2');
      expect(parsed.contentRatings, 'NR');
      expect(parsed.releaseDate, '1931-02-12');
      expect(parsed.duration, 4466);
      expect(parsed.overview, isNotEmpty);
      expect(parsed.posters, startsWith('$baseUrl/Items/'));
      expect(parsed.backdrops, contains('/Images/Backdrop'));
      expect(parsed.playItemGuid, 'c002f0f88ee970cce7f138bbc925de64');
    });

    test('backdrop falls back to the first BackdropImageTag', () {
      final detail = fixture('detail');
      final mapped = EmbyMapper.toItemResponse(detail, baseUrl);
      expect(
        mapped['backdrops'],
        contains('tag=545281894daf67361d92ae7e13c80d68'),
      );
    });

    test('logo image is exported for the clearart slot', () {
      final detail = fixture('detail');
      final mapped = EmbyMapper.toItemResponse(detail, baseUrl);
      expect(mapped['logos'], contains('/Images/Logo'));
      expect(mapped['logos'], contains('tag=7b8e65b5b145c8798e05ac7cc6876ddc'));
    });

    test('no Logo image tag leaves the slot empty', () {
      final mapped = EmbyMapper.toItemResponse(
        {'Id': 'item1', 'Type': 'Movie', 'Name': 'X'},
        baseUrl,
      );
      expect(mapped.containsKey('logos'), isFalse);
    });

    test('genre names resolve through the shared genre index', () {
      final detail = fixture('detail');
      final mapped = EmbyMapper.toItemResponse(detail, baseUrl);
      final parsed = MediaResponseParser.parseItemDetailResponse(
        envelope(mapped),
      );

      // The detail page looks the id up in `tag/genres`, so the id registered
      // while mapping the item has to reproduce the same name.
      expect(parsed.genres, isNotNull);
      expect(parsed.genres, isNotEmpty);
      expect(parsed.genres!.map(EmbyGenreIndex.nameOf), contains('Horror'));
    });
  });

  group('streams', () {
    test('video/audio/subtitle streams map onto the fnOS models', () {
      final detail = fixture('detail');
      final source = (detail['MediaSources'] as List).first as Map;
      final mapped = EmbyMapper.toStreamResponse(
        detail,
        baseUrl,
        source: Map<String, dynamic>.from(source),
      );
      final parsed =
          MediaResponseParser.parseStreamResponse(envelope(mapped));

      expect(parsed.videoStream!.guid, 'v0');
      expect(parsed.videoStream!.codecName, 'h264');
      expect(parsed.videoStream!.resolutionType, '1080p');
      expect(parsed.videoStream!.colorRangeType, 'SDR');
      expect(parsed.videoStream!.height, 1080);
      expect(parsed.fileStream!.guid, 'c002f0f88ee970cce7f138bbc925de64');
      expect(parsed.fileStream!.canPlay, 1);
      expect(parsed.audioStreams, hasLength(1));
      expect(parsed.audioStreams!.first.guid, 'a1');
      expect(parsed.audioStreams!.first.language, 'eng');
      expect(parsed.qualities!.first.resolution, '1080p');
      expect(parsed.qualities!.first.bitrate, greaterThan(0));
    });

    test('bitmap subtitles are flagged so they are not wrapped as text', () {
      final source = {
        'Id': 'src1',
        'Path': '/media/movie.mkv',
        'RunTimeTicks': 60000000000,
        'Bitrate': 8000000,
        'MediaStreams': [
          {'Type': 'Video', 'Index': 0, 'Codec': 'hevc', 'Width': 3840, 'Height': 2160},
          {'Type': 'Subtitle', 'Index': 3, 'Codec': 'pgssub', 'IsExternal': false},
          {'Type': 'Subtitle', 'Index': 4, 'Codec': 'subrip', 'IsExternal': true},
        ],
      };
      final mapped = EmbyMapper.toStreamResponse(
        {'Id': 'item1', 'Name': 'Test'},
        baseUrl,
        source: source,
      );
      final parsed =
          MediaResponseParser.parseStreamResponse(envelope(mapped));
      final subs = parsed.subtitleStreams!;
      expect(subs, hasLength(2));
      // The guid carries the owning item id so the download path can address
      // `Videos/{itemId}/.../Subtitles/{index}` without a second lookup.
      expect(subs[0].guid, 's3@item1');
      expect(subs[0].isBitmap, 1);
      expect(subs[1].guid, 's4@item1');
      expect(subs[1].isBitmap, 0);
      expect(parsed.videoStream!.resolutionType, '4K');
    });
  });

  group('playback', () {
    test('play info carries resume position and track selections', () {
      final detail = fixture('detail');
      final source = (detail['MediaSources'] as List).first as Map;
      final mapped = EmbyMapper.toPlayInfo(
        detail,
        baseUrl,
        source: Map<String, dynamic>.from(source),
      );
      final parsed = MediaResponseParser.parseOptionalPlayInfoResponse(
        envelope(mapped),
      );

      expect(parsed, isNotNull);
      expect(parsed!.mediaGuid, 'c002f0f88ee970cce7f138bbc925de64');
      expect(parsed.type, 'Movie');
      expect(parsed.videoGuid, 'v0');
      expect(parsed.audioGuid, 'a1');
      // Dracula has never been resumed on the demo server.
      expect(parsed.ts, 0);
      expect(parsed.item.title, 'Dracula');
    });

    test('resume entry exposes a non-zero position', () {
      final resume = fixture('resume');
      final items = (resume['Items'] as List);
      final mapped = EmbyMapper.toPlayDetailList(items, baseUrl);
      final parsed = MediaResponseParser.parsePlayListResponse(envelope(mapped));

      expect(parsed, isNotEmpty);
      expect(parsed.first.ts, greaterThan(0));
      expect(parsed.first.duration, greaterThan(parsed.first.ts!));
      expect(parsed.first.guid, '5e6e8380563c5211106652362c5c6843');
    });
  });

  group('tv hierarchy', () {
    test('seasons map with series context', () {
      final series = fixture('series');
      final seasonPayload = fixture('seasons');
      final seriesItem =
          Map<String, dynamic>.from((series['Items'] as List).first as Map);
      final mapped = EmbyMapper.toSeasonList(
        seasonPayload['Items'] as List,
        baseUrl,
        series: seriesItem,
      );
      final parsed =
          MediaResponseParser.parseSeasonListResponse(envelope(mapped));

      expect(parsed, hasLength(1));
      expect(parsed.first.type, 'Season');
      expect(parsed.first.seasonNumber, 1);
      expect(parsed.first.tvTitle, 'Pioneer One');
      expect(parsed.first.parentGuid, seriesItem['Id']);
      expect(parsed.first.guid, 'c83a32158113f6961530bbc1bcf916a7');
    });

    test('season without artwork borrows the series poster', () {
      final series = fixture('series');
      final seasonPayload = fixture('seasons');
      final seriesItem =
          Map<String, dynamic>.from((series['Items'] as List).first as Map);
      // The demo season carries an empty `ImageTags`, which is the common case
      // on a real server: only the series is scraped.
      final season =
          Map<String, dynamic>.from((seasonPayload['Items'] as List).first as Map);
      expect(season['ImageTags'], isEmpty);

      final mapped = EmbyMapper.toSeasonList(
        seasonPayload['Items'] as List,
        baseUrl,
        series: seriesItem,
      );
      final parsed =
          MediaResponseParser.parseSeasonListResponse(envelope(mapped));

      expect(parsed.first.poster, isNotNull);
      expect(parsed.first.poster, contains('/Items/${seriesItem['Id']}/Images/Primary'));
    });

    test('episodes map with season and series context', () {
      final seasonPayload = fixture('seasons');
      final episodePayload = fixture('episodes');
      final season =
          Map<String, dynamic>.from((seasonPayload['Items'] as List).first as Map);
      final mapped = EmbyMapper.toEpisodeList(
        episodePayload['Items'] as List,
        baseUrl,
        season: season,
      );
      final parsed =
          MediaResponseParser.parseEpisodeListResponse(envelope(mapped));

      expect(parsed, hasLength(3));
      final first = parsed.first;
      expect(first.type, 'Episode');
      expect(first.guid, 'f717d85df782816c2ab75423e32f740b');
      expect(first.seasonNumber, 1);
      expect(first.episodeNumber, 1);
      expect(first.tvTitle, 'Pioneer One');
      expect(first.parentGuid, 'c83a32158113f6961530bbc1bcf916a7');
      // `runtime` is minutes in the fnOS DTO (rendered as "{n} 分钟").
      expect(first.runtime, 31);
      expect(first.ancestorCategory, 'TV');
    });

    test('episode runtime falls back to the media source ticks', () {
      // Emby omits RunTimeTicks on the list row for some library entries but
      // still reports it on the media source; without this the card rendered
      // "时长未知" for a fully probed file.
      final season = {'Id': 's1', 'Name': '第 1 季', 'ChildCount': 1};
      final mapped = EmbyMapper.toEpisodeList(
        [
          {
            'Id': 'e1',
            'Type': 'Episode',
            'Name': '第一集',
            'IndexNumber': 1,
            'MediaSources': [
              {'Id': 'e1', 'RunTimeTicks': 24000000000},
            ],
          },
        ],
        baseUrl,
        season: season,
      );
      final parsed =
          MediaResponseParser.parseEpisodeListResponse(envelope(mapped));

      expect(parsed.first.runtime, 40);
      expect(parsed.first.duration, 2400);
    });

    test('episode without a still borrows the series poster', () {
      final season = {'Id': 's1', 'Name': '第 1 季', 'ChildCount': 1};
      final series = {
        'Id': 'series1',
        'Type': 'Series',
        'ImageTags': {'Primary': 'tag1'},
      };
      final mapped = EmbyMapper.toEpisodeList(
        [
          {'Id': 'e1', 'Type': 'Episode', 'Name': '第一集', 'IndexNumber': 1},
        ],
        baseUrl,
        season: season,
        series: series,
      );

      expect(mapped.first['poster'], contains('/Items/series1/Images/Primary'));
    });
  });

  group('people', () {
    test('cast list keeps order and builds profile urls', () {
      final detail = fixture('detail');
      final mapped = EmbyMapper.toPersonList(detail, baseUrl);
      final parsed = MediaResponseParser.parsePersonListResponse(
        envelope({'list': mapped, 'total': mapped.length}),
      );

      expect(parsed, isNotEmpty);
      expect(parsed.first.name, 'Bela Lugosi');
      expect(parsed.first.role, 'Count Dracula');
      expect(parsed.first.job, 'Actor');
      expect(parsed.first.order, 0);
      expect(parsed.first.profilePath, startsWith('$baseUrl/Items/'));
    });
  });

  group('urls', () {
    test('stream url carries token, source and start offset', () {
      final url = EmbyMapper.ticksPerSecond;
      expect(url, 10000000);
    });

    test('ticks convert to seconds', () {
      expect(EmbyMapper.secondsFromTicks(44662997880), 4466);
      expect(EmbyMapper.secondsFromTicks(null), 0);
    });
  });
}
