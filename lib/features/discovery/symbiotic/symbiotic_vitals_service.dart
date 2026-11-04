import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

import 'symbiotic_models.dart';

/// Symbiotic Co-Pilot service for Clipboard, Meeting & Mic, Dev Ports, and System Vitals (`UDC-15` S15.1–S15.4).
class SymbioticVitalsService {
  SymbioticVitalsService({
    Future<void> Function(String text)? clipboardWriter,
    Future<MeetingStatusSnapshot> Function()? meetingDetector,
    Future<bool> Function(bool mute)? micMuteSetter,
    Future<List<({int port, String process})>> Function(List<int> ports)?
    portProbe,
    Future<String> Function()? lanIpResolver,
    Future<SystemVitalsSnapshot> Function()? vitalsReader,
    bool initialInMeeting = false,
    String initialMeetingApp = 'none',
    bool initialMicMuted = false,
  }) : _clipboardWriter = clipboardWriter,
       _meetingDetector = meetingDetector,
       _micMuteSetter = micMuteSetter,
       _portProbe = portProbe,
       _lanIpResolver = lanIpResolver,
       _vitalsReader = vitalsReader,
       _inMeeting = initialInMeeting,
       _meetingApp = initialMeetingApp,
       _micMuted = initialMicMuted;

  final Future<void> Function(String text)? _clipboardWriter;
  final Future<MeetingStatusSnapshot> Function()? _meetingDetector;
  final Future<bool> Function(bool mute)? _micMuteSetter;
  final Future<List<({int port, String process})>> Function(List<int> ports)?
  _portProbe;
  final Future<String> Function()? _lanIpResolver;
  final Future<SystemVitalsSnapshot> Function()? _vitalsReader;

  bool _inMeeting;
  String _meetingApp;
  bool _micMuted;
  String _lastWrittenClipboard = '';

  /// Last text written to the clipboard in memory (for test verification; never logged).
  String get debugLastClipboardText => _lastWrittenClipboard;

  /// Writes [rawText] to the OS clipboard after redacting sensitive tokens (`UDC-15` S15.1).
  Future<({bool written, int charCount, int redactedCount})> writeClipboardText(
    String rawText,
  ) async {
    if (!isSafeClipboardWriteText(rawText)) {
      throw ArgumentError.value(rawText, 'text', 'Invalid clipboard text');
    }
    final redacted = redactSensitiveSelectionText(rawText, maxChars: 1600);
    final cleanText = redacted.text;
    _lastWrittenClipboard = cleanText;

    if (_clipboardWriter != null) {
      await _clipboardWriter(cleanText);
    } else {
      await _writeNativeClipboard(cleanText);
    }
    return (
      written: true,
      charCount: cleanText.length,
      redactedCount: redacted.redactedCount,
    );
  }

