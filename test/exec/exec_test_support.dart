import 'dart:convert';

import 'package:xuna_desktop/features/exec/exec_process_launcher.dart';

/// Scripted child used by the exec registry/driver tests.
class FakeExecHandle implements ExecProcessHandle {
  FakeExecHandle(this.pid);

  @override
  final int pid;
  final List<int> _pending = <int>[];
  bool exited = false;
  int? exitCode;
  int termSignals = 0;
  int killSignals = 0;
  bool exitOnTerm = true;
  final List<int> stdinBytes = <int>[];
  bool released = false;

  void emit(String text) => _pending.addAll(utf8.encode(text));

  void exit(int code) {
    exited = true;
    exitCode = code;
  }

  @override
  Future<ExecPollResult> poll() async {
    final data = List<int>.of(_pending);
    _pending.clear();
    return ExecPollResult(data: data, exited: exited, exitCode: exitCode);
  }

  @override
  Future<int> writeStdin(List<int> bytes, {bool eof = false}) async {
    stdinBytes.addAll(bytes);
    return bytes.length;
  }

  @override
  Future<bool> killGroup({required bool force}) async {
    if (exited) return false;
    if (force) {
      killSignals++;
      exit(137);
    } else {
      termSignals++;
      if (exitOnTerm) exit(143);
    }
    return true;
  }

  @override
  Future<void> release() async => released = true;
}

class FakeExecLauncher implements ExecProcessLauncher {
  final List<FakeExecHandle> started = <FakeExecHandle>[];
  final List<Map<String, String>> environments = <Map<String, String>>[];
  final List<String> commands = <String>[];
  void Function(FakeExecHandle handle)? onStart;

  @override
  bool get supportsPty => true;

  @override
  Future<ExecProcessHandle> start({
    required String command,
    required String cwd,
    required Map<String, String> environment,
    required bool pty,
  }) async {
    final handle = FakeExecHandle(1000 + started.length);
    started.add(handle);
    environments.add(environment);
    commands.add(command);
    onStart?.call(handle);
    return handle;
  }
}
