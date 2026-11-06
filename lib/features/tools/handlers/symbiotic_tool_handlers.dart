import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class ClipboardWriteTool extends HostToolHandler {
  const ClipboardWriteTool();

  @override
  String get name => 'clipboard.write';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final rawText = context.arguments['text'] as String;
    final res = await context.symbioticService.writeClipboardText(rawText);
    return ToolHandlerOutput(
      text: 'Đã chép ${res.charCount} ký tự vào clipboard.',
      structuredContent: <String, Object?>{
        'written': res.written,
        'charCount': res.charCount,
        'redactedCount': res.redactedCount,
      },
      toastBody: 'đã chép ${res.charCount} ký tự vào clipboard',
    );
  }
}

class MeetingStatusTool extends HostToolHandler {
  const MeetingStatusTool();

  @override
  String get name => 'meeting.status';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final snap = await context.symbioticService.getMeetingStatus();
    final micDesc = snap.micMuted ? 'đã tắt mic' : 'mic đang bật';
    final text = snap.inMeeting
        ? 'Đang họp trên ${snap.app} ($micDesc).'
        : 'Không có cuộc họp nào ($micDesc).';
    return ToolHandlerOutput(text: text, structuredContent: snap.toWireJson());
  }
}

class MeetingControlTool extends HostToolHandler {
  const MeetingControlTool();

  @override
  String get name => 'meeting.control';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = context.arguments['action'] as String;
    final res = await context.symbioticService.controlMeeting(action);
    context.actionLedger.pushEntry(
      ReversibleActionEntry(
        originalTool: 'meeting.control',
        inverseTool: 'meeting.control',
        inverseArgs: <String, Object?>{'action': res.inverseAction},
        description: res.previousMicMuted ? 'tắt lại mic' : 'bật lại mic',
        recordedAt: context.nowUtc,
      ),
    );
    final label = res.micMuted ? 'Đã tắt mic' : 'Đã bật mic';
    return ToolHandlerOutput(
      text: '$label (${res.app}).',
      structuredContent: <String, Object?>{
        'action': res.action,
        'micMuted': res.micMuted,
        'app': res.app,
      },
      toastBody: res.micMuted ? 'đã tắt mic' : 'đã bật mic',
    );
  }
}

class DevPortsTool extends HostToolHandler {
  const DevPortsTool();

  @override
  String get name => 'dev.ports';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final rawPorts = context.arguments['ports'];
    List<int>? ports;
    if (rawPorts is List) {
      ports = rawPorts.whereType<int>().toList(growable: false);
    }
    final res = await context.symbioticService.scanDevPorts(ports: ports);
    return ToolHandlerOutput(
      text: res.activePorts.isEmpty
          ? 'Không có cổng dev localhost nào đang chạy.'
          : 'Phát hiện ${res.activePorts.length} cổng dev trên ${res.lanIp}.',
      structuredContent: <String, Object?>{
        'lanIp': res.lanIp,
        'activePorts': res.activePorts
            .map((e) => e.toWireJson())
            .toList(growable: false),
      },
    );
  }
}

class SystemVitalsTool extends HostToolHandler {
  const SystemVitalsTool();

  @override
  String get name => 'system.vitals';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final snap = await context.symbioticService.readSystemVitals();
    return ToolHandlerOutput(
      text: '${snap.describeVi()} (${snap.healthStatus}).',
      structuredContent: snap.toWireJson(),
    );
  }
}

class WorkspaceCaptureCapsuleTool extends HostToolHandler {
  const WorkspaceCaptureCapsuleTool();

  @override
  String get name => 'workspace.capture_capsule';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final projectQuery = (context.arguments['project'] as String?) ?? 'recent';
    final nextStepHint = context.arguments['nextStepHint'] as String?;
    final ws = context.workspaceIndexer.resolveWorkspace(projectQuery);
    var resolvedProject = projectQuery;
    var branch = 'main';
    var dirtyCount = 0;
    if (ws != null) {
      resolvedProject = ws.alias;
      try {
        final summary = await context.workspaceIndexer.readGitSummary(ws);
        branch = summary.branch;
        dirtyCount = summary.modifiedCount + summary.untrackedCount;
      } catch (_) {
        // Fallback if Git CLI is unavailable
      }
    }
    final capsule = context.symbioticService.captureWorkspaceCapsule(
      project: resolvedProject,
      branch: branch,
      dirtyCount: dirtyCount,
      nextStepHint: nextStepHint,
      nowUtc: context.nowUtc,
    );
    return ToolHandlerOutput(
      text:
          'Đã đóng băng mạch làm việc ${capsule.project} (nhánh ${capsule.branch}, ${capsule.dirtyCount} tệp đang sửa).',
      structuredContent: capsule.toWireJson(),
      toastBody: 'đã đóng băng mạch làm việc ${capsule.project}',
    );
  }
}

class WorkspaceRestoreCapsuleTool extends HostToolHandler {
  const WorkspaceRestoreCapsuleTool();

