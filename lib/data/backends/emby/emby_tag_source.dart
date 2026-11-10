import '../../../core/network/api_result.dart';
import '../../datasources/tag_source.dart';
import '../../models/tag_models.dart';
import 'emby_api.dart';
import 'emby_mapper.dart';
import 'emby_tags.dart';

/// [TagSource] backed by an Emby / Jellyfin server.
///
/// Emby has no `/tag/*` endpoints, so the three fnOS lookups are synthesised
/// from what the server can actually answer:
///
///  * genres        ← `/Items/Filters` (`Genres`)
///  * locale tables ← `/Localization/{Cultures,Countries}`
///  * filter rows   ← `/Items/Filters` (`Genres`, `Years`) plus a bounded item
///                    probe that reports which resolutions occur in the scope.
///
/// Rows that Emby cannot filter server-side (colour range, audio profile, audio
/// language) are returned empty on purpose. The shared filter bar then renders
/// them with only the "all" option, instead of offering options whose selection
/// would be silently ignored.
class EmbyTagSource implements TagSource {
  EmbyTagSource(this._api, {required String userId}) : _userId = userId;

  final EmbyApi _api;
  final String _userId;

  /// Scope key → derived rows, so re-rendering the filter bar does not re-probe
  /// on every frame.
  final Map<String, _ScopeRows> _scopeCache = <String, _ScopeRows>{};
  Map<String, String>? _iso6391;
  Map<String, String>? _iso6392;
  Map<String, String>? _iso3166;

  static const Duration _scopeTtl = Duration(minutes: 5);
  static const int _probeLimit = 60;

  @override
  Future<ApiResult<List<GenresResponse>>> getGenres({
    required String language,
    bool force = false,
  }) async {
    final result = await _api.get<Map<String, dynamic>>(
      '/Genres',
      query: {'UserId': _userId, 'SortBy': 'SortName'},
    );
    return result.map((payload) {
      final items = (payload['Items'] as List?) ?? const [];
      return items
          .whereType<Map>()
          .map((raw) => raw['Name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .map((name) => GenresResponse(
                id: EmbyGenreIndex.idFor(name),
                value: name,
              ))
          .toList();
    });
  }

  @override
  Future<ApiResult<Map<String, String>>> getTag(
    String tag, {
    required String language,
    bool force = false,
  }) async {
    switch (tag) {
      case 'iso6391':
      case 'iso6392':
        return _cultureMap(tag, force: force);
      case 'iso3166':
        return _countryMap(force: force);
      default:
        // fnOS-only table; an empty map keeps callers on their raw-code
        // fallback instead of popping a toast on every detail page.
        return Success(<String, String>{});
    }
  }

  @override
  Future<ApiResult<TagListResponse>> getTagList({
    String? ancestorGuid,
    String? parentGuid,
    required int isFavorite,
    String? type,
  }) async {
    final parentId = _rawId(parentGuid ?? ancestorGuid);
    final scopeKey = '$parentId|$isFavorite|${type ?? ''}';
    final cached = _scopeCache[scopeKey];
    if (cached != null && !cached.isExpired) {
      return Success(cached.rows);
    }

    final filters = await _api.get<Map<String, dynamic>>(
      '/Items/Filters',
      query: {
        'UserId': _userId,
        if (parentId != null) 'ParentId': parentId,
        if (parentId != null) 'Recursive': true,
      },
    );
    final failure = filters.failureOrNull;
    if (failure != null) return ResultFailure<TagListResponse>(failure);

    final payload = filters.dataOrNull ?? const <String, dynamic>{};
    final genreNames = ((payload['Genres'] as List?) ?? const [])
        .whereType<Map>()
        .map((raw) => raw['Name']?.toString() ?? '')
        .where((name) => name.isNotEmpty);
    final years = ((payload['Years'] as List?) ?? const [])
        .whereType<num>()
        .map((year) => year.toInt());

    final rows = TagListResponse(
      genres: EmbyGenreIndex.idsFor(genreNames),
      resolutions: await _probeResolutions(
        parentId: parentId,
        isFavorite: isFavorite,
        type: type,
      ),
      decades: EmbyTags.decadesFromYears(years),
    );
    _scopeCache[scopeKey] = _ScopeRows(rows);
    return Success(rows);
  }

