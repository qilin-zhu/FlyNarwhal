import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show File, FileMode, Platform, Process, ProcessStartMode, RandomAccessFile, sleep;
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Runs a Dolby Vision profile 5 stream in the bundled external Yaoplayer
/// (mpv fork) instead of the embedded media_kit surface.
///
/// Yaoplayer renders through `vo=gpu-next` with `gpu-api=d3d11`, which applies
/// the Dolby Vision RPU (IPTPQc2) colour mapping natively. The embedded
/// player cannot reach that: media_kit's render API only registers
/// `render_backend_gpu`/`render_backend_sw`, and mpv's DV handling lives in
/// `vo_gpu_next`. So for profile 5 direct-link sessions the stream is handed
/// to Yaoplayer as its own window, and this class drives it over mpv's JSON
/// IPC named pipe.
///
/// The pipe name is unique per session so concurrent sessions never fight
/// over Yaoplayer's default `\\.\pipe\mpvsocket`; it is passed on the command
/// line, which overrides the bundled portable_config/mpv.conf value.
///
/// mpv's Windows pipe IPC treats every connection as a separate client and
/// delivers replies only to the connection that sent the command, so the pipe
/// is driven from a single isolate that owns one duplex handle
/// (`FileMode.append` is read+write in dart:io) and does blocking reads there
/// — a blocking read on the UI isolate would stall the whole app waiting for
/// a reply that may never come.
class YaoplayerSession {
  YaoplayerSession._(this.process, this._isolateHandle, this._toIsolate);

  /// Absolute path of the bundled launcher, or null when the bundle does not
  /// carry the runtime (non-Windows or arm64 builds).
  static String? resolveExecutable() {
    if (!Platform.isWindows) return null;
    final exe = File('yaoplayer/core-builds/current/Yaoplayer.exe');
    return exe.existsSync() ? exe.absolute.path : null;
  }

  /// Launches Yaoplayer for [url] and returns the session handle, or null
  /// when the runtime is unavailable (callers fall back to embedded playback).
  ///
  /// [headers] are forwarded as mpv `--http-header-fields` entries;
  /// [startSeconds] seeds the initial position; [title] feeds the window
  /// title and media-title property.
  static Future<YaoplayerSession?> start({
    required String url,
    required Map<String, String> headers,
    int startSeconds = 0,
    String? title,
  }) async {
    final exePath = resolveExecutable();
    if (exePath == null) {
      debugPrint('[yaoplayer] runtime not bundled, skipping external session');
      return null;
    }
    // Yaoplayer resolves portable_config relative to its own location, so
    // cwd must be the directory containing Yaoplayer.exe.
    final cwd = File(exePath).parent.parent.parent.path;
    final pipePath = '\\\\.\\pipe\\fly_narwhal_yaoplayer_'
        '${DateTime.now().microsecondsSinceEpoch}_${pid}';
    final titleArgument = title ?? 'FlyNarwhal';
    final args = <String>[
      '--input-ipc-server=$pipePath',
      '--force-window=yes',
      '--title=$titleArgument',
      if (startSeconds > 0) '--start=${startSeconds}s',
      for (final entry in headers.entries)
        '--http-header-fields=${entry.key}: ${entry.value}',
      '--',
      url,
    ];
    // A CR/LF inside an argument would let whatever follows be parsed as a
    // separate mpv option; refuse rather than sanitise silently.
    for (final arg in args) {
      if (arg.contains('\r') || arg.contains('\n')) {
        debugPrint('[yaoplayer] refusing arguments with newline characters');
        return null;
      }
    }

    final process = await Process.start(
      exePath,
      args,
      workingDirectory: cwd,
      mode: ProcessStartMode.normal,
    );

    // Drive the IPC pipe from an isolate so blocking reads never touch the
    // UI thread; see the class comment for why one handle must do both.
    final toIsolate = ReceivePort();
    final isolate = await Isolate.spawn(
      _pipeIsolateMain,
      _PipeIsolateConfig(
        pipePath: pipePath,
        commands: toIsolate.sendPort,
      ),
      debugName: 'yaoplayer-ipc',
    );
    return YaoplayerSession._(process, isolate, toIsolate);
  }

  final Process process;
  final Isolate _isolateHandle;
  final ReceivePort _toIsolate;

  SendPort? _isolateCommands;
  Future<SendPort?> get _commandsReady {
    return _commandsReadyMemo ??= () async {
      final config = await _toIsolate.first as SendPort;
      _isolateCommands = config;
      return config;
    }();
  }

  Future<SendPort?>? _commandsReadyMemo;

