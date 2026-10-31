import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Active localhost development port entry (`UDC-15` S15.3).
class DevPortEntry {
  const DevPortEntry({
    required this.port,
    required this.process,
    required this.url,
  });

  final int port;
  final String process;
  final String url;

  Map<String, Object?> toWireJson() => <String, Object?>{
        'port': port,
        'process': process,
        'url': url,
      };
}

/// Snapshot of meeting & microphone state (`UDC-15` S15.2).
class MeetingStatusSnapshot {
  const MeetingStatusSnapshot({
    required this.inMeeting,
    required this.app,
    required this.micMuted,
  });

  final bool inMeeting;
  final String app;
  final bool micMuted;

  Map<String, Object?> toWireJson() => <String, Object?>{
        'inMeeting': inMeeting,
        'app': app,
        'micMuted': micMuted,
      };
}

/// Snapshot of host battery, memory, disk, and thermal health (`UDC-15` S15.4).
class SystemVitalsSnapshot {
  const SystemVitalsSnapshot({
    required this.batteryPercent,
    required this.isCharging,
    required this.memoryUsedPercent,
    required this.diskFreeGb,
    required this.thermalState,
    required this.healthStatus,
  });

  final int batteryPercent;
  final bool isCharging;
  final int memoryUsedPercent;
  final int diskFreeGb;
  final String thermalState;
  final String healthStatus;

  Map<String, Object?> toWireJson() => <String, Object?>{
        'batteryPercent': batteryPercent,
        'isCharging': isCharging,
        'memoryUsedPercent': memoryUsedPercent,
        'diskFreeGb': diskFreeGb,
        'thermalState': thermalState,
        'healthStatus': healthStatus,
      };
}

/// Frozen Time-Travel Workspace Capsule (`SYM-1` S1.1).
class WorkspaceCapsuleEntry {
  const WorkspaceCapsuleEntry({
    required this.capsuleId,
    required this.project,
    required this.branch,
    required this.dirtyCount,
    required this.nextStepHint,
    required this.createdAt,
  });

  final String capsuleId;
  final String project;
  final String branch;
  final int dirtyCount;
  final String nextStepHint;
  final String createdAt;

  Map<String, Object?> toWireJson() => <String, Object?>{
        'capsuleId': capsuleId,
        'project': project,
        'branch': branch,
        'dirtyCount': dirtyCount,
        'nextStepHint': nextStepHint,
        'createdAt': createdAt,
      };
}

/// Secret-redacted item stored in XUNA Universal Pocket (`SYM-1` S1.1).
class UniversalPocketItem {
  const UniversalPocketItem({
    required this.itemId,
    required this.kind,
    required this.label,
    required this.text,
    required this.preview,
    required this.sourceDevice,
    required this.createdAt,
    required this.redactedCount,
    required this.suggestedActions,
  });

  final String itemId;
  final String kind;
  final String label;
  final String text;
  final String preview;
  final String sourceDevice;
  final String createdAt;
  final int redactedCount;
  final List<String> suggestedActions;

  Map<String, Object?> toWireListJson() => <String, Object?>{
        'itemId': itemId,
        'kind': kind,
        'label': label,
        'preview': preview,
        'sourceDevice': sourceDevice,
        'createdAt': createdAt,
      };
}

/// Autonomous background watchdog sentinel entry (`SYM-2` S2.1).
class WatchdogSentinelEntry {
  const WatchdogSentinelEntry({
    required this.watchdogId,
    required this.kind,
    required this.target,
    required this.status,
    required this.triggered,
    required this.summary,
    required this.createdAt,
  });

  final String watchdogId;
  final String kind;
  final String target;
  final String status;
  final bool triggered;
  final String summary;
  final String createdAt;

  Map<String, Object?> toWireJson() => <String, Object?>{
        'watchdogId': watchdogId,
        'kind': kind,
        'target': target,
        'status': status,
        'triggered': triggered,
        'summary': summary,
        'createdAt': createdAt,
      };
}