  /// Heights present in the scope, mapped to fnOS resolution buckets.
  ///
  /// A static ladder would offer `4K` on a 480p-only library, where selecting
  /// it can only produce an empty grid.
  Future<List<String>> _probeResolutions({
    String? parentId,
    required int isFavorite,
    String? type,
  }) async {
    final result = await _api.get<Map<String, dynamic>>(
      '/Users/$_userId/Items',
      query: {
        if (parentId != null) 'ParentId': parentId,
        'Recursive': true,
        'IncludeItemTypes': _itemTypesFor(type),
        if (isFavorite == 1) 'Filters': 'IsFavorite',
        'Fields': 'Height',
        'ImageTypeLimit': 0,
        'Limit': _probeLimit,
      },
    );
    final found = <String>{};
    for (final item in ((result.dataOrNull?['Items'] as List?) ?? const [])
        .whereType<Map>()) {
      final height = item['Height'] is num ? (item['Height'] as num).toInt() : 0;
      final label = EmbyMapper.resolutionLabelFromHeight(height);
      if (label != null) found.add(label);
    }
    const order = ['4K', '1080p', '720p', '480p'];
    final ordered = order.where(found.contains).toList();
    ordered.addAll(found.where((value) => !order.contains(value)).toList()
      ..sort());
    return ordered;
  }

  Future<ApiResult<Map<String, String>>> _countryMap({
    required bool force,
  }) async {
    if (!force && _iso3166 != null) return Success(_iso3166!);
    final result = await _api.get<List<dynamic>>('/Localization/Countries');
    final mapped = <String, String>{};
    for (final raw in result.dataOrNull ?? const []) {
      if (raw is! Map) continue;
      final code = raw['TwoLetterISORegionName']?.toString() ?? '';
      final name = raw['DisplayName']?.toString() ?? code;
      if (code.isNotEmpty) mapped[code.toUpperCase()] = name;
    }
    if (mapped.isNotEmpty) _iso3166 = mapped;
    return Success(mapped);
  }

  /// `iso6391` → two-letter codes, `iso6392` → three-letter codes. Jellyfin
  /// ships both spellings in one payload, so the two lookups share a request.
  Future<ApiResult<Map<String, String>>> _cultureMap(
    String tag, {
    required bool force,
  }) async {
    if (!force && _iso6391 != null && _iso6392 != null) {
      return Success(tag == 'iso6391' ? _iso6391! : _iso6392!);
    }
    final result = await _api.get<List<dynamic>>('/Localization/Cultures');
    final two = <String, String>{};
    final three = <String, String>{};
    for (final raw in result.dataOrNull ?? const []) {
      if (raw is! Map) continue;
      final name = raw['DisplayName']?.toString() ?? '';
      if (name.isEmpty) continue;
      final short = raw['TwoLetterISOLanguageName']?.toString() ?? '';
      if (short.isNotEmpty) two[short] = name;
      for (final code
          in (raw['ThreeLetterISOLanguageNames'] as List?) ?? const []) {
        final value = code.toString();
        if (value.isNotEmpty) three[value] = name;
      }
    }
    if (two.isNotEmpty) _iso6391 = two;
    if (three.isNotEmpty) _iso6392 = three;
    return Success(tag == 'iso6391' ? two : (three.isEmpty ? two : three));
  }

  static String? _rawId(String? guid) {
    if (guid == null || guid.isEmpty) return null;
    return EmbyMapper.rawId(guid);
  }

  static String _itemTypesFor(String? type) {
    switch (type) {
      case 'Movie':
        return 'Movie';
      case 'TV':
        return 'Series';
      case 'Episode':
        return 'Episode';
      default:
        return 'Movie,Series,Episode,Video,MusicVideo';
    }
  }
}

class _ScopeRows {
  _ScopeRows(this.rows) : _createdAt = DateTime.now();

  final TagListResponse rows;
  final DateTime _createdAt;

  bool get isExpired =>
      DateTime.now().difference(_createdAt) > EmbyTagSource._scopeTtl;
}
