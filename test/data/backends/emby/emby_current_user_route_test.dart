// Guards the user-profile route: Emby parses `/Users/{id}` as a Guid, so the
// Jellyfin convenience route `/Users/Me` 500s there with
// "Unrecognized Guid format." The backend must resolve the profile through the
// authenticated user id instead; that failure used to hit the session
// invalidation path in UserInfoNotifier and bounce the user back to login
// right after a successful sign-in.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_narwhal/data/backends/emby/emby_api.dart';
import 'package:fly_narwhal/data/backends/emby/emby_media_backend.dart';

class _PathCapturingAdapter implements HttpClientAdapter {
  _PathCapturingAdapter(this.userId);

  final String userId;

  final List<String> paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.toString().replaceFirst(
          RegExp('^https?://[^/]+'),
          '',
        );
    paths.add(path);
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'Id': userId,
        'Name': 'demo',
        'Policy': <String, dynamic>{'IsAdministrator': false},
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('getCurrentUser resolves the profile through /Users/{userId}', () async {
    final adapter = _PathCapturingAdapter('92dff8e8aaaa4b1af8f29cba2d0e5c461');
    final api = EmbyApi(
      credentials: EmbyCredentials(
        baseUrl: 'http://127.0.0.1:8894',
        accessToken: 'token-1',
        userId: '92dff8e8aaaa4b1af8f29cba2d0e5c461',
        deviceId: 'device-1',
      ),
      dio: Dio()..httpClientAdapter = adapter,
    );
    final backend = EmbyMediaBackend(
      api: api,
      initialBaseUrl: 'http://127.0.0.1:8894',
    );

    final result = await backend.getCurrentUser();

    expect(result.failureOrNull?.message, isNull);
    expect(result.getOrThrow().username, 'demo');
    expect(
      adapter.paths.any((p) => p.contains('/Users/Me')),
      isFalse,
      reason: 'Emby 500s on /Users/Me (Guid parse failure)');
    expect(
      adapter.paths.any((p) =>
          p.contains('/Users/92dff8e8aaaa4b1af8f29cba2d0e5c461') &&
          !p.contains('/Users/Me')),
      isTrue,
      reason: 'the profile must come from the authenticated user id');
  });
}