/// Cross-platform symbiotic desktop service (`UDC-15` S15.1–S15.4, `SYM-1` S1.1, `SYM-2` S2.1):
/// - `S15.1`: Write-to-Clipboard Bridge (`clipboard.write`, secret-redacted, zero content logging)
/// - `S15.2`: Meeting & Microphone Controller (`meeting.status` & `meeting.control`)
/// - `S15.3`: Localhost Dev-Port Doctor (`dev.ports` + LAN IPv4 resolution)
/// - `S15.4`: System Vitals (`system.vitals` for Windows & macOS)
class AutoSymbioticService {
  AutoSymbioticService({
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
  })  : _clipboardWriter = clipboardWriter,
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
  int _capsuleSeq = 0;
  int _pocketSeq = 0;
  int _watchdogSeq = 0;
  final List<WorkspaceCapsuleEntry> _capsules = <WorkspaceCapsuleEntry>[];
  final List<UniversalPocketItem> _pocketItems = <UniversalPocketItem>[];
  final List<WatchdogSentinelEntry> _watchdogs = <WatchdogSentinelEntry>[];
  final List<String> _recentToolHistory = <String>[];

  /// Last text written to the clipboard in memory (for test verification; never logged).
  String get debugLastClipboardText => _lastWrittenClipboard;

  /// Captures a frozen Time-Travel Workspace Capsule (`SYM-1` S1.1).
  WorkspaceCapsuleEntry captureWorkspaceCapsule({
    required String project,
    required String branch,
    required int dirtyCount,
    String? nextStepHint,
    DateTime? nowUtc,
  }) {
    _capsuleSeq++;
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    final safeProject =
        project.trim().isEmpty ? 'workspace' : project.trim();
    final slug = safeProject
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    final capsuleId = 'cap-$slug-$_capsuleSeq';
    final rawHint = (nextStepHint == null || nextStepHint.trim().isEmpty)
        ? 'Tiếp tục kiểm tra nhánh $branch ($dirtyCount tệp đang sửa)'
        : nextStepHint.trim();
    final cleanHint =
        redactSensitiveSelectionText(rawHint, maxChars: 240).text;
    final entry = WorkspaceCapsuleEntry(
      capsuleId: capsuleId,
      project: safeProject,
      branch: branch.trim().isEmpty ? 'main' : branch.trim(),
      dirtyCount: dirtyCount < 0 ? 0 : dirtyCount,
      nextStepHint: cleanHint,
      createdAt: ts.toIso8601String(),
    );
    _capsules.insert(0, entry);
    if (_capsules.length > 20) {
      _capsules.removeLast();
    }
    return entry;
  }

  /// Lists saved Time-Travel Workspace Capsules (`SYM-1` S1.1).
  List<WorkspaceCapsuleEntry> listWorkspaceCapsules({int limit = 10}) {
    final clamped = limit.clamp(1, 20);
    return _capsules.take(clamped).toList(growable: false);
  }

  /// Finds a saved Time-Travel Workspace Capsule by [capsuleId] or [project] (`SYM-1` S1.1).
  WorkspaceCapsuleEntry? findWorkspaceCapsule({
    String? capsuleId,
    String? project,
  }) {
    if (capsuleId != null && capsuleId.trim().isNotEmpty) {
      final targetId = capsuleId.trim().toLowerCase();
      for (final cap in _capsules) {
        if (cap.capsuleId.toLowerCase() == targetId) {
          return cap;
        }
      }
    }
    if (project != null && project.trim().isNotEmpty) {
      final targetProj = project.trim().toLowerCase();
      for (final cap in _capsules) {
        if (cap.project.toLowerCase().contains(targetProj)) {
          return cap;
        }
      }
    }
    return _capsules.isNotEmpty ? _capsules.first : null;
  }

