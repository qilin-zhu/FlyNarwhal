import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Makes the bundled Dolby Vision profile 5 decode shader available to mpv.
///
/// mpv only accepts `glsl-shaders` as a list of **filesystem** paths — there is
/// no way to hand it shader source — so the asset has to be written out before
/// the first profile 5 stream is opened.
///
/// Why a shader at all: media_kit renders through libmpv's render API, and that
/// API registers only `render_backend_gpu` and `render_backend_sw`
/// (`video/out/vo_libmpv.c`). `vo_gpu_next` — the only mpv video output that
/// decodes Dolby Vision, via libplacebo's `pl_shader_dovi_reshape` — is not
/// reachable from that context, and `vo_gpu`'s own `video.c` only *restores*
/// the colour tags after a DoVi mapping it never performs. The server cannot do
/// it either: Emby's "tone map" for this stream is `vpp_qsv=format=nv12`, which
/// reinterprets the IPTPQc2 samples as ordinary YCbCr and turns the picture
/// green/purple. So the decode happens in the shader stage.
class DolbyVisionShader {
  DolbyVisionShader._();

  static const String assetPath = 'assets/shaders/dolby_vision_profile5.hook';
  static const String fileName = 'dolby_vision_profile5.hook';

  /// Cached absolute path of the extracted shader, or null when extraction has
  /// not succeeded yet. A failed first attempt is retried on the next call
  /// rather than cached, so a transient filesystem error does not disable
  /// profile 5 for the rest of the session.
  static String? _extractedPath;
  static Future<String?>? _inFlight;

  /// Writes [assetPath] to the app's temporary directory once and returns its
  /// absolute path. Returns null when the asset or the directory is
  /// unavailable; callers then play the stream without the shader rather than
  /// failing playback.
  ///
  /// [loadAsset] and [resolveDirectory] are test seams; production code uses
  /// the bundle and `getTemporaryDirectory`.
  static Future<String?> ensureExtracted({
    Future<String> Function()? loadAsset,
    Future<Directory> Function()? resolveDirectory,
  }) {
    final cached = _extractedPath;
    if (cached != null) return Future.value(cached);
    return _inFlight ??=
        _extract(loadAsset ?? _loadAsset, resolveDirectory ?? _resolveDirectory)
            .whenComplete(() => _inFlight = null);
  }

  static Future<String> _loadAsset() => rootBundle.loadString(assetPath);

  static Future<Directory> _resolveDirectory() => getTemporaryDirectory();

  static Future<String?> _extract(
    Future<String> Function() loadAsset,
    Future<Directory> Function() resolveDirectory,
  ) async {
    try {
      final source = await loadAsset();
      final directory = await resolveDirectory();
      final file = File(p.join(directory.path, fileName));
      // Rewrite when the bundled asset changed (or the file vanished) so an
      // updated shader is picked up after an upgrade without a cache purge.
      if (!file.existsSync() || file.readAsStringSync() != source) {
        await file.writeAsString(source, flush: true);
      }
      // `glsl-shaders` is a string list, and mpv picks the separator from the
      // platform: `:` on POSIX, `;` on Windows (`opt->priv` in
      // `options/m_option.c`). A backslash immediately before the separator is
      // consumed as an escape, so leaving native Windows separators in would
      // let a trailing `\` eat the next character. Forward slashes are accepted
      // on every platform mpv runs on, which keeps the value free of both
      // problems; a `,` or `:` inside the path is fine on Windows because its
      // separator is `;`.
      _extractedPath = file.path.replaceAll(r'\', '/');
      return _extractedPath;
    } catch (_) {
      return null;
    }
  }

  /// Test seam: forgets the cached path so the next call re-extracts.
  static void resetForTest() {
    _extractedPath = null;
    _inFlight = null;
  }
}
