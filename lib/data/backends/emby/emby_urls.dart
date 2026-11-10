/// URL shapes and auth headers shared by the Emby client and the mapper.
///
/// Kept free of `dio` so the mapper (and its unit tests) can build absolute
/// image URLs without pulling in the HTTP layer.
class EmbyUrls {
  const EmbyUrls._();

  /// Emby ticks are 100-nanosecond units.
  static const int ticksPerSecond = 10000000;

  /// `ApiKey` is the query parameter both Emby and Jellyfin document.
  ///
  /// Do NOT replace it with `api_key`: Jellyfin 10.10+ (and 12.x) match query
  /// keys case-sensitively against a fixed name list and answer 401 for the
  /// snake_case spelling. Emby 4.9 is the mirror image — it honours `api_key`
  /// and answers 401 for `ApiKey` — so both are emitted. Emby ignores the
  /// unknown spelling and Jellyfin ignores the unknown one; sending both is
  /// the only shape that authenticates a bare `mpv` range request on either
  /// server. Verified on Emby 4.9.0.46: `ApiKey` alone → 401, `api_key` alone
  /// → 206, both → 206.
  static const String apiKeyParam = 'ApiKey';

  /// Legacy spelling still accepted by Emby; see [apiKeyParam].
  static const String legacyApiKeyParam = 'api_key';

  /// Query fragment carrying the token for player-facing URLs.
  static String _tokenQuery(String accessToken) =>
      '$apiKeyParam=$accessToken&$legacyApiKeyParam=$accessToken';

  static String normalizedBase(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  static int secondsFromTicks(Object? ticks) {
    if (ticks is num) return ticks ~/ ticksPerSecond;
    return 0;
  }

  /// Headers that authenticate a REST call.
  ///
  /// Jellyfin 10.10+ dropped the `X-Emby-Token` shortcut: it only accepts the
  /// full `Authorization: MediaBrowser Token="..."` form (or `ApiKey` in the
  /// query). Emby itself accepts both, so the widely-compatible form wins.
  static Map<String, String> authorizationHeaders(String accessToken) {
    return <String, String>{
      'Authorization': 'MediaBrowser Token="$accessToken"',
      'Accept': 'application/json',
    };
  }

  /// Absolute poster / backdrop URL. [tag] busts the client cache when the
  /// server re-scrapes an image.
  static String image(
    String baseUrl,
    String itemId, {
    String kind = 'Primary',
    int? maxWidth,
    String? tag,
  }) {
    final params = <String>[
      if (maxWidth != null) 'maxWidth=$maxWidth',
      if (tag != null && tag.isNotEmpty) 'tag=$tag',
      'quality=90',
    ];
    return '${normalizedBase(baseUrl)}/Items/$itemId/Images/$kind'
        '?${params.join('&')}';
  }

  /// Absolute direct-play URL. The token goes in the query so the media player
  /// authenticates every range request without extra header plumbing (mpv
  /// does not forward custom headers across a redirect or into sub-requests).
  /// [mediaSourceId] must be Emby's `MediaSources[].Id`, not the item id.
  static String stream(
    String baseUrl,
    String itemId, {
    required String accessToken,
    String? mediaSourceId,
    int? startTicks,
  }) {
    final params = <String>[
      'static=true',
      'MediaSourceId=${mediaSourceId ?? itemId}',
      _tokenQuery(accessToken),
      if (startTicks != null && startTicks > 0) 'StartTimeTicks=$startTicks',
    ];
    return '${normalizedBase(baseUrl)}/Videos/$itemId/stream?${params.join('&')}';
  }

  /// Absolute HLS transcode URL (`master.m3u8`).
  ///
  /// Emby re-encodes here when the client forces h264/SDR or picks a lower
  /// quality. It does *not* tone-map Dolby Vision: a profile 5 source comes
  /// back through a bare `format=pix_fmts=yuv420p` and keeps its IPTPQc2
  /// samples, so this URL must not be used to "fix" DV colours — those sources
  /// direct play instead and let the client's decode shader apply the RPU.
  /// [videoBitrate] is in bits per second, matching the Emby API.
  ///
  /// [playSessionId] must be non-empty and stable for the session: Emby copies
  /// it into every segment URI it emits, and with an empty value each segment
  /// request is rejected with `400 Value cannot be null. (Parameter 'key')`.
  static String transcode(
    String baseUrl,
    String itemId, {
    required String accessToken,
    required String playSessionId,
    String? mediaSourceId,
    String videoCodec = 'h264',
    String audioCodec = 'aac',
    int? videoBitrate,
    int? startTicks,
  }) {
    final params = <String>[
      'MediaSourceId=${mediaSourceId ?? itemId}',
      'VideoCodec=$videoCodec',
      'AudioCodec=$audioCodec',
      'TranscodingMaxAudioChannels=2',
      'SegmentContainer=mp4',
      'MinSegments=1',
      'BreakOnNonKeyFrames=True',
      'PlaySessionId=$playSessionId',
      if (videoBitrate != null && videoBitrate > 0)
        'VideoBitrate=$videoBitrate',
      _tokenQuery(accessToken),
      if (startTicks != null && startTicks > 0) 'StartTimeTicks=$startTicks',
    ];
    return '${normalizedBase(baseUrl)}/Videos/$itemId/master.m3u8?'
        '${params.join('&')}';
  }
}
