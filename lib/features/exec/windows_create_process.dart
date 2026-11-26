import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/exec/exec_process_launcher.dart';
import 'package:xuna_desktop/features/exec/windows_kernel32_ffi.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Builds the exact `lpCommandLine` passed verbatim to `CreateProcessW` for
/// `cmd.exe /d /s /c "<command>"`.
///
/// Unlike Dart's `Process.start` (which escapes `"` as `\"` using MSVCRT rules
/// that `cmd.exe` does not understand), passing this string verbatim to
/// `CreateProcessW` lets `cmd.exe /s /c` strip only the single outer quote
/// pair and execute [command] unchanged.
String buildWindowsCmdCommandLine(String comspec, String command) {
  if (comspec.isEmpty ||
      comspec.contains('\x00') ||
      command.contains('\x00') ||
      command.contains('\r') ||
      command.contains('\n')) {
    throw const XunaHostChannelException(
      status: XtpStatus.invalidArgs,
      errorCode: 'invalid_exec_command',
    );
  }
  final quotedExe = comspec.contains(' ') && !comspec.startsWith('"')
      ? '"$comspec"'
      : comspec;
  return '$quotedExe /d /s /c "$command"';
}

/// Resolves the `lpApplicationName` path for `cmd.exe` on Windows.
String resolveWindowsComspecPath(
  String comspec, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  if (comspec.toLowerCase() == 'cmd.exe') {
    final fromEnv = env['ComSpec'] ?? env['COMSPEC'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      return fromEnv.trim();
    }
    return r'C:\Windows\System32\cmd.exe';
  }
  return comspec;
}

/// Encodes [environment] into a sorted UTF-16LE `KEY=VALUE\0...\0\0` block
/// suitable for `CreateProcessW` with `CREATE_UNICODE_ENVIRONMENT`.
Uint16List encodeWindowsEnvironmentBlock(Map<String, String> environment) {
  final entries =
      environment.entries
          .where(
            (e) =>
                e.key.isNotEmpty &&
                !e.key.contains('=') &&
                !e.key.contains('\x00') &&
                !e.value.contains('\x00'),
          )
          .toList()
        ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  if (entries.isEmpty) {
    return Uint16List.fromList(const <int>[0, 0]);
  }
  final units = <int>[];
  for (final e in entries) {
    units.addAll(e.key.codeUnits);
    units.add(0x3D); // '='
    units.addAll(e.value.codeUnits);
    units.add(0);
  }
  units.add(0);
  return Uint16List.fromList(units);
}

/// Encodes [value] as a null-terminated UTF-16LE unit list.
Uint16List encodeUtf16NullTerminated(String value) {
  final units = value.codeUnits;
  final out = Uint16List(units.length + 1);
  out.setRange(0, units.length, units);
  out[units.length] = 0;
  return out;
}

/// Starts `cmd.exe /d /s /c "<command>"` via Win32 `CreateProcessW` so
/// `lpCommandLine` is delivered verbatim (no Dart MSVCRT `\"` escaping), with
/// a sanitized UTF-16 environment block and a Job Object for tree termination.
ExecProcessHandle startWindowsNativeCmdProcess({
  required String comspec,
  required String command,
  required String cwd,
  required Map<String, String> environment,
}) {
  if (!Platform.isWindows) {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
    );
  }
  final appPath = resolveWindowsComspecPath(comspec);
  final cmdLine = buildWindowsCmdCommandLine(appPath, command);
  return _Win32ExecProcess.spawn(
    applicationName: appPath,
    commandLine: cmdLine,
    cwd: cwd,
    environment: environment,
  );
}

class _Win32ExecProcess implements ExecProcessHandle {
  _Win32ExecProcess._({
    required WinKernel32 k32,
    required this.pid,
    required int hProcess,
    required int hThread,
    required int hStdoutRead,
    required int hStdinWrite,
    required int hJob,
  }) : _k32 = k32,
       _hProcess = hProcess,
       _hThread = hThread,
       _hStdoutRead = hStdoutRead,
       _hStdinWrite = hStdinWrite,
       _hJob = hJob;

  final WinKernel32 _k32;
  @override
  final int pid;
  int _hProcess;
  int _hThread;
  int _hStdoutRead;
  int _hStdinWrite;
  int _hJob;
  int? _exitCode;
  bool _released = false;