  @override
  String get name => 'workspace.restore_capsule';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final capsuleId = context.arguments['capsuleId'] as String?;
    final projectQuery = context.arguments['project'] as String?;
    final ide = (context.arguments['ide'] as String?) ?? 'auto';
    final capsule = context.symbioticService.findWorkspaceCapsule(
      capsuleId: capsuleId,
      project: projectQuery,
    );
    if (capsule == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'capsule_not_found',
      );
    }
    final ws = context.workspaceIndexer.resolveWorkspace(capsule.project);
    if (ws != null) {
      final resolvedIde =
          context.appScanner.resolveCodingAgent(
            ide == 'auto' ? 'antigravity' : ide,
          ) ??
          context.appScanner.resolveCodingAgent('auto');
      if (resolvedIde != null) {
        await context.workspaceIndexer.launchCodingAgent(
          workspace: ws,
          agent: resolvedIde.agent,
          executable: resolvedIde.executable,
          resumeLast: true,
        );
      }
    }
    final briefingVi =
        'Đã rã đông dự án ${capsule.project} (nhánh ${capsule.branch}). Việc tiếp theo: ${capsule.nextStepHint}';
    return ToolHandlerOutput(
      text: briefingVi,
      structuredContent: <String, Object?>{
        'restored': true,
        'capsuleId': capsule.capsuleId,
        'project': capsule.project,
        'branch': capsule.branch,
        'nextStepHint': capsule.nextStepHint,
        'briefingVi': briefingVi,
      },
      toastBody: 'đã khôi phục mạch làm việc ${capsule.project}',
    );
  }
}

class WorkspaceListCapsulesTool extends HostToolHandler {
  const WorkspaceListCapsulesTool();

  @override
  String get name => 'workspace.list_capsules';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final limit = (context.arguments['limit'] as int?) ?? 10;
    final list = context.symbioticService.listWorkspaceCapsules(limit: limit);
    return ToolHandlerOutput(
      text: list.isEmpty
          ? 'Chưa có mạch làm việc nào được đóng băng.'
          : 'Đang lưu ${list.length} mạch làm việc trong bộ nhớ Time-Travel.',
      structuredContent: <String, Object?>{
        'capsules': list.map((e) => e.toWireJson()).toList(growable: false),
      },
    );
  }
}

class PocketPushItemTool extends HostToolHandler {
  const PocketPushItemTool();

  @override
  String get name => 'pocket.push_item';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final rawText = context.arguments['text'] as String;
    final label = context.arguments['label'] as String?;
    final kind = context.arguments['kind'] as String?;
    final sourceDevice = context.arguments['sourceDevice'] as String?;
    final item = context.symbioticService.pushPocketItem(
      rawText: rawText,
      label: label,
      kind: kind,
      sourceDevice: sourceDevice,
      nowUtc: context.nowUtc,
    );
    return ToolHandlerOutput(
      text: 'Đã cất vào Túi đồ XUNA (${item.kind}: ${item.label}).',
      structuredContent: <String, Object?>{
        'itemId': item.itemId,
        'kind': item.kind,
        'label': item.label,
        'preview': item.preview,
        'redactedCount': item.redactedCount,
        'suggestedActions': item.suggestedActions,
      },
      toastBody: 'đã lưu vào Túi đồ XUNA',
    );
  }
}

class PocketListItemsTool extends HostToolHandler {
  const PocketListItemsTool();

  @override
  String get name => 'pocket.list_items';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final kind = context.arguments['kind'] as String?;
    final query = context.arguments['query'] as String?;
    final limit = (context.arguments['limit'] as int?) ?? 10;
    final items = context.symbioticService.listPocketItems(
      kind: kind,
      query: query,
      limit: limit,
    );
    return ToolHandlerOutput(
      text: items.isEmpty
          ? 'Túi đồ XUNA hiện đang trống.'
          : 'Tìm thấy ${items.length} mục trong Túi đồ XUNA.',
      structuredContent: <String, Object?>{
        'items': items.map((e) => e.toWireListJson()).toList(growable: false),
      },
    );
  }
}

class PocketTransformItemTool extends HostToolHandler {
  const PocketTransformItemTool();

  @override
  String get name => 'pocket.transform_item';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final itemId = context.arguments['itemId'] as String?;
    final rawText = context.arguments['text'] as String?;
    final mode = context.arguments['mode'] as String;
    final res = context.symbioticService.transformPocketItem(
      itemId: itemId,
      rawText: rawText,
      mode: mode,
    );
    return ToolHandlerOutput(
      text:
          'Đã biến đổi nội dung theo chế độ ${res.mode} (${res.itemCount} mục).',
      structuredContent: <String, Object?>{
        'mode': res.mode,
        'transformedText': res.transformedText,
        'itemCount': res.itemCount,
      },
    );
  }
}

class WatchdogWatchProcessOrPortTool extends HostToolHandler {
  const WatchdogWatchProcessOrPortTool();