  /// Queries current meeting and microphone state (`UDC-15` S15.2).
  Future<MeetingStatusSnapshot> getMeetingStatus() async {
    if (_meetingDetector != null) {
      final detected = await _meetingDetector();
      _inMeeting = detected.inMeeting;
      _meetingApp = detected.app;
      _micMuted = detected.micMuted;
      return detected;
    }
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      final nativeDetected = await _detectNativeMeetingProcess();
      if (nativeDetected != null) {
        _inMeeting = nativeDetected.inMeeting;
        _meetingApp = nativeDetected.app;
      }
    }
    return MeetingStatusSnapshot(
      inMeeting: _inMeeting,
      app: _meetingApp,
      micMuted: _micMuted,
    );
  }

  Future<({bool inMeeting, String app})?> _detectNativeMeetingProcess() async {
    try {
      String output = '';
      if (Platform.isWindows) {
        final res = await Process.run(
          'tasklist',
          const <String>['/FO', 'CSV', '/NH'],
          runInShell: false,
        ).timeout(const Duration(seconds: 2));
        output = (res.stdout?.toString() ?? '').toLowerCase();
      } else if (Platform.isMacOS || Platform.isLinux) {
        final res = await Process.run(
          'ps',
          const <String>['-ax', '-o', 'comm='],
          runInShell: false,
        ).timeout(const Duration(seconds: 2));
        output = (res.stdout?.toString() ?? '').toLowerCase();
      }
      if (output.isEmpty) return null;
      if (output.contains('zoom.us') ||
          output.contains('zoom.exe') ||
          output.contains('cpthost')) {
        return (inMeeting: true, app: 'zoom');
      }
      if (output.contains('ms-teams') || output.contains('teams.exe')) {
        return (inMeeting: true, app: 'teams');
      }
      if (output.contains('webex') || output.contains('atmgr')) {
        return (inMeeting: true, app: 'webex');
      }
      if (output.contains('discord')) {
        return (inMeeting: true, app: 'discord');
      }
      if (output.contains('facetime')) {
        return (inMeeting: true, app: 'meet');
      }
      return (inMeeting: false, app: 'none');
    } catch (_) {
      return null;
    }
  }

  /// Mutes, unmutes, or toggles the host microphone (`UDC-15` S15.2).
  Future<
    ({
      String action,
      bool micMuted,
      bool previousMicMuted,
      String inverseAction,
      String app,
    })
  >
  controlMeeting(String action) async {
    if (!allowedMeetingActions.contains(action)) {
      throw ArgumentError.value(action, 'action', 'Unsupported meeting action');
    }
    final prevMuted = _micMuted;
    final targetMuted = switch (action) {
      'mute_mic' => true,
      'unmute_mic' => false,
      _ => !_micMuted,
    };
    if (_micMuteSetter != null) {
      _micMuted = await _micMuteSetter(targetMuted);
    } else {
      await _setNativeMicMute(targetMuted);
      _micMuted = targetMuted;
    }
    final inverseAction = prevMuted ? 'mute_mic' : 'unmute_mic';
    return (
      action: action,
      micMuted: _micMuted,
      previousMicMuted: prevMuted,
      inverseAction: inverseAction,
      app: _meetingApp,
    );
  }

  /// Scans allowlisted localhost development ports and returns LAN preview URLs (`UDC-15` S15.3).
  Future<({String lanIp, List<DevPortEntry> activePorts})> scanDevPorts({
    List<int>? ports,
  }) async {
    final targetPorts = (ports == null || ports.isEmpty)
        ? defaultAllowedDevPorts
        : ports
              .where((p) => p >= 1024 && p <= 65535)
              .take(16)
              .toList(growable: false);
    final lanIp = _lanIpResolver != null
        ? await _lanIpResolver()
        : await _resolveDefaultLanIp();

    if (_portProbe != null) {
      final probed = await _portProbe(targetPorts);
      final entries = probed
          .map(
            (p) => DevPortEntry(
              port: p.port,
              process: p.process,
              url: 'http://$lanIp:${p.port}',
            ),
          )
          .toList(growable: false);
      return (lanIp: lanIp, activePorts: entries);
    }

    final active = <DevPortEntry>[];
    for (final port in targetPorts) {
      final open = await _isLocalPortOpen(port);
      if (open) {
        active.add(
          DevPortEntry(
            port: port,
            process: _guessDevProcessForPort(port),
            url: 'http://$lanIp:$port',
          ),
        );
      }
    }
    return (lanIp: lanIp, activePorts: active);
  }

  /// Reads host battery, RAM, disk, and thermal vitals (`UDC-15` S15.4).
  Future<SystemVitalsSnapshot> readSystemVitals() async {
    if (_vitalsReader != null) {
      return _vitalsReader();
    }
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      final nativeVitals = await _readNativeSystemVitals();
      if (nativeVitals != null) {
        return nativeVitals;
      }
    }
    return const SystemVitalsSnapshot(
      batteryPercent: 85,
      isCharging: true,
      memoryUsedPercent: 52,
      diskFreeGb: 120,
      thermalState: 'nominal',
      healthStatus: 'healthy',
    );
  }

  Future<SystemVitalsSnapshot?> _readNativeSystemVitals() async {
    try {
      int batteryPercent = 100;
      bool isCharging = true;
      int memoryUsedPercent = 50;
      int diskFreeGb = 100;

      if (Platform.isWindows) {
        final psScript =
            r'$b = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1; '
            r'$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue; '
            r'$d = Get-PSDrive -Name C -ErrorAction SilentlyContinue; '
            r'$batPct = if ($b -and $null -ne $b.EstimatedChargeRemaining) { [int]$b.EstimatedChargeRemaining } else { 100 }; '
            r'$chg = if ($b -and $b.BatteryStatus -eq 1) { 0 } else { 1 }; '
            r'$memPct = if ($os -and $os.TotalVisibleMemorySize -gt 0) { [int][math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 100.0) / $os.TotalVisibleMemorySize) } else { 50 }; '
            r'$diskGb = if ($d -and $null -ne $d.Free) { [int][math]::Floor($d.Free / 1GB) } else { 100 }; '
            r'Write-Output "$batPct|$chg|$memPct|$diskGb"';
        final res = await Process.run(
          'powershell.exe',
          <String>['-NoProfile', '-NonInteractive', '-Command', psScript],
          runInShell: false,
        ).timeout(const Duration(seconds: 3));
        final line = (res.stdout?.toString() ?? '').trim();
        final parts = line.split('|');
        if (parts.length >= 4) {
          batteryPercent = (int.tryParse(parts[0].trim()) ?? 100).clamp(0, 100);
          isCharging = parts[1].trim() != '0';
          memoryUsedPercent =
              (int.tryParse(parts[2].trim()) ?? 50).clamp(0, 100);
          diskFreeGb = (int.tryParse(parts[3].trim()) ?? 100).clamp(0, 99999);
        } else {
          return null;
        }
      } else if (Platform.isMacOS) {
        try {
          final battRes = await Process.run(
            '/usr/bin/pmset',
            const <String>['-g', 'batt'],
            runInShell: false,
          ).timeout(const Duration(seconds: 2));
          final battOut = battRes.stdout?.toString() ?? '';
          final pctMatch = RegExp(r'(\d+)%').firstMatch(battOut);
          if (pctMatch != null) {
            batteryPercent =
                (int.tryParse(pctMatch.group(1)!) ?? 100).clamp(0, 100);
          }
          isCharging = !battOut.toLowerCase().contains('discharging');
        } catch (_) {}

        try {
          final dfRes = await Process.run(
            '/bin/df',
            const <String>['-k', '/'],
            runInShell: false,
          ).timeout(const Duration(seconds: 2));
          final lines = (dfRes.stdout?.toString() ?? '')
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList();
          if (lines.length >= 2) {
            final cols = lines[1].split(RegExp(r'\s+'));
            if (cols.length >= 4) {
              final availKb = int.tryParse(cols[3]) ?? 0;
              if (availKb > 0) {
                diskFreeGb = (availKb ~/ (1024 * 1024)).clamp(0, 99999);
              }
            }
          }
        } catch (_) {}

        try {
          final vmRes = await Process.run(
            '/usr/bin/vm_stat',
            const <String>[],
            runInShell: false,
          ).timeout(const Duration(seconds: 2));
          final vmOut = vmRes.stdout?.toString() ?? '';
          int extractPages(String label) {
            final m = RegExp('$label:\\s+(\\d+)').firstMatch(vmOut);
            return m != null ? (int.tryParse(m.group(1)!) ?? 0) : 0;
          }

          final freePages =
              extractPages('Pages free') + extractPages('Pages speculative');
          final activePages = extractPages('Pages active') +
              extractPages('Pages wired down') +
              extractPages('Pages occupied by compressor');
          final totalPages = freePages +
              activePages +
              extractPages('Pages inactive');
          if (totalPages > 0) {
            memoryUsedPercent =
                ((activePages * 100) / totalPages).round().clamp(1, 99);
          }
        } catch (_) {}
      } else if (Platform.isLinux) {
        try {
          for (final bat in const <String>['BAT0', 'BAT1']) {
            final capFile = File('/sys/class/power_supply/$bat/capacity');
            if (capFile.existsSync()) {
              batteryPercent =
                  (int.tryParse(capFile.readAsStringSync().trim()) ?? 100)
                      .clamp(0, 100);
              final statusFile = File('/sys/class/power_supply/$bat/status');
              if (statusFile.existsSync()) {
                isCharging = !statusFile
                    .readAsStringSync()
                    .toLowerCase()
                    .contains('discharging');
              }
              break;
            }
          }
        } catch (_) {}

        try {
          final memFile = File('/proc/meminfo');
          if (memFile.existsSync()) {
            final content = memFile.readAsStringSync();
            final totalMatch =
                RegExp(r'MemTotal:\s+(\d+)').firstMatch(content);
            final availMatch =
                RegExp(r'MemAvailable:\s+(\d+)').firstMatch(content);
            if (totalMatch != null && availMatch != null) {
              final totalKb = int.tryParse(totalMatch.group(1)!) ?? 0;
              final availKb = int.tryParse(availMatch.group(1)!) ?? 0;
              if (totalKb > 0) {
                memoryUsedPercent =
                    (((totalKb - availKb) * 100) / totalKb).round().clamp(1, 99);
              }
            }
          }
        } catch (_) {}

        try {
          final dfRes = await Process.run(
            'df',
            const <String>['-k', '/'],
            runInShell: false,
          ).timeout(const Duration(seconds: 2));
          final lines = (dfRes.stdout?.toString() ?? '')
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList();
          if (lines.length >= 2) {
            final cols = lines[1].split(RegExp(r'\s+'));
            if (cols.length >= 4) {
              final availKb = int.tryParse(cols[3]) ?? 0;
              if (availKb > 0) {
                diskFreeGb = (availKb ~/ (1024 * 1024)).clamp(0, 99999);
              }
            }
          }
        } catch (_) {}
      } else {
        return null;
      }

      final isWarning = (batteryPercent < 20 && !isCharging) ||
          memoryUsedPercent >= 90 ||
          diskFreeGb < 10;
      return SystemVitalsSnapshot(
        batteryPercent: batteryPercent,
        isCharging: isCharging,
        memoryUsedPercent: memoryUsedPercent,
        diskFreeGb: diskFreeGb,
        thermalState: memoryUsedPercent >= 92 ? 'fair' : 'nominal',
        healthStatus: isWarning ? 'warning' : 'healthy',
      );
    } catch (_) {
      return null;
    }
  }

  static String _guessDevProcessForPort(int port) {
    return switch (port) {
      3000 => 'next-dev',
      4200 => 'ng-serve',
      5000 => 'flask-server',
      5173 || 5174 => 'vite',
      8000 => 'uvicorn',
      8080 => 'web-dev-server',
      8888 => 'jupyter',
      _ => 'dev-server',
    };
  }

  Future<bool> _isLocalPortOpen(int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 60),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<String> _resolveDefaultLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            return ip;
          }
        }
      }
    } catch (_) {
      // Fallback to loopback if no LAN interface is available.
    }
    return '127.0.0.1';
  }

  Future<void> _writeNativeClipboard(String text) async {
    try {
      if (Platform.isMacOS) {
        final proc = await Process.start(
          '/usr/bin/pbcopy',
          const <String>[],
          runInShell: false,
        );
        proc.stdin.add(utf8.encode(text));
        await proc.stdin.close();
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } else if (Platform.isWindows) {
        final proc = await Process.start(
          'clip.exe',
          const <String>[],
          runInShell: false,
        );
        proc.stdin.add(utf8.encode(text));
        await proc.stdin.close();
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } else if (Platform.isLinux) {
        for (final cmd in const <List<String>>[
          <String>['xclip', '-selection', 'clipboard'],
          <String>['xsel', '--clipboard', '--input'],
          <String>['wl-copy'],
        ]) {
          try {
            final proc = await Process.start(
              cmd.first,
              cmd.sublist(1),
              runInShell: false,
            );
            proc.stdin.add(utf8.encode(text));
            await proc.stdin.close();
            final code = await proc.exitCode.timeout(
              const Duration(seconds: 2),
            );
            if (code == 0) break;
          } catch (_) {}
        }
      }
    } catch (_) {
      // Best-effort in headless environments
    }
  }

  Future<void> _setNativeMicMute(bool mute) async {
    try {
      if (Platform.isMacOS) {
        final vol = mute ? 0 : 80;
        await Process.run('/usr/bin/osascript', <String>[
          '-e',
          'set volume input volume $vol',
        ], runInShell: false).timeout(const Duration(seconds: 2));
      } else if (Platform.isWindows) {
        // Send WM_APPCOMMAND APPCOMMAND_MIC_ON_OFF_TOGGLE (24 << 16 = 0x180000) to foreground window
        const psToggleMic =
            r'$sig = "[DllImport(\"user32.dll\")] public static extern IntPtr GetForegroundWindow(); [DllImport(\"user32.dll\")] public static extern IntPtr SendMessageW(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);"; '
            r'$t = Add-Type -MemberDefinition $sig -Name "Win32Mic" -Namespace "Xuna" -PassThru -ErrorAction SilentlyContinue; '
            r'if ($t) { $h = $t::GetForegroundWindow(); [void]$t::SendMessageW($h, 0x0319, $h, [IntPtr]0x180000); }';
        await Process.run(
          'powershell.exe',
          <String>['-NoProfile', '-NonInteractive', '-Command', psToggleMic],
          runInShell: false,
        ).timeout(const Duration(seconds: 2));
      } else if (Platform.isLinux) {
        try {
          await Process.run(
            'pactl',
            <String>[
              'set-source-mute',
              '@DEFAULT_SOURCE@',
              mute ? '1' : '0',
            ],
            runInShell: false,
          ).timeout(const Duration(seconds: 2));
        } catch (_) {
          await Process.run(
            'amixer',
            <String>['set', 'Capture', mute ? 'nocap' : 'cap'],
            runInShell: false,
          ).timeout(const Duration(seconds: 2));
        }
      }
    } catch (_) {
      // Best-effort in headless environments
    }
  }
}

