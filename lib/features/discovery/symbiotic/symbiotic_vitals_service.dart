import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'symbiotic_models.dart';

/// Symbiotic Co-Pilot service for Clipboard, Dev Ports, and System Vitals (`UDC-15`).
class SymbioticVitalsService {
  SymbioticVitalsService({
    Future<void> Function(String text)? clipboardWriter,
    Future<List<({int port, String process})>> Function(List<int> ports)?
    portProbe,
    Future<String> Function()? lanIpResolver,
    Future<SystemVitalsSnapshot> Function()? vitalsReader,
  }) : _clipboardWriter = clipboardWriter,
       _portProbe = portProbe,
       _lanIpResolver = lanIpResolver,
       _vitalsReader = vitalsReader;

  final Future<void> Function(String text)? _clipboardWriter;
  final Future<List<({int port, String process})>> Function(List<int> ports)?
  _portProbe;
  final Future<String> Function()? _lanIpResolver;
  final Future<SystemVitalsSnapshot> Function()? _vitalsReader;

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
            // The OS owner of the port is not probed; do not invent one from the number.
            process: 'unknown',
            url: 'http://$lanIp:$port',
          ),
        );
      }
    }
    return (lanIp: lanIp, activePorts: active);
  }

  /// Reads host battery, RAM and free-disk vitals (`UDC-15` S15.4).
  ///
  /// Only values that were really measured are returned; a metric the host cannot
  /// read (for example the battery of a desktop) stays `null`. When nothing could be
  /// measured the call fails with `unsupported` instead of reporting placeholders.
  Future<SystemVitalsSnapshot> readSystemVitals() async {
    if (_vitalsReader != null) {
      return _vitalsReader();
    }
    final snapshot = await _readNativeSystemVitals();
    if (snapshot == null || !snapshot.hasAnyMeasurement) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'vitals_unavailable',
        message: 'This host could not measure battery, memory or disk.',
      );
    }
    return snapshot;
  }

  static int? _percentOrNull(int? value) => value?.clamp(0, 100);

  Future<int?> _freeDiskGbViaDf(String dfExecutable) async {
    try {
      final dfRes = await Process.run(
        dfExecutable,
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
          final availKb = int.tryParse(cols[3]);
          if (availKb != null && availKb > 0) {
            return (availKb ~/ (1024 * 1024)).clamp(0, 99999);
          }
        }
      }
    } catch (_) {
      // A failed probe means "not measured", reported as null by the caller.
    }
    return null;
  }

  Future<SystemVitalsSnapshot?> _readNativeSystemVitals() async {
    int? batteryPercent;
    bool? isCharging;
    int? memoryUsedPercent;
    int? diskFreeGb;

    try {
      if (Platform.isWindows) {
        const psScript =
            r'$b = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1; '
            r'$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue; '
            r'$d = Get-PSDrive -Name C -ErrorAction SilentlyContinue; '
            r'$batPct = if ($b -and $null -ne $b.EstimatedChargeRemaining) { [int]$b.EstimatedChargeRemaining } else { "" }; '
            r'$chg = if ($b -and $null -ne $b.BatteryStatus) { if ($b.BatteryStatus -eq 1) { 0 } else { 1 } } else { "" }; '
            r'$memPct = if ($os -and $os.TotalVisibleMemorySize -gt 0) { [int][math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 100.0) / $os.TotalVisibleMemorySize) } else { "" }; '
            r'$diskGb = if ($d -and $null -ne $d.Free) { [int][math]::Floor($d.Free / 1GB) } else { "" }; '
            r'Write-Output "$batPct|$chg|$memPct|$diskGb"';
        final res = await Process.run(
          'powershell.exe',
          const <String>['-NoProfile', '-NonInteractive', '-Command', psScript],
          runInShell: false,
        ).timeout(const Duration(seconds: 3));
        final parts = (res.stdout?.toString() ?? '').trim().split('|');
        if (parts.length < 4) return null;
        batteryPercent = _percentOrNull(int.tryParse(parts[0].trim()));
        final chg = int.tryParse(parts[1].trim());
        isCharging = batteryPercent == null || chg == null ? null : chg != 0;
        memoryUsedPercent = _percentOrNull(int.tryParse(parts[2].trim()));
        final disk = int.tryParse(parts[3].trim());
        diskFreeGb = disk?.clamp(0, 99999);
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
            batteryPercent = _percentOrNull(int.tryParse(pctMatch.group(1)!));
            isCharging = batteryPercent == null
                ? null
                : !battOut.toLowerCase().contains('discharging');
          }
        } catch (_) {
          // No battery information: leave null.
        }
        diskFreeGb = await _freeDiskGbViaDf('/bin/df');
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
          final totalPages =
              freePages + activePages + extractPages('Pages inactive');
          if (totalPages > 0) {
            memoryUsedPercent =
                ((activePages * 100) / totalPages).round().clamp(1, 99);
          }
        } catch (_) {
          // vm_stat unavailable: leave null.
        }
      } else if (Platform.isLinux) {
        try {
          for (final bat in const <String>['BAT0', 'BAT1']) {
            final capFile = File('/sys/class/power_supply/$bat/capacity');
            if (capFile.existsSync()) {
              batteryPercent = _percentOrNull(
                int.tryParse(capFile.readAsStringSync().trim()),
              );
              final statusFile = File('/sys/class/power_supply/$bat/status');
              if (batteryPercent != null && statusFile.existsSync()) {
                isCharging = !statusFile
                    .readAsStringSync()
                    .toLowerCase()
                    .contains('discharging');
              }
              break;
            }
          }
        } catch (_) {
          // No battery information: leave null.
        }
        try {
          final memFile = File('/proc/meminfo');
          if (memFile.existsSync()) {
            final content = memFile.readAsStringSync();
            final totalMatch = RegExp(r'MemTotal:\s+(\d+)').firstMatch(content);
            final availMatch =
                RegExp(r'MemAvailable:\s+(\d+)').firstMatch(content);
            if (totalMatch != null && availMatch != null) {
              final totalKb = int.tryParse(totalMatch.group(1)!) ?? 0;
              final availKb = int.tryParse(availMatch.group(1)!) ?? 0;
              if (totalKb > 0) {
                memoryUsedPercent = (((totalKb - availKb) * 100) / totalKb)
                    .round()
                    .clamp(1, 99);
              }
            }
          }
        } catch (_) {
          // /proc/meminfo unreadable: leave null.
        }
        diskFreeGb = await _freeDiskGbViaDf('df');
      } else {
        return null;
      }
    } catch (_) {
      return null;
    }

    final isWarning =
        (batteryPercent != null && batteryPercent < 20 && isCharging == false) ||
            (memoryUsedPercent != null && memoryUsedPercent >= 90) ||
            (diskFreeGb != null && diskFreeGb < 10);
    final measured =
        batteryPercent != null || memoryUsedPercent != null || diskFreeGb != null;
    return SystemVitalsSnapshot(
      batteryPercent: batteryPercent,
      isCharging: isCharging,
      memoryUsedPercent: memoryUsedPercent,
      diskFreeGb: diskFreeGb,
      healthStatus: !measured ? 'unknown' : (isWarning ? 'warning' : 'healthy'),
    );
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
}
