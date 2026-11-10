import 'package:dio/dio.dart';

import '../../../core/error/error_handler.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/ssl/ssl_trust_configurator.dart';
import '../../../core/network/ssl/ssl_trust_manager.dart';
import 'emby_urls.dart';

/// Credentials for an Emby-family server (Emby, Jellyfin).
class EmbyCredentials {
  const EmbyCredentials({
    required this.baseUrl,
    required this.accessToken,
    required this.userId,
    required this.deviceId,
  });

  final String baseUrl;
  final String accessToken;
  final String userId;
  final String deviceId;

  EmbyCredentials copyWith({
    String? baseUrl,
    String? accessToken,
    String? userId,
    String? deviceId,
  }) {
    return EmbyCredentials(
      baseUrl: baseUrl ?? this.baseUrl,
      accessToken: accessToken ?? this.accessToken,
      userId: userId ?? this.userId,
      deviceId: deviceId ?? this.deviceId,
    );
  }
}

/// Result of a successful `Users/AuthenticateByName` call.
class EmbyAuthResult {
  const EmbyAuthResult({
    required this.userId,
    required this.accessToken,
    required this.userName,
    required this.serverId,
    required this.serverName,
    required this.productName,
    required this.serverVersion,
  });

  final String userId;
  final String accessToken;
  final String userName;
  final String serverId;
  final String serverName;
  final String productName;
  final String serverVersion;

  /// Jellyfin identifies itself with `ProductName == "Jellyfin Server"`.
  bool get isJellyfin => productName.toLowerCase().contains('jellyfin');
}

