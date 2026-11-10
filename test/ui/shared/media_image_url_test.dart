import 'package:fly_narwhal/ui/shared/common/fn_cached_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveMediaImageUrl', () {
    test('passes absolute urls through untouched', () {
      // The Emby mapper already emits absolute URLs. Prefixing them produced
      // `/v/api/v1/sys/img/Items/...`, which 404'd on every image.
      const emby =
          'http://nas:8096/Items/abc/Images/Backdrop?maxWidth=1920&tag=t1';
      expect(resolveMediaImageUrl('http://nas:8096', emby), emby);
      expect(resolveMediaImageUrl('http://nas:8096', emby, width: 400), emby);
      expect(
        resolveMediaImageUrl(null, 'https://cdn.test/a.jpg'),
        'https://cdn.test/a.jpg',
      );
    });

    test('routes fnOS relative paths through the image proxy', () {
      expect(
        resolveMediaImageUrl('http://nas:5666', '/media/poster/1.jpg'),
        'http://nas:5666/v/api/v1/sys/img/media/poster/1.jpg',
      );
      expect(
        resolveMediaImageUrl('http://nas:5666', 'media/poster/1.jpg'),
        'http://nas:5666/v/api/v1/sys/img/media/poster/1.jpg',
      );
      expect(
        resolveMediaImageUrl('http://nas:5666/', '/media/poster/1.jpg'),
        'http://nas:5666/v/api/v1/sys/img/media/poster/1.jpg',
      );
    });

    test('appends the fnOS resize hint only to proxy urls', () {
      expect(
        resolveMediaImageUrl('http://nas:5666', '/media/poster/1.jpg',
            width: 400),
        'http://nas:5666/v/api/v1/sys/img/media/poster/1.jpg?w=400',
      );
      // A path that already carries a query is left alone rather than being
      // given a second `?`.
      expect(
        resolveMediaImageUrl('http://nas:5666', '/media/poster/1.jpg?v=2',
            width: 400),
        'http://nas:5666/v/api/v1/sys/img/media/poster/1.jpg?v=2',
      );
      expect(
        resolveMediaImageUrl('http://nas:5666', '/media/poster/1.jpg'),
        'http://nas:5666/v/api/v1/sys/img/media/poster/1.jpg',
      );
    });

    test('does not double-prefix an already proxied path', () {
      expect(
        resolveMediaImageUrl('http://nas:5666', '/v/api/v1/sys/img/a/1.jpg'),
        'http://nas:5666/v/api/v1/sys/img/a/1.jpg',
      );
      expect(
        resolveMediaImageUrl('http://nas:5666', 'v/api/v1/sys/img/a/1.jpg'),
        'http://nas:5666/v/api/v1/sys/img/a/1.jpg',
      );
    });

    test('returns empty for missing input', () {
      expect(resolveMediaImageUrl('http://nas:5666', ''), '');
      expect(resolveMediaImageUrl('http://nas:5666', '   '), '');
      expect(resolveMediaImageUrl(null, '/media/poster/1.jpg'), '');
      expect(resolveMediaImageUrl('', '/media/poster/1.jpg'), '');
    });
  });
}