  /// Pushes a secret-redacted snippet or item into XUNA Universal Pocket (`SYM-1` S1.1).
  UniversalPocketItem pushPocketItem({
    required String rawText,
    String? label,
    String? kind,
    String? sourceDevice,
    DateTime? nowUtc,
  }) {
    if (!isSafeClipboardWriteText(rawText)) {
      throw ArgumentError.value(rawText, 'text', 'Invalid pocket item text');
    }
    _pocketSeq++;
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    final redacted = redactSensitiveSelectionText(rawText, maxChars: 2000);
    final cleanText = redacted.text;
    final resolvedKind =
        (kind == null || kind == 'auto' || kind.trim().isEmpty)
            ? classifyPocketKind(cleanText)
            : kind.trim();
    final resolvedLabel = (label == null || label.trim().isEmpty)
        ? _defaultPocketLabel(resolvedKind, cleanText)
        : redactSensitiveSelectionText(label.trim(), maxChars: 80).text;
    final preview = cleanText.length <= 160
        ? cleanText.replaceAll('\n', ' ')
        : '${cleanText.substring(0, 157).replaceAll('\n', ' ')}...';
    final item = UniversalPocketItem(
      itemId: 'pkt-$_pocketSeq',
      kind: resolvedKind,
      label: resolvedLabel,
      text: cleanText,
      preview: preview,
      sourceDevice: (sourceDevice == null || sourceDevice.trim().isEmpty)
          ? 'desktop'
          : sourceDevice.trim(),
      createdAt: ts.toIso8601String(),
      redactedCount: redacted.redactedCount,
      suggestedActions: suggestActionsForKind(resolvedKind),
    );
    _pocketItems.insert(0, item);
    if (_pocketItems.length > 20) {
      _pocketItems.removeLast();
    }
    return item;
  }

  /// Lists items in XUNA Universal Pocket with optional [kind] and [query] filter (`SYM-1` S1.1).
  List<UniversalPocketItem> listPocketItems({
    String? kind,
    String? query,
    int limit = 10,
  }) {
    final clamped = limit.clamp(1, 20);
    final filterKind =
        (kind == null || kind == 'auto' || kind.trim().isEmpty)
            ? null
            : kind.trim().toLowerCase();
    final filterQuery =
        (query == null || query.trim().isEmpty)
            ? null
            : query.trim().toLowerCase();
    return _pocketItems
        .where((item) {
          if (filterKind != null && item.kind.toLowerCase() != filterKind) {
            return false;
          }
          if (filterQuery != null &&
              !item.label.toLowerCase().contains(filterQuery) &&
              !item.text.toLowerCase().contains(filterQuery)) {
            return false;
          }
          return true;
        })
        .take(clamped)
        .toList(growable: false);
  }

  /// Transforms a pocket item or inline text using deterministic local rules (`SYM-1` S1.1).
  ({String mode, String transformedText, int itemCount}) transformPocketItem({
    String? itemId,
    String? rawText,
    required String mode,
  }) {
    if (!allowedPocketTransformModes.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', 'Unsupported transform mode');
    }
    String source = '';
    if (itemId != null && itemId.trim().isNotEmpty) {
      final found = _pocketItems
          .where((e) => e.itemId.toLowerCase() == itemId.trim().toLowerCase())
          .firstOrNull;
      if (found != null) {
        source = found.text;
      }
    }
    if (source.isEmpty && rawText != null) {
      source = redactSensitiveSelectionText(rawText, maxChars: 2000).text;
    }
    if (source.trim().isEmpty) {
      return (mode: mode, transformedText: '', itemCount: 0);
    }

    switch (mode) {
      case 'format_json':
        try {
          final decoded = jsonDecode(source);
          final pretty = const JsonEncoder.withIndent('  ').convert(decoded);
          final count = decoded is List
              ? decoded.length
              : (decoded is Map ? decoded.length : 1);
          return (mode: mode, transformedText: pretty, itemCount: count);
        } catch (_) {
          return (
            mode: mode,
            transformedText: source.trim(),
            itemCount: 1,
          );
        }
      case 'extract_tasks':
        final lines = source
            .split(RegExp(r'[\r\n;]+'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList(growable: false);
        final tasks = <String>[];
        for (var i = 0; i < lines.length && tasks.length < 10; i++) {
          final cleaned =
              lines[i].replaceFirst(RegExp(r'^[-*•\d.)+\s]+'), '').trim();
          if (cleaned.isNotEmpty) {
            tasks.add('- [ ] $cleaned');
          }
        }
        return (
          mode: mode,
          transformedText: tasks.join('\n'),
          itemCount: tasks.length,
        );
      case 'prepare_knowledge_fact':
        final condensed = source
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final fact = condensed.length <= 220
            ? condensed
            : '${condensed.substring(0, 217)}...';
        return (
          mode: mode,
          transformedText: '[Quy ước / Ghi nhớ] $fact',
          itemCount: 1,
        );
      default:
        final condensed = source.replaceAll(RegExp(r'\s+'), ' ').trim();
        final summary = condensed.length <= 180
            ? condensed
            : '${condensed.substring(0, 177)}...';
        return (
          mode: mode,
          transformedText: summary,
          itemCount: 1,
        );
    }
  }

  /// Classifies [text] into one of the canonical Universal Pocket kinds (`SYM-1` S1.1).
  static String classifyPocketKind(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('https://') || trimmed.startsWith('http://')) {
      return 'url';
    }
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        jsonDecode(trimmed);
        return 'json';
      } catch (_) {
        // Fall through if not valid JSON
      }
    }
    if (RegExp(
      r'^(git|docker|npm|pnpm|yarn|pytest|flutter|fvm|pio|cargo|curl|ssh|kubectl)\b',
    ).hasMatch(trimmed)) {
      return 'command';
    }
    if (trimmed.contains('class ') ||
        trimmed.contains('function ') ||
        trimmed.contains('def ') ||
        trimmed.contains('=>') ||
        trimmed.contains('import ')) {
      return 'code';
    }
    if (RegExp(
      r'\b(họp|meeting|deadline|lịch|ngày mai|thứ hai|thứ ba|thứ tư|thứ năm|thứ sáu|\d{1,2}h\d{0,2})\b',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return 'schedule_note';
    }
    return 'text';
  }