  final Map<int, Completer<Map<String, dynamic>?>> _pending = {};
  int _requestId = 0;
  // The isolate tags replies with the request id and pipes events back here.
  // Initialised eagerly in start() via _ensureReplyPort; direct field
  // initialization cannot reference instance state, hence the helper.
  ReceivePort? _repliesPort;

  ReceivePort _ensureReplyPort() {
    return _repliesPort ??= () {
      final port = ReceivePort();
      port.listen((message) {
        if (message is List && message.length == 2) {
          final id = message[0] as int?;
          final reply = message[1];
          if (id != null) {
            final completer = _pending.remove(id);
            if (completer != null && !completer.isCompleted) {
              completer.complete(reply is Map<String, dynamic>
                  ? reply
                  : null);
            }
          }
        }
      });
      return port;
    }();
  }

  /// Sends a command and resolves the full reply map
  /// (`{"error": ..., "data": ...}`), or null on timeout/disconnect.
  Future<Map<String, dynamic>?> request(List<String> args) async {
    final commands = await _commandsReady;
    if (commands == null) return null;
    _requestId += 1;
    final id = _requestId;
    final completer = Completer<Map<String, dynamic>?>();
    _pending[id] = completer;
    final replyPort = _ensureReplyPort();
    commands.send([id, args, replyPort.sendPort]);
    return completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        _pending.remove(id);
        return null;
      },
    );
  }

  /// Sends a command without waiting for a reply.
  Future<void> command(List<String> args) async {
    unawaited(request(args));
  }

  /// Current playback position in seconds, or null when unavailable.
  Future<int?> positionSeconds() async {
    final reply = await request(const ['get_property', 'time-pos']);
    if (reply != null && reply['error'] == 'success' && reply['data'] is num) {
      return (reply['data'] as num).round();
    }
    return null;
  }

  /// Politely closes Yaoplayer (flushing watch-later state) and releases the
  /// pipe isolate.
  Future<void> stop() async {
    await command(const ['quit']);
    // Give mpv a moment to flush watch-later state before the hard kill.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    process.kill();
    _isolateHandle.kill();
    _repliesPort?.close();
    _repliesPort = null;
    _toIsolate.close();
    _pending.clear();
  }
}

class _PipeIsolateConfig {
  const _PipeIsolateConfig({
    required this.pipePath,
    required this.commands,
  });

  final String pipePath;
  final SendPort commands;
}

/// Owns the single duplex connection to mpv's IPC pipe. Blocking reads are
/// safe here; the host isolate stays responsive.
void _pipeIsolateMain(_PipeIsolateConfig config) {
  final replies = ReceivePort();
  config.commands.send(replies.sendPort);

  // mpv creates the pipe shortly after process start; retry until it shows up.
  RandomAccessFile? pipe;
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (pipe == null && DateTime.now().isBefore(deadline)) {
    try {
      // FileMode.append opens read+write on Windows named pipes; write mode
      // alone cannot read the replies back.
      pipe = File(config.pipePath).openSync(mode: FileMode.append);
    } catch (_) {
      // No Isolate.sleep in this SDK version; a busy retry at 200ms via a
      // blocking OS-level sleep keeps the pipe poll cheap.
      sleep(const Duration(milliseconds: 200));
    }
  }
  if (pipe == null) {
    Isolate.current.kill();
    return;
  }

  int requestId = 0;
  final byteBuf = <int>[];

  String readLine() {
    while (true) {
      for (var i = 0; i < byteBuf.length; i++) {
        if (byteBuf[i] == 0x0A) {
          final line = utf8.decode(byteBuf.sublist(0, i), allowMalformed: true);
          byteBuf.removeRange(0, i + 1);
          return line;
        }
      }
      // Blocking read: waits until mpv writes more data.
      final chunk = pipe!.readSync(65536);
      if (chunk.isNotEmpty) {
        byteBuf.addAll(chunk);
      } else {
        sleep(const Duration(milliseconds: 50));
      }
    }
  }

  replies.listen((message) {
    if (message is! List || message.length != 3) return;
    final id = message[0] as int;
    final args = (message[1] as List).cast<String>();
    final replyPort = message[2] as SendPort;
    try {
      final payload = jsonEncode({
        'command': args,
        'request_id': ++requestId,
      });
      pipe!.writeStringSync('$payload\n');
      pipe.flushSync();
      final line = readLine();
      Map<String, dynamic>? reply;
      try {
        reply = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {}
      replyPort.send([id, reply]);
    } catch (_) {
      // Pipe died (Yaoplayer exited); reply null so callers stop polling.
      replyPort.send([id, null]);
      Isolate.current.kill();
    }
  });
}
