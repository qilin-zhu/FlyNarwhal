// Guards the login header handshake: Jellyfin parses `DeviceId` out of the
// `Authorization` header and rejects an empty value with 400 before it even
// looks at the credentials. The player only persists its device id once it has
// started, so a fresh install used to fail its first Emby login.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fly_narwhal/data/backends/emby/emby_api.dart';

/// Captures the header the client actually sends, then answers with a minimal
/// successful login + server-info payload.
class _HeaderCapturingAdapter implements HttpClientAdapter {
  _HeaderCapturingAdapter();

  final List<String> authorizations = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authorizations.add(options.headers['Authorization']?.toString() ?? '');
    final body = options.path.endsWith('Users/AuthenticateByName')
        ? jsonEncode(<String, dynamic>{
            'User': <String, dynamic>{
              'Id': 'user-1',
              'Name': 'demo',
            },
            'AccessToken': 'token-1',
            'ServerId': 'server-1',
          })
        : jsonEncode(<String, dynamic>{
            'ServerName': 'Demo',
            'ProductName': 'Jellyfin Server',
            'Version': '10.9.0',
          });
    return ResponseBody.fromString(
      body,
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
  test('an empty device id is replaced before the login header is built',
      () async {
    final adapter = _HeaderCapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    final result = await EmbyApi.authenticate(
      baseUrl: 'http://127.0.0.1:8096',
      username: 'demo',
      password: '',
      deviceId: '',
      dio: dio,
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.authorizations, isNotEmpty);
    final header = adapter.authorizations.first;
    final match = RegExp(r'DeviceId="([^"]*)"').firstMatch(header);
    expect(match, isNotNull, reason: 'header was: $header');
    expect(match!.group(1), isNotEmpty);
  });

  test('a stored device id is forwarded verbatim', () async {
    final adapter = _HeaderCapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    await EmbyApi.authenticate(
      baseUrl: 'http://127.0.0.1:8096',
      username: 'demo',
      password: '',
      deviceId: 'mtest-device',
      dio: dio,
    );

    expect(
      adapter.authorizations.first,
      contains('DeviceId="mtest-device"'),
    );
  });
}
