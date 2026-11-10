import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/network/api_result.dart';
import '../../../../data/backends/media_backend.dart';
import '../../../../data/models/episode_list_response.dart';
import '../../../../data/models/media_request_models.dart';
import '../../../../data/models/movie_detail_models.dart';
import '../../../../data/models/player_models.dart';
import '../../../../providers/providers.dart';

class PlayerService {
  final MediaBackend _backend;

  PlayerService(this._backend);

  // Get play info for a media item.
  Future<PlayInfoResponse> getPlayInfo(String guid, {String? mediaGuid}) async {
    final result = await _backend.getPlayerPlayInfo(
      PlayInfoRequest(itemGuid: guid, mediaGuid: mediaGuid),
    );
    return _unwrapNullableResult(
      result,
      fallbackMessage: 'Missing play info response',
    );
  }

  // Get stream info for a media guid.
  Future<StreamResponse> getStreamInfo(
    String mediaGuid, {
    String? ip,
    int level = 1,
  }) async {
    final request = StreamRequest(
      mediaGuid: mediaGuid,
      ip: ip,
      level: level,
      header: Header(
        userAgent: [AppConstants.userAgent],
      ),
    );
    final result = await _backend.getStreamInfo(request);
    return _unwrapResult(result);
  }

  // Play video with specified parameters.
  Future<PlayPlayResponse> playVideo(PlayPlayRequest request) async {
    final result = await _backend.playVideo(request);
    return _unwrapResult(result);
  }

  // Download external subtitle content for media_kit rendering.
  Future<String> downloadExternalSubtitle(String guid) async {
    final result = await _backend.downloadExternalSubtitle(guid);
    return _unwrapResult(result);
  }

  // Get episode list for the current season or series parent.
  Future<List<EpisodeListResponse>> getEpisodeList(String guid) async {
    final result = await _backend.getEpisodeList(guid);
    return _unwrapResult(result);
  }

  // Update play record (progress).
  Future<void> updatePlayRecord(PlayRecordRequest request) async {
    final result = await _backend.updatePlayRecord(request);
    _unwrapResult(result);
  }

  // Update live-channel (IPTV) play record.
  Future<void> updateLivePlayRecord(LivePlayRecordRequest request) async {
    final result = await _backend.updateLivePlayRecord(request);
    _unwrapResult(result);
  }

  // Set skip config for intro and outro.
  Future<void> setSkipConfig({
    required String guid,
    required int skipOpening,
    required int skipEnding,
  }) async {
    final request = SetConfigByItemRequest(
      guid: guid,
      skipOpening: skipOpening,
      skipEnding: skipEnding,
    );
    final result = await _backend.setSkipConfig(request);
    _unwrapResult(result);
  }

  // Build HLS play URL.
  String buildHlsPlayUrl(String playLink) {
    return playLink;
  }

  // Get IP hash from source name.
  String getIpHash(String sourceName) {
    return md5.convert(utf8.encode(sourceName)).toString();
  }

  T _unwrapResult<T>(
    ApiResult<T> result, {
    String? fallbackMessage,
  }) {
    return result.when(
      success: (data) {
        if (data == null) {
          throw Exception(fallbackMessage ?? 'Empty response data');
        }
        return data;
      },
      failure: (failure) => throw Exception(failure.displayMessage.isNotEmpty
          ? failure.displayMessage
          : failure.message),
    );
  }

  T _unwrapNullableResult<T>(
    ApiResult<T?> result, {
    String? fallbackMessage,
  }) {
    return result.when(
      success: (data) {
        if (data == null) {
          throw Exception(fallbackMessage ?? 'Empty response data');
        }
        return data;
      },
      failure: (failure) => throw Exception(failure.displayMessage.isNotEmpty
          ? failure.displayMessage
          : failure.message),
    );
  }
}

final playerServiceProvider = Provider<PlayerService>((ref) {
  final backend = ref.watch(mediaBackendProvider);
  return PlayerService(backend);
});