  static _Win32ExecProcess spawn({
    required String applicationName,
    required String commandLine,
    required String cwd,
    required Map<String, String> environment,
  }) {
    final k32 = WinKernel32.instance;
    final sa = k32.alloc<WinSecurityAttributes>(
      sizeOf<WinSecurityAttributes>(),
    );
    final outReadPtr = k32.alloc<IntPtr>(sizeOf<IntPtr>());
    final outWritePtr = k32.alloc<IntPtr>(sizeOf<IntPtr>());
    final inReadPtr = k32.alloc<IntPtr>(sizeOf<IntPtr>());
    final inWritePtr = k32.alloc<IntPtr>(sizeOf<IntPtr>());
    final si = k32.alloc<WinStartupInfoW>(sizeOf<WinStartupInfoW>());
    final pi = k32.alloc<WinProcessInformation>(
      sizeOf<WinProcessInformation>(),
    );
    final appPtr = k32.allocUtf16(encodeUtf16NullTerminated(applicationName));
    final cmdPtr = k32.allocUtf16(encodeUtf16NullTerminated(commandLine));
    final cwdPtr = k32.allocUtf16(encodeUtf16NullTerminated(cwd));
    final envPtr = k32.allocUtf16(encodeWindowsEnvironmentBlock(environment));

    var hOutRead = 0;
    var hOutWrite = 0;
    var hInRead = 0;
    var hInWrite = 0;
    var hJob = 0;
    try {
      sa.ref.nLength = sizeOf<WinSecurityAttributes>();
      sa.ref.lpSecurityDescriptor = nullptr;
      sa.ref.bInheritHandle = 1;

      if (k32.createPipe(outReadPtr, outWritePtr, sa, 0) == 0 ||
          k32.createPipe(inReadPtr, inWritePtr, sa, 0) == 0) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'exec_spawn_failed',
        );
      }
      hOutRead = outReadPtr.value;
      hOutWrite = outWritePtr.value;
      hInRead = inReadPtr.value;
      hInWrite = inWritePtr.value;

      k32.setHandleInformation(hOutRead, winHandleFlagInherit, 0);
      k32.setHandleInformation(hInWrite, winHandleFlagInherit, 0);

      si.ref.cb = sizeOf<WinStartupInfoW>();
      si.ref.dwFlags = winStartfUseStdHandles;
      si.ref.hStdInput = hInRead;
      si.ref.hStdOutput = hOutWrite;
      si.ref.hStdError = hOutWrite;

