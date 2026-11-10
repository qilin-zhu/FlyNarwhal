/// Which media server family the app is currently signed in to.
///
/// Persisted as a short string so a future kind can be added without a
/// migration; unknown values fall back to [MediaServerKind.fnos], which is what
/// every pre-existing install is.
enum MediaServerKind {
  fnos('fnos'),
  emby('emby'),
  jellyfin('jellyfin');

  const MediaServerKind(this.value);

  final String value;

  static MediaServerKind fromValue(String? raw) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    for (final kind in MediaServerKind.values) {
      if (kind.value == normalized) return kind;
    }
    return MediaServerKind.fnos;
  }

  /// Emby and Jellyfin share the same REST contract, so almost every code path
  /// only needs to distinguish "fnOS" from "Emby family".
  bool get isEmbyFamily =>
      this == MediaServerKind.emby || this == MediaServerKind.jellyfin;

  bool get isFnos => this == MediaServerKind.fnos;
}
