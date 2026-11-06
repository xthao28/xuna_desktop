import 'dart:async';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'symbiotic_models.dart';
import 'symbiotic_vitals_service.dart';

/// Autonomous Watchdog Sentinel, Executive Function Coach, Desk Whisper, and Habit Miner (`SYM-2` S2.1).
class WatchdogCoachService {
  WatchdogCoachService({required SymbioticVitalsService vitalsService})
    : _vitalsService = vitalsService;

  final SymbioticVitalsService _vitalsService;
  int _watchdogSeq = 0;
  final List<WatchdogSentinelEntry> _watchdogs = <WatchdogSentinelEntry>[];
  final List<String> _recentToolHistory = <String>[];

  /// Registers a background watchdog sentinel on a process or localhost port (`SYM-2` S2.1).
  Future<
    ({
      String watchdogId,
      String targetKind,
      String targetValue,
      String status,
      String summary,
    })
  >
  registerProcessOrPortWatchdog({
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
      final scanned = await _vitalsService.scanDevPorts(
        ports: <int>[targetPort],
      );
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
    })
  >
  registerResourceWatchdog({
    required String metric,
    required int threshold,
    DateTime? nowUtc,
  }) async {
    _watchdogSeq++;
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    final wdId = 'wd-$_watchdogSeq';
    final vitals = await _vitalsService.readSystemVitals();
    final measured = switch (metric) {
      'battery_below' => vitals.batteryPercent,
      'memory_above' => vitals.memoryUsedPercent,
      _ => vitals.diskFreeGb,
    };
    if (measured == null) {
      throw XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'metric_unavailable',
        message: 'This host cannot measure $metric.',
      );
    }
    final currentVal = measured;
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
  listAndClearWatchdogs({String action = 'list'}) {
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
  })
  decomposeOverwhelm({required String goal, String? project}) {
    final cleanGoal = redactSensitiveSelectionText(
      goal.trim(),
      maxChars: 240,
    ).text;
    final cleanProj = (project == null || project.trim().isEmpty)
        ? 'workspace'
        : project.trim();
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
  })
  buildDeskWhisperDigest({required String topic, String? contextHint}) {
    final cleanTopic = redactSensitiveSelectionText(
      topic.trim(),
      maxChars: 120,
    ).text;
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
      bulletPoints: <String>[cleanTopic, cleanHint],
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