      // Created suspended so the kill-on-close Job Object is attached BEFORE
      // cmd.exe runs: no grandchild can start outside the job in the window
      // between process creation and job assignment.
      //
      // Note (P0.5, 2026-11-26): cmd builtins still write the OEM code page
      // to the pipe. Setting the child's console to UTF-8 is not possible
      // here: AttachConsole on the suspended child fails with
      // ERROR_INVALID_HANDLE (its console only exists once it runs), and
      // after resume cmd has already cached the code page. The real fix is a
      // ConPTY launcher (also needed for `pty: true` on Windows).
      final ok = k32.createProcessW(
        appPtr,
        cmdPtr,
        nullptr,
        nullptr,
        1,
        winCreateUnicodeEnvironment | winCreateNoWindow | winCreateSuspended,
        envPtr.cast<Void>(),
        cwdPtr,
        si,
        pi,
      );
      if (ok == 0) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'exec_spawn_failed',
        );
      }

      k32.closeHandle(hOutWrite);
      hOutWrite = 0;
      k32.closeHandle(hInRead);
      hInRead = 0;

      try {
        hJob = _attachKillOnCloseJob(k32, pi.ref.hProcess);
        if (k32.resumeThread(pi.ref.hThread) == winResumeThreadFailed) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'exec_spawn_failed',
          );
        }
      } catch (_) {
        // Never leave a suspended cmd.exe behind.
        k32.terminateProcess(pi.ref.hProcess, 1);
        k32.closeHandle(pi.ref.hThread);
        k32.closeHandle(pi.ref.hProcess);
        rethrow;
      }
      final handle = _Win32ExecProcess._(
        k32: k32,
        pid: pi.ref.dwProcessId,
        hProcess: pi.ref.hProcess,
        hThread: pi.ref.hThread,
        hStdoutRead: hOutRead,
        hStdinWrite: hInWrite,
        hJob: hJob,
      );
      hOutRead = 0;
      hInWrite = 0;
      hJob = 0;
      return handle;
    } finally {
      if (hOutRead != 0) k32.closeHandle(hOutRead);
      if (hOutWrite != 0) k32.closeHandle(hOutWrite);
      if (hInRead != 0) k32.closeHandle(hInRead);
      if (hInWrite != 0) k32.closeHandle(hInWrite);
      if (hJob != 0) k32.closeHandle(hJob);
      k32.free(sa);
      k32.free(outReadPtr);
      k32.free(outWritePtr);
      k32.free(inReadPtr);
      k32.free(inWritePtr);
      k32.free(si);
      k32.free(pi);
      k32.free(appPtr);
      k32.free(cmdPtr);
      k32.free(cwdPtr);
      k32.free(envPtr);
    }
  }

  static int _attachKillOnCloseJob(WinKernel32 k32, int hProcess) {
    final hJob = k32.createJobObjectW(nullptr, nullptr);
    if (hJob == 0) return 0;
    final info = k32.alloc<WinJobObjectExtendedLimitInformation>(
      sizeOf<WinJobObjectExtendedLimitInformation>(),
    );
    try {
      info.ref.basicLimitInformation.limitFlags =
          winJobObjectLimitKillOnJobClose;
      k32.setInformationJobObject(
        hJob,
        winJobObjectExtendedLimitInfoClass,
        info.cast<Void>(),
        sizeOf<WinJobObjectExtendedLimitInformation>(),
      );
      if (k32.assignProcessToJobObject(hJob, hProcess) == 0) {
        k32.closeHandle(hJob);
        return 0;
      }
      return hJob;
    } finally {
      k32.free(info);
    }
  }

  List<int> _drainPipe() {
    if (_hStdoutRead == 0) return const <int>[];
    final availPtr = _k32.alloc<Uint32>(sizeOf<Uint32>());
    final readPtr = _k32.alloc<Uint32>(sizeOf<Uint32>());
    final out = <int>[];
    try {
      while (out.length < 64 * 1024) {
        availPtr.value = 0;
        final peekOk = _k32.peekNamedPipe(
          _hStdoutRead,
          nullptr,
          0,
          nullptr,
          availPtr,
          nullptr,
        );
        if (peekOk == 0 || availPtr.value == 0) break;
        final chunk = availPtr.value > 8192 ? 8192 : availPtr.value;
        final buf = _k32.alloc<Uint8>(chunk);
        try {
          readPtr.value = 0;
          final readOk = _k32.readFile(
            _hStdoutRead,
            buf,
            chunk,
            readPtr,
            nullptr,
          );
          if (readOk == 0 || readPtr.value == 0) break;
          out.addAll(buf.asTypedList(readPtr.value));
        } finally {
          _k32.free(buf);
        }
      }
      return out;
    } finally {
      _k32.free(availPtr);
      _k32.free(readPtr);
    }
  }

  @override
  Future<ExecPollResult> poll() async {
    final data = <int>[..._drainPipe()];
    if (_exitCode == null && _hProcess != 0) {
      final codePtr = _k32.alloc<Uint32>(sizeOf<Uint32>());
      try {
        if (_k32.getExitCodeProcess(_hProcess, codePtr) != 0 &&
            codePtr.value != winStillActive) {
          _exitCode = codePtr.value;
          data.addAll(_drainPipe());
        }
      } finally {
        _k32.free(codePtr);
      }
    }
    return ExecPollResult(
      data: data,
      exited: _exitCode != null,
      exitCode: _exitCode,
    );
  }

  @override
  Future<int> writeStdin(List<int> bytes, {bool eof = false}) async {
    if (_hStdinWrite == 0) return -1;
    var total = 0;
    if (bytes.isNotEmpty) {
      final buf = _k32.alloc<Uint8>(bytes.length);
      final writtenPtr = _k32.alloc<Uint32>(sizeOf<Uint32>());
      try {
        buf.asTypedList(bytes.length).setAll(0, bytes);
        while (total < bytes.length) {
          writtenPtr.value = 0;
          final ok = _k32.writeFile(
            _hStdinWrite,
            buf + total,
            bytes.length - total,
            writtenPtr,
            nullptr,
          );
          if (ok == 0 || writtenPtr.value == 0) break;
          total += writtenPtr.value;
        }
      } finally {
        _k32.free(buf);
        _k32.free(writtenPtr);
      }
    }
    if (eof && _hStdinWrite != 0) {
      _k32.closeHandle(_hStdinWrite);
      _hStdinWrite = 0;
    }
    return total;
  }

  @override
  Future<bool> killGroup({required bool force}) async {
    if (_exitCode != null) return false;
    var sent = false;
    if (_hJob != 0) {
      sent = _k32.terminateJobObject(_hJob, 1) != 0;
    }
    if (!sent) {
      try {
        final result = await Process.run('taskkill', <String>[
          '/PID',
          '$pid',
          '/T',
          '/F',
        ]);
        sent = result.exitCode == 0;
      } on Object {
        // Fall through to TerminateProcess below.
      }
      if (!sent && _hProcess != 0) {
        sent = _k32.terminateProcess(_hProcess, 1) != 0;
      }
    }
    return sent;
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    for (final h in <int>[
      _hStdinWrite,
      _hStdoutRead,
      _hThread,
      _hProcess,
      _hJob,
    ]) {
      if (h != 0) _k32.closeHandle(h);
    }
    _hStdinWrite = 0;
    _hStdoutRead = 0;
    _hThread = 0;
    _hProcess = 0;
    _hJob = 0;
  }
}