/// Thin REST client for the Emby / Jellyfin API.
///
/// Deliberately independent of the fnOS `DioClient`: that client injects the
/// `Authx` signature and the `x-trim-client` impersonation headers, which an
/// Emby server rejects. This client only sends the token header Emby expects.
class EmbyApi {
  EmbyApi({
    required EmbyCredentials credentials,
    Dio? dio,
    SslTrustManager? sslTrustManager,
    Future<void> Function(SslTrustEntry entry)? persistSslTrustEntry,
  })  : _credentials = credentials,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              responseType: ResponseType.json,
              followRedirects: true,
            )) {
    if (dio == null) {
      configureSslTrust(
        _dio,
        trustManager: sslTrustManager,
        persistEntry: persistSslTrustEntry,
      );
    }
  }

  static const String clientName = 'FlyNarwhal';
  static const String clientVersion = '2.4.0';

  /// Device id used when the caller has none stored yet. Emby only uses it to
  /// group sessions, so a random per-login id is enough to satisfy the header
  /// validation; the player persists its own stable id on first start.
  static String _fallbackDeviceId() =>
      'fly-narwhal-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

  final Dio _dio;
  EmbyCredentials _credentials;

  EmbyCredentials get credentials => _credentials;

  String get baseUrl => EmbyUrls.normalizedBase(_credentials.baseUrl);

  /// Emby accepts the token either as a query parameter or as an
  /// `Authorization: MediaBrowser Token="..."` header. The query form is used
  /// for URLs handed to the media player, which cannot attach headers to every
  /// range request reliably.
  Map<String, dynamic> _authQuery() => {
        EmbyUrls.apiKeyParam: _credentials.accessToken,
      };

  Map<String, String> get _authHeaders =>
      EmbyUrls.authorizationHeaders(_credentials.accessToken);

  EmbyApi withCredentials(EmbyCredentials credentials) {
    _credentials = credentials;
    return this;
  }

  /// GET returning the decoded JSON body.
  Future<ApiResult<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    T Function(dynamic data)? converter,
  }) {
    return _request<T>(
      () => _dio.get<dynamic>(
        '$baseUrl$path',
        queryParameters: {..._authQuery(), ...?query},
        options: Options(headers: _authHeaders),
      ),
      converter: converter,
    );
  }

  /// POST returning the decoded JSON body.
  Future<ApiResult<T>> post<T>(
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    T Function(dynamic data)? converter,
  }) {
    return _request<T>(
      () => _dio.post<dynamic>(
        '$baseUrl$path',
        queryParameters: {..._authQuery(), ...?query},
        data: body,
        options: Options(headers: _authHeaders),
      ),
      converter: converter,
    );
  }

  /// DELETE returning the decoded JSON body.
  Future<ApiResult<T>> delete<T>(
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    T Function(dynamic data)? converter,
  }) {
    return _request<T>(
      () => _dio.delete<dynamic>(
        '$baseUrl$path',
        queryParameters: {..._authQuery(), ...?query},
        data: body,
        options: Options(headers: _authHeaders),
      ),
      converter: converter,
    );
  }

  /// Fetches a raw text body (subtitles).
  Future<ApiResult<String>> getText(String path, {Map<String, dynamic>? query}) {
    return _request<String>(
      () => _dio.get<dynamic>(
        '$baseUrl$path',
        queryParameters: {..._authQuery(), ...?query},
        options: Options(
          headers: _authHeaders,
          responseType: ResponseType.plain,
        ),
      ),
      converter: (data) => data is String ? data : '$data',
    );
  }

  Future<ApiResult<T>> _request<T>(
    Future<Response<dynamic>> Function() send, {
    T Function(dynamic data)? converter,
  }) async {
    try {
      final response = await send();
      final data = response.data;
      return Success(converter != null ? converter(data) : data as T);
    } on DioException catch (e) {
      return ResultFailure(_describeError(e));
    } on FailureInfo catch (e) {
      return ResultFailure(e);
    } catch (e) {
      final failure = ErrorHandler.handle(e);
      return ResultFailure(FailureInfo(
        message: failure.message,
        code: failure.code,
        displayMessage: failure.displayMessage,
      ));
    }
  }

  /// Emby returns `{ "status": 401, "title": ... }` or a bare HTML page on
  /// failure; both are surfaced through the same message.
  FailureInfo _describeError(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    String? serverMessage;
    if (data is Map) {
      serverMessage = (data['title'] ?? data['Message'])?.toString();
    }
    final message = serverMessage?.trim().isNotEmpty == true
        ? serverMessage!.trim()
        : ErrorHandler.handleDioError(e).message;
    return FailureInfo(
      message: message,
      code: status,
      displayMessage: message,
    );
  }

  /// Resolves the public server identity without authentication.
  static Future<ApiResult<Map<String, dynamic>>> fetchPublicInfo(
    String baseUrl, {
    Dio? dio,
  }) async {
    final client = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ));
    try {
      final response = await client.get<dynamic>(
        '${EmbyUrls.normalizedBase(baseUrl)}/System/Info/Public',
      );
      final data = response.data;
      if (data is Map) {
        return Success(Map<String, dynamic>.from(data));
      }
      return ResultFailure(
        FailureInfo.fromMessage('Unexpected server info payload'),
      );
    } on DioException catch (e) {
      final failure = ErrorHandler.handleDioError(e);
      return ResultFailure(FailureInfo(
        message: failure.message,
        code: e.response?.statusCode,
        displayMessage: failure.displayMessage,
      ));
    }
  }

  /// Exchanges username + password for an access token.
  static Future<ApiResult<EmbyAuthResult>> authenticate({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceId,
    Dio? dio,
  }) async {
    final client = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 12),
        ));
    final base = EmbyUrls.normalizedBase(baseUrl);
    // Jellyfin rejects an empty DeviceId outright (the header is parsed but the
    // empty value fails its validation, surfacing as 400 before the credentials
    // are even checked). The stored fallback id is only written once the player
    // has started, so a fresh install would otherwise fail its first login.
    final resolvedDeviceId =
        deviceId.trim().isEmpty ? _fallbackDeviceId() : deviceId.trim();
    try {
      final response = await client.post<dynamic>(
        '$base/Users/AuthenticateByName',
        data: {'Username': username, 'Pw': password},
        options: Options(headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'MediaBrowser Client="$clientName", '
              'Device="Desktop", DeviceId="$resolvedDeviceId", '
              'Version="$clientVersion"',
        }),
      );
      final data = response.data;
      if (data is! Map) {
        return ResultFailure(
          FailureInfo.fromMessage('Unexpected login response payload'),
        );
      }
      final user = data['User'];
      final token = data['AccessToken'];
      if (user is! Map || token is! String || token.isEmpty) {
        return ResultFailure(
          FailureInfo.fromMessage('Login response is missing a token'),
        );
      }
      final info = await fetchPublicInfo(base, dio: client);
      final publicInfo = info.dataOrNull ?? const <String, dynamic>{};
      return Success(EmbyAuthResult(
        userId: user['Id']?.toString() ?? '',
        accessToken: token,
        userName: user['Name']?.toString() ?? username,
        serverId: data['ServerId']?.toString() ?? '',
        serverName: publicInfo['ServerName']?.toString() ?? '',
        productName: publicInfo['ProductName']?.toString() ?? '',
        serverVersion: publicInfo['Version']?.toString() ?? '',
      ));
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final failure = ErrorHandler.handleDioError(e);
      // 401 is the normal "wrong password" answer; surface it as a plain
      // message so the login screen does not report a network failure.
      final message = status == 401
          ? '用户名或密码错误 / Invalid username or password'
          : failure.message;
      return ResultFailure(FailureInfo(
        message: message,
        code: status,
        displayMessage: message,
      ));
    }
  }

  /// Absolute poster / backdrop URL.
  static String imageUrl(
    String baseUrl,
    String itemId, {
    String kind = 'Primary',
    int? maxWidth,
    String? tag,
  }) =>
      EmbyUrls.image(baseUrl, itemId,
          kind: kind, maxWidth: maxWidth, tag: tag);

  /// Absolute stream URL used by the media player.
  String streamUrl(
    String itemId, {
    String? mediaSourceId,
    int? startTicks,
  }) =>
      EmbyUrls.stream(
        _credentials.baseUrl,
        itemId,
        accessToken: _credentials.accessToken,
        mediaSourceId: mediaSourceId,
        startTicks: startTicks,
      );

  /// Absolute HLS transcode URL used when the client forces h264/SDR or picks
  /// a lower quality. Dolby Vision does not use it: Emby re-encodes DV without
  /// applying the RPU, so those sources direct play instead.
  ///
  /// [playSessionId] is required by Emby: it is echoed into every segment URI,
  /// and an empty value makes the player's segment requests fail with
  /// `400 Value cannot be null. (Parameter 'key')`.
  String transcodeUrl(
    String itemId, {
    required String playSessionId,
    String? mediaSourceId,
    String videoCodec = 'h264',
    int? videoBitrate,
    int? startTicks,
  }) =>
      EmbyUrls.transcode(
        _credentials.baseUrl,
        itemId,
        accessToken: _credentials.accessToken,
        playSessionId: playSessionId,
        mediaSourceId: mediaSourceId,
        videoCodec: videoCodec,
        videoBitrate: videoBitrate,
        startTicks: startTicks,
      );
}