  @override
  String get name => 'watchdog.watch_process_or_port';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final targetKind = context.arguments['targetKind'] as String;
    final processName = context.arguments['processName'] as String?;
    final port = context.arguments['port'] as int?;
    final label = context.arguments['label'] as String?;
    final res = await context.symbioticService.registerProcessOrPortWatchdog(
      targetKind: targetKind,
      processName: processName,
      port: port,
      label: label,
      nowUtc: context.nowUtc,
    );
    return ToolHandlerOutput(
      text: res.summary,
      structuredContent: <String, Object?>{
        'watchdogId': res.watchdogId,
        'targetKind': res.targetKind,
        'targetValue': res.targetValue,
        'status': res.status,
        'summary': res.summary,
      },
    );
  }
}

class WatchdogWatchResourceThresholdTool extends HostToolHandler {
  const WatchdogWatchResourceThresholdTool();

  @override
  String get name => 'watchdog.watch_resource_threshold';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final metric = context.arguments['metric'] as String;
    final threshold = context.arguments['threshold'] as int;
    final res = await context.symbioticService.registerResourceWatchdog(
      metric: metric,
      threshold: threshold,
      nowUtc: context.nowUtc,
    );
    return ToolHandlerOutput(
      text: res.summary,
      structuredContent: <String, Object?>{
        'watchdogId': res.watchdogId,
        'metric': res.metric,
        'threshold': res.threshold,
        'currentValue': res.currentValue,
        'triggered': res.triggered,
        'summary': res.summary,
      },
    );
  }
}

class WatchdogListAndClearTool extends HostToolHandler {
  const WatchdogListAndClearTool();

  @override
  String get name => 'watchdog.list_and_clear';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = (context.arguments['action'] as String?) ?? 'list';
    final res = context.symbioticService.listAndClearWatchdogs(action: action);
    return ToolHandlerOutput(
      text:
          'Có ${res.watchdogs.length} đội tuần tra đang chạy (đã xóa ${res.clearedCount}).',
      structuredContent: <String, Object?>{
        'watchdogs': res.watchdogs,
        'clearedCount': res.clearedCount,
      },
    );
  }
}

class CoachDecomposeOverwhelmTool extends HostToolHandler {
  const CoachDecomposeOverwhelmTool();

  @override
  String get name => 'coach.decompose_overwhelm';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final goal = context.arguments['goal'] as String;
    final project = context.arguments['project'] as String?;
    final res = context.symbioticService.decomposeOverwhelm(
      goal: goal,
      project: project,
    );
    return ToolHandlerOutput(
      text: '${res.firstFiveMinuteStep} — ${res.encouragementVi}',
      structuredContent: <String, Object?>{
        'goal': res.goal,
        'project': res.project,
        'firstFiveMinuteStep': res.firstFiveMinuteStep,
        'followUpSteps': res.followUpSteps,
        'encouragementVi': res.encouragementVi,
      },
    );
  }
}

class MeetingDeskWhisperDigestTool extends HostToolHandler {
  const MeetingDeskWhisperDigestTool();

  @override
  String get name => 'meeting.desk_whisper_digest';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final topic = context.arguments['topic'] as String;
    final contextHint = context.arguments['contextHint'] as String?;
    final res = context.symbioticService.buildDeskWhisperDigest(
      topic: topic,
      contextHint: contextHint,
    );
    return ToolHandlerOutput(
      text: res.whisperLine,
      structuredContent: <String, Object?>{
        'topic': res.topic,
        'whisperLine': res.whisperLine,
        'bulletPoints': res.bulletPoints,
        'silentMode': res.silentMode,
      },
    );
  }
}

class HabitProposeWorkflowTool extends HostToolHandler {
  const HabitProposeWorkflowTool();

  @override
  String get name => 'habit.propose_workflow';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final minOccurrences = (context.arguments['minOccurrences'] as int?) ?? 2;
    final proposals = context.symbioticService.proposeHabitWorkflows(
      minOccurrences: minOccurrences,
    );
    return ToolHandlerOutput(
      text: 'Đã phát hiện ${proposals.length} quy trình thói quen gợi ý.',
      structuredContent: <String, Object?>{'proposals': proposals},
    );
  }
}

const List<HostToolHandler> defaultSymbioticToolHandlers = <HostToolHandler>[
  ClipboardWriteTool(),
  MeetingStatusTool(),
  MeetingControlTool(),
  DevPortsTool(),
  SystemVitalsTool(),
  WorkspaceCaptureCapsuleTool(),
  WorkspaceRestoreCapsuleTool(),
  WorkspaceListCapsulesTool(),
  PocketPushItemTool(),
  PocketListItemsTool(),
  PocketTransformItemTool(),
  WatchdogWatchProcessOrPortTool(),
  WatchdogWatchResourceThresholdTool(),
  WatchdogListAndClearTool(),
  CoachDecomposeOverwhelmTool(),
  MeetingDeskWhisperDigestTool(),
  HabitProposeWorkflowTool(),
];
