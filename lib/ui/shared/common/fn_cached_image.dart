import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/providers.dart';
import 'img_loading_progress_ring.dart';

/// Headers the active backend needs for image requests, or null when the
/// server needs no auth. Exposed here because several screens build their own
/// [CachedNetworkImage] instead of using [FnCachedImage].
Map<String, String>? backendImageHeaders(WidgetRef ref) {
  final headers = ref.watch(mediaBackendProvider).playerHeaders;
  return headers.isEmpty ? null : headers;
}

/// Resolves a backend image reference to an absolute URL.
///
/// fnOS returns server-relative paths (e.g. `/media/poster/...`) that must be
/// routed through `/v/api/v1/sys/img`, while the Emby mapper already emits
/// absolute `/Items/{id}/Images/...` URLs. Those absolute URLs have to pass
/// through untouched: prefixing them a second time produced
/// `.../v/api/v1/sys/img/Items/...`, so every backdrop, poster, episode thumb
/// and cast avatar 404'd on Emby.
///
/// [width] appends the fnOS `?w=` resize hint; Emby URLs carry their own
/// sizing parameters and are never rewritten.
String resolveMediaImageUrl(String? baseUrl, String path, {int? width}) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return trimmed;
  }
  if (baseUrl == null || baseUrl.isEmpty) return '';
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  final suffix = trimmed.contains('?')
      ? ''
      : (width != null ? '?w=${width.round()}' : '');
  if (trimmed.startsWith('/v/api/v1/sys/img')) {
    return '$base$trimmed$suffix';
  }
  if (trimmed.startsWith('v/api/v1/sys/img')) {
    return '$base/$trimmed$suffix';
  }
  final normalized = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  return '$base/v/api/v1/sys/img$normalized$suffix';
}

/// 统一网络图片组件——所有页面通过此组件加载远程图片，共享同一个缓存管理器。
class FnCachedImage extends ConsumerWidget {
  final String posterPath;
  final BoxFit fit;
  final double? placeholderSize;
  final double? width;
  final Widget? errorWidget;
  final Widget? placeholder;
  final Duration fadeOutDuration;

  const FnCachedImage({
    super.key,
    required this.posterPath,
    this.fit = BoxFit.cover,
    this.placeholderSize,
    this.width,
    this.errorWidget,
    this.placeholder,
    this.fadeOutDuration = const Duration(milliseconds: 120),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(preferencesManagerProvider);
    final baseUrl = prefs.getBaseUrl();
    final cacheManager = ref.watch(imageCacheManagerProvider);

    final resolvedPath = posterPath.trim();
    // Emby URLs are already absolute (the mapper builds them) and
    // [resolveMediaImageUrl] returns absolute paths untouched, so one code path
    // serves both backends.
    final imageUrl = baseUrl != null && resolvedPath.isNotEmpty
        ? resolveMediaImageUrl(baseUrl, resolvedPath, width: width?.round())
        : null;

    // Auth differs per backend, so ask it rather than assuming fnOS headers.
    final httpHeaders = backendImageHeaders(ref);

    if (imageUrl == null) {
      return errorWidget ?? const Center(child: Icon(FluentIcons.file_image));
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      httpHeaders: httpHeaders,
      cacheManager: cacheManager,
      fit: fit,
      fadeOutDuration: fadeOutDuration,
      errorWidget: (context, url, error) =>
          errorWidget ?? const Center(child: Icon(FluentIcons.error)),
      placeholder: (context, url) =>
          placeholder ??
          ImgLoadingProgressRing(
            size: placeholderSize ?? 32.0,
          ),
    );
  }

}

/// 返回 backdrop 使用的 [CachedNetworkImageProvider]，供 [Image] 组件使用。
CachedNetworkImageProvider fnCachedImageProvider(
  WidgetRef ref,
  String posterPath, {
  double? width,
}) {
  final prefs = ref.read(preferencesManagerProvider);
  final baseUrl = prefs.getBaseUrl();
  final cacheManager = ref.read(imageCacheManagerProvider);

  final imageUrl = resolveMediaImageUrl(baseUrl, posterPath, width: width?.round());

  final backendHeaders = ref.read(mediaBackendProvider).playerHeaders;
  final httpHeaders = backendHeaders.isEmpty ? null : backendHeaders;

  return CachedNetworkImageProvider(
    imageUrl,
    headers: httpHeaders,
    cacheManager: cacheManager,
  );
}
