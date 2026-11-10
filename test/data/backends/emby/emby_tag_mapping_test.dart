// Covers the two data shapes that only appear when an Emby server drives the
// fnOS UI: the folder breadcrumb/title trail and the tag metadata that Emby
// does not model directly.
import 'package:fly_narwhal/data/backends/emby/emby_mapper.dart';
import 'package:fly_narwhal/data/backends/emby/emby_tags.dart';
import 'package:flutter_test/flutter_test.dart';

const String baseUrl = 'https://demo.jellyfin.org/stable';

/// The shape `/Items/{id}/Ancestors` returns: nearest ancestor first, ending
/// with the synthetic user root.
const List<Map<String, dynamic>> ancestors = <Map<String, dynamic>>[
  <String, dynamic>{
    'Id': 'f137a2dd21bbc1b99aa5c0f6bf02a805',
    'Name': 'Movies',
    'Type': 'CollectionFolder',
  },
  <String, dynamic>{
    'Id': 'e9d5075a97c24bd4864a1ae1f5e9e0a1',
    'Name': 'Media Folders',
    'Type': 'UserRootFolder',
  },
];

void main() {
  group('folder trail', () {
    test('library name becomes the title root and the folder the last crumb', () {
      final trail = EmbyMapper.folderTrail(
        ancestors,
        folderId: '01fff54ce70b1cbb26d52fca759c0e01',
        folderName: 'Blender Foundation',
      );

      expect(trail['library_guid'], 'f137a2dd21bbc1b99aa5c0f6bf02a805');
      expect(trail['mdb_name'], 'Movies');

      final jumpList = trail['jump_list'] as List<Map<String, dynamic>>;
      // Root crumb carries an empty guid so its click falls back to /library.
      expect(jumpList.first['fv_guid'], '');
      expect(jumpList.first['base_name'], 'Movies');
      // The last entry is what the folder screen renders as the page title.
      expect(jumpList.last['base_name'], 'Blender Foundation');
      expect(jumpList.last['fv_guid'], 'fv_01fff54ce70b1cbb26d52fca759c0e01');
    });

    test('intermediate folders are kept and ordered outward-in', () {
      final nested = <Map<String, dynamic>>[
        <String, dynamic>{
          'Id': 'season-folder',
          'Name': 'Season 1',
          'Type': 'Folder',
        },
        ...ancestors,
      ];
      final trail = EmbyMapper.folderTrail(
        nested,
        folderId: 'episode-folder',
        folderName: 'Disc 1',
      );

      final names = (trail['jump_list'] as List<Map<String, dynamic>>)
          .map((entry) => entry['base_name'])
          .toList();
      expect(names, <String>['Movies', 'Season 1', 'Disc 1']);
    });

    test('an ancestor-less folder still yields a usable trail', () {
      final trail = EmbyMapper.folderTrail(
        const <dynamic>[],
        folderId: 'orphan',
        folderName: 'Loose Files',
      );

      expect(trail['mdb_name'], 'Loose Files');
      expect(trail['library_guid'], '');
      final jumpList = trail['jump_list'] as List<Map<String, dynamic>>;
      expect(jumpList, hasLength(2));
      expect(jumpList.last['base_name'], 'Loose Files');
    });
  });

  group('tag metadata', () {
    test('years collapse into decade buckets, newest first', () {
      expect(
        EmbyTags.decadesFromYears(<int>[2013, 2016, 1999, 1903]),
        <String>['2010s', '1990s', '1900s'],
      );
      expect(EmbyTags.decadesFromYears(const <int>[]), isEmpty);
    });

    test('decade labels round-trip into a Jellyfin Years filter', () {
      expect(
        EmbyTags.yearsFilter('2010s'),
        '2010,2011,2012,2013,2014,2015,2016,2017,2018,2019',
      );
      expect(EmbyTags.yearsFilter('2016'), '2016');
      expect(EmbyTags.yearsFilter('Recent'), '${DateTime.now().year}');
      // "Others" has no Jellyfin equivalent; dropping it beats widening it.
      expect(EmbyTags.yearsFilter('Others'), isNull);
      expect(EmbyTags.yearsFilter(null), isNull);
    });

    test('watched flag maps to the Jellyfin filter token', () {
      expect(EmbyTags.watchedFilter('1'), 'IsPlayed');
      expect(EmbyTags.watchedFilter('0'), 'IsUnplayed');
      expect(EmbyTags.watchedFilter(null), isNull);
    });

    test('resolution buckets map to height windows', () {
      expect(EmbyTags.heightRange('4K'), (2000, null));
      expect(EmbyTags.heightRange('1080p'), (1000, 1999));
      expect(EmbyTags.heightRange('720p'), (700, 999));
      expect(EmbyTags.heightRange('nonsense'), isNull);
    });

    test('genre ids are stable per name', () {
      final first = EmbyGenreIndex.idFor('Animation');
      final second = EmbyGenreIndex.idFor('Comedy');
      expect(EmbyGenreIndex.idFor('Animation'), first);
      expect(EmbyGenreIndex.idFor('Comedy'), second);
      expect(EmbyGenreIndex.nameOf(first), 'Animation');
      expect(EmbyGenreIndex.idsFor(<String>['Comedy', '']), <int>[second]);
      expect(EmbyGenreIndex.nameOf(null), isNull);
    });

    test('colour range and audio profile derive from stream fields', () {
      expect(
        EmbyMapper.colorRangeOf(<String, dynamic>{'VideoRangeType': 'SDR'}),
        'SDR',
      );
      expect(
        EmbyMapper.colorRangeOf(
          <String, dynamic>{'VideoRangeType': 'HDR10'},
        ),
        'HDR',
      );
      expect(
        EmbyMapper.colorRangeOf(
          <String, dynamic>{'VideoRangeType': 'DOVIProfile5'},
        ),
        'DolbyVision',
      );
      expect(EmbyMapper.colorRangeOf(const <String, dynamic>{}), isNull);
      expect(
        EmbyMapper.audioProfileOf(
          <String, dynamic>{'Codec': 'eac3', 'Channels': 6},
        ),
        'DolbySurround',
      );
      expect(
        EmbyMapper.audioProfileOf(
          <String, dynamic>{
            'Codec': 'truehd',
            'Channels': 8,
            'DisplayTitle': 'TrueHD Atmos',
          },
        ),
        'DolbyAtmos',
      );
      expect(
        EmbyMapper.audioProfileOf(
          <String, dynamic>{'Codec': 'aac', 'Channels': 2},
        ),
        'Stereo',
      );
      expect(
        EmbyMapper.audioProfileOf(
          <String, dynamic>{'Codec': 'aac', 'Channels': 1},
        ),
        'Others',
      );
    });

    group('dynamic range detection across server dialects', () {
      // Emby 4.9 (verified against 4.9.0.46) sends VideoRange +
      // ExtendedVideoType/SubType and NEVER VideoRangeType. Reading only
      // VideoRangeType made every HDR/DoVi stream look like SDR, so the
      // player opened the raw direct-play link and mpv rendered BT.2020 PQ
      // content as BT.709 — the washed-out, wrong-colour report.
      test('Emby 4.9 HDR10 payload is recognised as HDR', () {
        final range = EmbyMapper.videoRangeOf(<String, dynamic>{
          'Codec': 'hevc',
          'Profile': 'Main 10',
          'BitDepth': 10,
          'VideoRange': 'HDR 10',
          'ExtendedVideoType': 'Hdr10',
          'ExtendedVideoSubType': 'Hdr10',
          'ColorTransfer': 'smpte2084',
          'ColorPrimaries': 'bt2020',
          'ColorSpace': 'bt2020nc',
        });
        expect(range, isNotNull);
        expect(range!.label, 'HDR');
        expect(range.isSdr, isFalse);
        expect(range.dvProfile, 0);
        expect(range.isDolbyVision, isFalse);
      });

      test('Emby 4.9 HLG payload is recognised as HDR', () {
        final range = EmbyMapper.videoRangeOf(<String, dynamic>{
          'Codec': 'h264',
          'VideoRange': 'HLG',
          'ExtendedVideoType': 'HyperLogGamma',
          'ExtendedVideoSubType': 'HyperLogGamma',
          'ColorTransfer': 'arib-std-b67',
          'ColorPrimaries': 'bt2020',
        });
        expect(range!.label, 'HDR');
        expect(range.isSdr, isFalse);
      });

      test('Emby 4.9 Dolby Vision payload yields the right profile', () {
        // Every DoVi subtype observed on a live Emby 4.9 library.
        const expected = <String, int>{
          'DoviProfile50': 5,
          'DoviProfile76': 7,
          'DoviProfile81': 8,
          'DoviProfile84': 8,
        };
        for (final entry in expected.entries) {
          final range = EmbyMapper.videoRangeOf(<String, dynamic>{
            'Codec': 'hevc',
            'BitDepth': 10,
            'VideoRange': 'DolbyVision',
            'ExtendedVideoType': 'DolbyVision',
            'ExtendedVideoSubType': entry.key,
          });
          expect(range, isNotNull, reason: entry.key);
          expect(range!.label, 'DolbyVision', reason: entry.key);
          expect(range.dvProfile, entry.value, reason: entry.key);
          expect(range.isDolbyVision, isTrue, reason: entry.key);
        }
      });

      test('profile 5 drives the HLS-only gate', () {
        final p5 = EmbyMapper.videoRangeOf(<String, dynamic>{
          'VideoRange': 'DolbyVision',
          'ExtendedVideoSubType': 'DoviProfile50',
        });
        expect(p5!.dvProfile, 5);
        // 8.1/8.4 still carry an HDR10 base layer and are reported as 8.
        final p81 = EmbyMapper.videoRangeOf(<String, dynamic>{
          'VideoRange': 'DolbyVision',
          'ExtendedVideoSubType': 'DoviProfile81',
        });
        expect(p81!.dvProfile, 8);
      });

      test('plain SDR stream stays SDR', () {
        expect(
          EmbyMapper
              .videoRangeOf(<String, dynamic>{
                'Codec': 'h264',
                'VideoRange': 'SDR',
                'ColorTransfer': 'bt709',
                'ColorPrimaries': 'bt709',
              })!
              .isSdr,
          isTrue,
        );
        // No range metadata at all is reported as unknown rather than being
        // guessed into HDR (the caller falls back to the SDR default).
        expect(EmbyMapper.videoRangeOf(const <String, dynamic>{}), isNull);
      });

      test('PQ transfer alone is enough to spot HDR', () {
        // Some library scans drop VideoRange but keep the transfer function.
        final range = EmbyMapper.videoRangeOf(<String, dynamic>{
          'ColorTransfer': 'smpte2084',
          'ColorPrimaries': 'bt2020',
        });
        expect(range!.label, 'HDR');
      });

      test('colour range bucket follows the detected range', () {
        expect(
          EmbyMapper.colorRangeOf(<String, dynamic>{
            'VideoRange': 'HDR 10',
            'ExtendedVideoType': 'Hdr10',
          }),
          'HDR',
        );
        expect(
          EmbyMapper.colorRangeOf(<String, dynamic>{
            'VideoRange': 'DolbyVision',
            'ExtendedVideoSubType': 'DoviProfile50',
          }),
          'DolbyVision',
        );
        expect(
          EmbyMapper.colorRangeOf(<String, dynamic>{
            'VideoRange': 'SDR',
            'ColorTransfer': 'bt709',
          }),
          'SDR',
        );
      });

      test('the mapped video stream carries the profile and range', () {
        final payload = EmbyMapper.toStreamResponse(
          <String, dynamic>{'Id': '1', 'Name': 'ep'},
          'http://host:8096',
          source: <String, dynamic>{
            'Id': 'mediasource_1',
            'MediaStreams': <Map<String, dynamic>>[
              <String, dynamic>{
                'Type': 'Video',
                'Index': 0,
                'Codec': 'hevc',
                'Width': 3840,
                'Height': 2160,
                'BitRate': 20000000,
                'VideoRange': 'DolbyVision',
                'ExtendedVideoType': 'DolbyVision',
                'ExtendedVideoSubType': 'DoviProfile50',
                'BitDepth': 10,
              },
            ],
          },
        );
        final video = payload['video_stream'] as Map<String, dynamic>;
        expect(video['color_range_type'], 'DolbyVision');
        expect(video['dv_profile'], 5);
        expect(video['resolution_type'], '4K');
      });
    });

    test('unknown height stays unknown instead of guessing 1080p', () {
      expect(EmbyMapper.resolutionLabelFromHeight(2160), '4K');
      expect(EmbyMapper.resolutionLabelFromHeight(1080), '1080p');
      expect(EmbyMapper.resolutionLabelFromHeight(720), '720p');
      expect(EmbyMapper.resolutionLabelFromHeight(480), '480p');
      expect(EmbyMapper.resolutionLabelFromHeight(0), isNull);
    });
  });
}
