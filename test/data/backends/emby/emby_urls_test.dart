// Guards the two player-URL shapes that silently broke direct play against a
// live Emby 4.9.0.46 server:
//
// 1. `MediaSourceId` must be Emby's `MediaSources[].Id` (`mediasource_<id>`),
//    not the item id. With the item id Emby resolves no media source and
//    answers `400 Value cannot be null. (Parameter 'mediaSource')`, mpv never
//    opens, the 30 s verification times out and playback drops to a transcode.
// 2. Emby 4.9 honours `?api_key=` and 401s on `?ApiKey=`, the exact inverse of
//    Jellyfin 10.10+. mpv sends the URL bare (no Authorization header across
//    range requests), so only emitting one spelling breaks one server family.
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_narwhal/data/backends/emby/emby_urls.dart';

void main() {
  const base = 'http://nas.local:8096';
  const token = 'secret-token';

  group('direct stream URL', () {
    test('carries both token spellings so Emby and Jellyfin authenticate', () {
      final url = EmbyUrls.stream(base, '49175', accessToken: token);
      expect(url, contains('ApiKey=$token'));
      expect(url, contains('api_key=$token'));
    });

    test('is static-stream shaped and absolute', () {
      final url = EmbyUrls.stream(base, '49175', accessToken: token);
      expect(url, startsWith('$base/Videos/49175/stream?'));
      expect(url, contains('static=true'));
    });

    test('uses the media source id when one is supplied', () {
      final url = EmbyUrls.stream(
        base,
        '49175',
        accessToken: token,
        mediaSourceId: 'mediasource_49175',
      );
      expect(url, contains('MediaSourceId=mediasource_49175'));
      expect(url, isNot(contains('MediaSourceId=49175&')));
    });

    test('falls back to the item id when no source id is known', () {
      final url = EmbyUrls.stream(base, '49175', accessToken: token);
      expect(url, contains('MediaSourceId=49175'));
    });

    test('normalises a trailing slash on the base url', () {
      final url = EmbyUrls.stream('$base/', '7', accessToken: token);
      expect(url, startsWith('$base/Videos/7/stream?'));
    });

    test('adds StartTimeTicks only for a positive offset', () {
      expect(
        EmbyUrls.stream(base, '7', accessToken: token, startTicks: 0),
        isNot(contains('StartTimeTicks')),
      );
      expect(
        EmbyUrls.stream(base, '7', accessToken: token, startTicks: 120000000),
        contains('StartTimeTicks=120000000'),
      );
    });
  });

  group('HLS transcode URL', () {
    const playSessionId = 'flynarwhal1700000000000000';

    test('carries both token spellings', () {
      final url = EmbyUrls.transcode(
        base,
        '49175',
        accessToken: token,
        playSessionId: playSessionId,
      );
      expect(url, contains('ApiKey=$token'));
      expect(url, contains('api_key=$token'));
    });

    test('targets master.m3u8 under the item id', () {
      final url = EmbyUrls.transcode(
        base,
        '49175',
        accessToken: token,
        playSessionId: playSessionId,
        mediaSourceId: 'mediasource_49175',
      );
      expect(url, startsWith('$base/Videos/49175/master.m3u8?'));
      expect(url, contains('MediaSourceId=mediasource_49175'));
      expect(url, contains('VideoCodec=h264'));
      expect(url, contains('SegmentContainer=mp4'));
    });

    test('honours an explicit encoder and bitrate', () {
      final url = EmbyUrls.transcode(
        base,
        '7',
        accessToken: token,
        playSessionId: playSessionId,
        videoCodec: 'hevc',
        videoBitrate: 8000000,
      );
      expect(url, contains('VideoCodec=hevc'));
      expect(url, contains('VideoBitrate=8000000'));
    });

    // Emby copies PlaySessionId into every segment URI of the playlist it
    // returns. An empty value makes each segment request fail with
    // `400 Value cannot be null. (Parameter 'key')`, so the query must always
    // carry a non-empty one.
    test('always sends a non-empty PlaySessionId', () {
      final url = EmbyUrls.transcode(
        base,
        '49175',
        accessToken: token,
        playSessionId: playSessionId,
      );
      expect(url, contains('PlaySessionId=$playSessionId'));
      expect(url, isNot(contains('PlaySessionId=&')));
    });
  });

  group('image URL', () {
    test('unauthenticated poster URL keeps its query compact', () {
      final url = EmbyUrls.image(base, '49175', maxWidth: 400, tag: 'abc');
      expect(url, startsWith('$base/Items/49175/Images/Primary?'));
      expect(url, contains('maxWidth=400'));
      expect(url, contains('tag=abc'));
      expect(url, contains('quality=90'));
    });
  });
}
