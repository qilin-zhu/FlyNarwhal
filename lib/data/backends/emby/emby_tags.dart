/// Translation helpers for the fnOS "tag" metadata that Emby does not model.
///
/// The shared filter UI (see `filter_box.dart`) keys genres by an `int` and
/// expresses date ranges as decade labels (`2010s`, `Recent`), because that is
/// what the fnOS `tag/list` endpoint returns. Emby serves genre *names* inside
/// `/Items/Filters` and a flat list of years instead, so this file bridges the
/// two shapes.
class EmbyGenreIndex {
  const EmbyGenreIndex._();

  /// `int` id → genre name, filled while parsing any genre-bearing payload.
  ///
  /// Ids are derived from the name so a genre keeps one id regardless of which
  /// library (or folder) the option list came from; the filter UI looks names
  /// up by id when it renders the row and when it builds the query.
  static final Map<int, String> _names = <int, String>{};

  static int idFor(String name) {
    final id = name.hashCode;
    _names[id] = name;
    return id;
  }

  static List<int> idsFor(Iterable<String> names) => names
      .where((name) => name.isNotEmpty)
      .map(idFor)
      .toList(growable: false);

  static String? nameOf(int? id) => id == null ? null : _names[id];
}

class EmbyTags {
  const EmbyTags._();

  /// `[2013, 2016]` → `['2010s']`, newest decade first.
  static List<String> decadesFromYears(Iterable<int> years) {
    final decades = <String>{};
    for (final year in years) {
      if (year < 1900) continue;
      decades.add('${(year ~/ 10) * 10}s');
    }
    return decades.toList()..sort((a, b) => b.compareTo(a));
  }

  /// fnOS decade label → Jellyfin `Years` query value.
  ///
  /// `Others` means "outside the listed decades", which Jellyfin cannot express
  /// as a filter, so it is dropped rather than silently widened to everything.
  static String? yearsFilter(String? decade) {
    if (decade == null || decade.isEmpty) return null;
    if (decade == 'Recent') return '${DateTime.now().year}';
    if (decade == 'Others') return null;
    final decadeMatch = RegExp(r'^(\d{4})s$').firstMatch(decade);
    if (decadeMatch != null) {
      final start = int.parse(decadeMatch.group(1)!);
      return List<String>.generate(10, (i) => '${start + i}').join(',');
    }
    return RegExp(r'^\d{4}$').hasMatch(decade) ? decade : null;
  }

  /// fnOS `watched` tag (`1` / `0`) → Jellyfin `Filters` token.
  static String? watchedFilter(String? watched) {
    if (watched == '1') return 'IsPlayed';
    if (watched == '0') return 'IsUnplayed';
    return null;
  }

  /// fnOS resolution bucket → Jellyfin `MinHeight` / `MaxHeight` pair.
  ///
  /// Returns `null` for buckets Jellyfin cannot express, so the caller simply
  /// omits the filter instead of asking for a width that silently matches
  /// nothing.
  static (int?, int?)? heightRange(String? resolution) {
    if (resolution == null || resolution.isEmpty) return null;
    switch (resolution) {
      case '4K':
      case '2160p':
        return (2000, null);
      case '1080p':
        return (1000, 1999);
      case '720p':
        return (700, 999);
      case '480p':
        return (400, 699);
      default:
        final match = RegExp(r'^(\d{3,4})p$').firstMatch(resolution);
        if (match == null) return null;
        final height = int.parse(match.group(1)!);
        return (height - 50, height + 50);
    }
  }
}
