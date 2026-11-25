import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/exec/windows_create_process.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Result of polling a running child.
class ExecPollResult {
  const ExecPollResult({
    required this.data,
    required this.exited,
    this.exitCode,
    this.dropped = false,
  });

  final List<int> data;
  final bool exited;
  final int? exitCode;
  final bool dropped;
}

/// One child process started by an [ExecProcessLauncher] in its own process
/// group (POSIX) or job tree (Windows).
abstract class ExecProcessHandle {
  int get pid;

  /// Returns output produced since the last call and the exit state.
  Future<ExecPollResult> poll();

  Future<int> writeStdin(List<int> bytes, {bool eof = false});

  /// Terminates the whole group/tree. [force] = SIGKILL / `taskkill /F`.
  /// Returns false when nothing was left to signal.
  Future<bool> killGroup({required bool force});

  Future<void> release();
}

/// Starts `exec.run` children with an explicit environment (no inheritance).
abstract class ExecProcessLauncher {
  bool get supportsPty;

  Future<ExecProcessHandle> start({
    required String command,
    required String cwd,
    required Map<String, String> environment,
    required bool pty,
  });
}

/// Platform default: native process groups on macOS, `cmd.exe` + `taskkill /T`
/// on Windows, and a fail-closed launcher elsewhere (Rule H1).
ExecProcessLauncher defaultExecProcessLauncher() {
  if (Platform.isMacOS) return MacosExecProcessLauncher();
  if (Platform.isWindows) return WindowsExecProcessLauncher();
  return const UnsupportedExecProcessLauncher();
}

/// Refuses every start: no process-group runner exists on this platform yet.
class UnsupportedExecProcessLauncher implements ExecProcessLauncher {
  const UnsupportedExecProcessLauncher();

  @override
  bool get supportsPty => false;

  @override
  Future<ExecProcessHandle> start({
    required String command,
    required String cwd,
    required Map<String, String> environment,
    required bool pty,
  }) {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'exec.run has no process-group runner on this platform.',
    );
  }
}

/// Windows runner: native `CreateProcessW` with verbatim `cmd.exe /d /s /c`
/// `lpCommandLine` (avoids Dart's MSVCRT `\"` escaping) and Job Object /
/// `taskkill /PID <pid> /T /F` tree termination. PTY is not available before
/// ConPTY support, so `pty: true` fails closed.
class WindowsExecProcessLauncher implements ExecProcessLauncher {
  WindowsExecProcessLauncher({this.comspec = 'cmd.exe'});

  final String comspec;

  @override
  bool get supportsPty => false;

  @override
  Future<ExecProcessHandle> start({
    required String command,
    required String cwd,
    required Map<String, String> environment,
    required bool pty,
  }) async {
    if (pty) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'pty_unsupported_on_platform',
      );
    }
    return startWindowsNativeCmdProcess(
      comspec: comspec,
      command: command,
      cwd: cwd,
      environment: environment,
    );
  }
}

/// macOS runner backed by `XunaHostPlugin+Exec.swift` (`posix_spawn` with
/// `POSIX_SPAWN_SETPGROUP`, optional PTY, `kill(-pgid, …)`).
class MacosExecProcessLauncher implements ExecProcessLauncher {
  MacosExecProcessLauncher({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('xuna/host');

  final MethodChannel _channel;

  @override
  bool get supportsPty => true;

  @override
  Future<ExecProcessHandle> start({
    required String command,
    required String cwd,
    required Map<String, String> environment,
    required bool pty,
  }) async {
    final raw = await _invoke('execSpawn', <String, Object?>{
      'command': command,
      'cwd': cwd,
      'environment': environment,
      'pty': pty,
    });
    final handle = raw['handle'];
    final pid = raw['pid'];
    if (handle is! int || pid is! int) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'exec_spawn_failed',
      );
    }
    return _NativeProcessHandle(this, handle, pid);
  }

  Future<Map<Object?, Object?>> _invoke(
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>(method, args)
          .timeout(const Duration(seconds: 10));
      if (result == null) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'exec_native_error',
        );
      }
      return result;
    } on MissingPluginException {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'platform_unsupported',
      );
    } on PlatformException catch (error) {
      final details = error.details;
      final code = details is Map && details['errorCode'] is String
          ? details['errorCode'] as String
          : 'exec_native_error';
      throw XunaHostChannelException(status: XtpStatus.failed, errorCode: code);
    } on TimeoutException {
      throw const XunaHostChannelException(
        status: XtpStatus.timeout,
        errorCode: 'exec_native_timeout',
      );
    }
  }
}

class _NativeProcessHandle implements ExecProcessHandle {
  _NativeProcessHandle(this._launcher, this._handle, this.pid);

  final MacosExecProcessLauncher _launcher;
  final int _handle;

  @override
  final int pid;

  @override
  Future<ExecPollResult> poll() async {
    final raw = await _launcher._invoke('execPoll', <String, Object?>{
      'handle': _handle,
    });
    final data = raw['data'];
    final exited = raw['exited'] == true && raw['outputClosed'] == true;
    return ExecPollResult(
      data: data is Uint8List ? data : const <int>[],
      exited: exited,
      exitCode: exited ? raw['exitCode'] as int? : null,
      dropped: raw['dropped'] == true,
    );
  }

  @override
  Future<int> writeStdin(List<int> bytes, {bool eof = false}) async {
    final raw = await _launcher._invoke('execWrite', <String, Object?>{
      'handle': _handle,
      'data': Uint8List.fromList(bytes),
      'eof': eof,
    });
    final written = raw['written'];
    return written is int ? written : -1;
  }

  @override
  Future<bool> killGroup({required bool force}) async {
    final raw = await _launcher._invoke('execSignal', <String, Object?>{
      'handle': _handle,
      'signal': force ? 'kill' : 'term',
    });
    return raw['sent'] == true;
  }

  @override
  Future<void> release() async {
    await _launcher._invoke('execRelease', <String, Object?>{
      'handle': _handle,
    });
  }
}

/// Decodes child output bytes for a tool response: strips ANSI/VT escape
/// sequences and passes the text through U5 secret redaction, bounded to
/// [maxBytes] (UTF-8). Returns the redacted text and whether it was cut.
({String text, bool truncated}) redactExecOutput(
  List<int> bytes, {
  int maxBytes = 16384,
}) {
  var start = 0;
  var cut = false;
  // Keep the tail: the end of a build/test log carries the verdict.
  if (bytes.length > maxBytes) {
    start = bytes.length - maxBytes;
    cut = true;
    while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
      start++;
    }
  }
  final decoded = utf8.decode(bytes.sublist(start), allowMalformed: true);
  final plain = decoded.replaceAll(
    RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*\x07|[@-Z\\-_])'),
    '',
  );
  final redacted = redactBrowserSnapshot(plain, maxBytes: maxBytes);
  return (text: redacted.text, truncated: cut || redacted.truncated);
}