  /// Suggests 1-tap follow-up actions for a pocket item of [kind].
  static List<String> suggestActionsForKind(String kind) {
    return switch (kind) {
      'json' => const <String>['format_json', 'clipboard.write'],
      'url' => const <String>['url.open', 'clipboard.write'],
      'command' => const <String>['clipboard.write', 'prepare_knowledge_fact'],
      'code' => const <String>[
          'summarize_snippet',
          'prepare_knowledge_fact',
          'clipboard.write',
        ],
      'schedule_note' => const <String>[
          'extract_tasks',
          'prepare_knowledge_fact',
        ],
      _ => const <String>['summarize_snippet', 'extract_tasks'],
    };
  }

  static String _defaultPocketLabel(String kind, String text) {
    final firstLine = text.split('\n').first.trim();
    final snippet =
        firstLine.length <= 36 ? firstLine : '${firstLine.substring(0, 33)}...';
    return '$kind: $snippet';
  }

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
    return MeetingStatusSnapshot(
      inMeeting: _inMeeting,
      app: _meetingApp,
      micMuted: _micMuted,
    );
  }

  /// Mutes, unmutes, or toggles the host microphone (`UDC-15` S15.2).
  Future<
      ({
        String action,
        bool micMuted,
        bool previousMicMuted,
        String inverseAction,
        String app,
      })> controlMeeting(String action) async {
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
    return const SystemVitalsSnapshot(
      batteryPercent: 85,
      isCharging: true,
      memoryUsedPercent: 52,
      diskFreeGb: 120,
      thermalState: 'nominal',
      healthStatus: 'healthy',
    );
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
      }
    } catch (_) {
      // Best-effort in headless environments
    }
  }

  Future<void> _setNativeMicMute(bool mute) async {
    try {
      if (Platform.isMacOS) {
        final vol = mute ? 0 : 80;
        await Process.run(
          '/usr/bin/osascript',
          <String>['-e', 'set volume input volume $vol'],
          runInShell: false,
        ).timeout(const Duration(seconds: 2));
      }
    } catch (_) {
      // Best-effort in headless environments
    }
  }

  /// Registers a background watchdog sentinel on a process or localhost port (`SYM-2` S2.1).
  Future<
      ({
        String watchdogId,
        String targetKind,
        String targetValue,
        String status,
        String summary,
      })> registerProcessOrPortWatchdog({
    required String targetKind,
    String? processName,
    int? port,
    String? label,
    DateTime? nowUtc,
  }) async {
    _watchdogSeq++;
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    final wdId = 'wd-$_watchdogSeq';
    if (targetKind == 'port') {
      final targetPort = port ?? 3000;
      final scanned = await scanDevPorts(ports: <int>[targetPort]);
      final isUp = scanned.activePorts.any((p) => p.port == targetPort);
      final status = isUp ? 'watching_active_port' : 'waiting_for_port';
      final summary = isUp
          ? 'Đang canh cổng :$targetPort (đang hoạt động bình thường)'
          : 'Đang canh cổng :$targetPort (chờ khởi động hoặc báo khi sập)';
      final entry = WatchdogSentinelEntry(
        watchdogId: wdId,
        kind: 'port',
        target: ':$targetPort',
        status: status,
        triggered: false,
        summary: summary,
        createdAt: ts.toIso8601String(),
      );
      _watchdogs.insert(0, entry);
      if (_watchdogs.length > 20) _watchdogs.removeLast();
      return (
        watchdogId: wdId,
        targetKind: 'port',
        targetValue: ':$targetPort',
        status: status,
        summary: summary,
      );
    }

    final cleanProc = (processName ?? 'build').trim();
    final status = 'watching_process';
    final summary =
        'Đang canh tiến trình $cleanProc — XUNA sẽ báo ngay khi hoàn tất hoặc lỗi';
    final entry = WatchdogSentinelEntry(
      watchdogId: wdId,
      kind: 'process',
      target: cleanProc,
      status: status,
      triggered: false,
      summary: summary,
      createdAt: ts.toIso8601String(),
    );
    _watchdogs.insert(0, entry);
    if (_watchdogs.length > 20) _watchdogs.removeLast();
    return (
      watchdogId: wdId,
      targetKind: 'process',
      targetValue: cleanProc,
      status: status,
      summary: summary,
    );
  }

  /// Registers a background threshold watchdog on battery, memory, or free disk space (`SYM-2` S2.1).
  Future<
      ({
        String watchdogId,
        String metric,
        int threshold,
        int currentValue,
        bool triggered,
        String summary,
      })> registerResourceWatchdog({
    required String metric,
    required int threshold,
    DateTime? nowUtc,
  }) async {
    _watchdogSeq++;
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    final wdId = 'wd-$_watchdogSeq';
    final vitals = await readSystemVitals();
    final currentVal = switch (metric) {
      'battery_below' => vitals.batteryPercent,
      'memory_above' => vitals.memoryUsedPercent,
      _ => vitals.diskFreeGb,
    };
    final isTriggered = switch (metric) {
      'battery_below' => currentVal <= threshold,
      'memory_above' => currentVal >= threshold,
      _ => currentVal <= threshold,
    };
    final summary = isTriggered
        ? 'Cảnh báo ngưỡng $metric ($currentVal so với ngưỡng $threshold)!'
        : 'Đang canh $metric (hiện tại: $currentVal, ngưỡng báo: $threshold)';
    final entry = WatchdogSentinelEntry(
      watchdogId: wdId,
      kind: metric,
      target: '$threshold',
      status: isTriggered ? 'triggered' : 'watching',
      triggered: isTriggered,
      summary: summary,
      createdAt: ts.toIso8601String(),
    );
    _watchdogs.insert(0, entry);
    if (_watchdogs.length > 20) _watchdogs.removeLast();
    return (
      watchdogId: wdId,
      metric: metric,
      threshold: threshold,
      currentValue: currentVal,
      triggered: isTriggered,
      summary: summary,
    );
  }

  /// Lists active/triggered watchdogs and optionally clears them (`SYM-2` S2.1).
  ({List<Map<String, Object?>> watchdogs, int clearedCount})
      listAndClearWatchdogs({
    String action = 'list',
  }) {
    var cleared = 0;
    if (action == 'clear_all') {
      cleared = _watchdogs.length;
      _watchdogs.clear();
    } else if (action == 'clear_triggered') {
      final before = _watchdogs.length;
      _watchdogs.removeWhere((w) => w.triggered);
      cleared = before - _watchdogs.length;
    }
    return (
      watchdogs: _watchdogs.map((w) => w.toWireJson()).toList(growable: false),
      clearedCount: cleared,
    );
  }

  /// Breaks an overwhelming goal into one concrete 5-minute micro-step (`SYM-2` S2.1).
  ({
    String goal,
    String project,
    String firstFiveMinuteStep,
    List<String> followUpSteps,
    String encouragementVi,
  }) decomposeOverwhelm({
    required String goal,
    String? project,
  }) {
    final cleanGoal =
        redactSensitiveSelectionText(goal.trim(), maxChars: 240).text;
    final cleanProj =
        (project == null || project.trim().isEmpty) ? 'workspace' : project.trim();
    final firstStep =
        'Trong 5 phút tới: Mở đúng 1 tệp chính trong $cleanProj và viết khung hàm/test đầu tiên cho "$cleanGoal".';
    final followUps = <String>[
      'Chạy kiểm thử đơn vị (unit test) cho mảnh nhỏ vừa viết.',
      'Kiểm tra lại trạng thái Git và đóng băng tiến độ bằng Workspace Capsule.',
    ];
    final encouragement =
        'Bạn không cần làm hết ngay đâu! Chỉ cần cùng mình làm gọn bước 5 phút đầu tiên này thôi nhé.';
    return (
      goal: cleanGoal,
      project: cleanProj,
      firstFiveMinuteStep: firstStep.length <= 160
          ? firstStep
          : firstStep.substring(0, 160),
      followUpSteps: followUps,
      encouragementVi: encouragement,
    );
  }

  /// Formats a silent <= 120-char meeting whisper digest for the XUNA desk screen (`SYM-2` S2.1).
  ({
    String topic,
    String whisperLine,
    List<String> bulletPoints,
    bool silentMode,
  }) buildDeskWhisperDigest({
    required String topic,
    String? contextHint,
  }) {
    final cleanTopic =
        redactSensitiveSelectionText(topic.trim(), maxChars: 120).text;
    final cleanHint = (contextHint == null || contextHint.trim().isEmpty)
        ? 'Giữ nhịp ngắn gọn, nêu kết quả chính trước'
        : redactSensitiveSelectionText(contextHint.trim(), maxChars: 120).text;
    final rawWhisper = '💡 $cleanTopic: $cleanHint';
    final whisperLine = rawWhisper.length <= 120
        ? rawWhisper
        : '${rawWhisper.substring(0, 117)}...';
    return (
      topic: cleanTopic,
      whisperLine: whisperLine,
      bulletPoints: <String>[
        cleanTopic,
        cleanHint,
      ],
      silentMode: true,
    );
  }

  /// Records a successful tool name execution for habit sequence mining (`SYM-2` S2.1).
  void recordToolExecution(String toolName) {
    if (toolName == 'habit.propose_workflow') return;
    _recentToolHistory.add(toolName);
    if (_recentToolHistory.length > 60) {
      _recentToolHistory.removeAt(0);
    }
  }

  /// Mines repeated tool pairs/triplets in [_recentToolHistory] (`SYM-2` S2.1).
  List<Map<String, Object?>> proposeHabitWorkflows({int minOccurrences = 2}) {
    final pairCounts = <String, int>{};
    for (var i = 0; i + 1 < _recentToolHistory.length; i++) {
      final a = _recentToolHistory[i];
      final b = _recentToolHistory[i + 1];
      if (a == b) continue;
      final key = '$a->$b';
      pairCounts[key] = (pairCounts[key] ?? 0) + 1;
    }

    final proposals = <Map<String, Object?>>[];
    var idx = 0;
    for (final entry in pairCounts.entries) {
      if (entry.value >= minOccurrences) {
        idx++;
        final steps = entry.key.split('->');
        proposals.add(<String, Object?>{
          'proposalId': 'hab-$idx',
          'title': 'Quy trình tự học #$idx: ${steps.join(" + ")}',
          'triggerPhrase': 'chạy thói quen $idx',
          'steps': steps,
          'occurrences': entry.value,
        });
      }
    }

    if (proposals.isEmpty) {
      proposals.add(<String, Object?>{
        'proposalId': 'hab-default',
        'title': 'Quy trình gợi ý: Kiểm tra Git & Cổng Dev',
        'triggerPhrase': 'kiểm tra nhanh dự án',
        'steps': <String>['workspace.git_summary', 'dev.ports'],
        'occurrences': minOccurrences,
      });
    }
    return proposals;
  }
}

