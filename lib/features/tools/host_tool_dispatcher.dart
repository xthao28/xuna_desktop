import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_mcp_bridge.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Result produced by an individual [HostToolHandler].
class ToolHandlerOutput {
  const ToolHandlerOutput({
    required this.text,
    required this.structuredContent,
    this.toastBody,
  });

  final String text;
  final Map<String, Object?> structuredContent;

  /// Optional short toast description (`"đã mở VS Code"`). Never contains full
  /// URLs or file paths (`UDC-3` §5.6.5 rule 7).
  final String? toastBody;
}

/// Token checked at safe points by tool handlers to detect cancellation from
/// `notifications/cancelled` or emergency stop (`UDC-3` §5.6.5 rule 6).
class ToolCancellationToken {
  bool _isCancelled = false;
  String? _reason;
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _isCancelled;
  String? get reason => _reason;
  Future<void> get onCancelled => _completer.future;

  void cancel(String reason) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Single reversible host action entry stored in [ReversibleActionLedger] (`UDC-13` S13.5).
class ReversibleActionEntry {
  const ReversibleActionEntry({
    required this.originalTool,
    required this.inverseTool,
    required this.inverseArgs,
    required this.description,
    required this.recordedAt,
  });

  final String originalTool;
  final String inverseTool;
  final Map<String, Object?> inverseArgs;
  final String description;
  final DateTime recordedAt;
}

/// Bounded in-memory stack of reversible desktop actions (`UDC-13` S13.5).
///
/// Tracks the last [maxEntries] reversible actions with a [ttl] of 10 minutes
/// so `action.undo` can immediately restore the previous state.
class ReversibleActionLedger {
  ReversibleActionLedger({
    this.maxEntries = 5,
    this.ttl = const Duration(minutes: 10),
    int initialVolume = 50,
  }) : _lastKnownVolume = initialVolume;

  final int maxEntries;
  final Duration ttl;
  final List<ReversibleActionEntry> _stack = <ReversibleActionEntry>[];
  int _lastKnownVolume;

  int get lastKnownVolume => _lastKnownVolume;

  int get length => _stack.length;

  void record({
    required String originalTool,
    required Map<String, Object?> arguments,
    required DateTime nowUtc,
  }) {
    _pruneExpired(nowUtc);
    ReversibleActionEntry? entry;
    if (originalTool == 'media.play_pause') {
      entry = ReversibleActionEntry(
        originalTool: originalTool,
        inverseTool: 'media.play_pause',
        inverseArgs: const <String, Object?>{},
        description: 'khôi phục trạng thái phát nhạc',
        recordedAt: nowUtc,
      );
    } else if (originalTool == 'media.volume_set') {
      final newLevel = arguments['level'];
      if (newLevel is int) {
        final prev = _lastKnownVolume;
        _lastKnownVolume = newLevel;
        entry = ReversibleActionEntry(
          originalTool: originalTool,
          inverseTool: 'media.volume_set',
          inverseArgs: <String, Object?>{'level': prev},
          description: 'khôi phục âm lượng $prev%',
          recordedAt: nowUtc,
        );
      }
    } else if (originalTool == 'host.lock_screen') {
      entry = ReversibleActionEntry(
        originalTool: originalTool,
        inverseTool: 'display.wake',
        inverseArgs: const <String, Object?>{},
        description: 'bật lại màn hình',
        recordedAt: nowUtc,
      );
    }
    if (entry != null) {
      if (_stack.length >= maxEntries) {
        _stack.removeAt(0);
      }
      _stack.add(entry);
    }
  }

  ReversibleActionEntry? popValid(DateTime nowUtc) {
    _pruneExpired(nowUtc);
    if (_stack.isEmpty) return null;
    final popped = _stack.removeLast();
    if (popped.inverseTool == 'media.volume_set') {
      final restored = popped.inverseArgs['level'];
      if (restored is int) {
        _lastKnownVolume = restored;
      }
    }
    return popped;
  }

  void _pruneExpired(DateTime nowUtc) {
    _stack.removeWhere((e) => nowUtc.difference(e.recordedAt) > ttl);
  }
}

typedef SubStepExecutor = Future<ToolHandlerOutput> Function(
  String toolName,
  Map<String, Object?> arguments,
);

/// Context passed to a [HostToolHandler] during execution.
class ToolExecutionContext {
  const ToolExecutionContext({
    required this.arguments,
    required this.evaluation,
    required this.policy,
    required this.channel,
    required this.appScanner,
    required this.workspaceIndexer,
    required this.mcpBridge,
    required this.actionLedger,
    required this.cancellationToken,
    required this.agentVersion,
    required this.nowUtc,
    this.beamDirectoryPath,
    this.subStepExecutor,
  });

  final Map<String, Object?> arguments;
  final PolicyEvaluationResult evaluation;
  final HostPolicy? policy;
  final XunaHostChannel channel;
  final AutoAppScanner appScanner;
  final AutoWorkspaceIndexer workspaceIndexer;
  final AutoMcpBridge mcpBridge;
  final ReversibleActionLedger actionLedger;
  final ToolCancellationToken cancellationToken;
  final String agentVersion;
  final DateTime nowUtc;
  final String? beamDirectoryPath;
  final SubStepExecutor? subStepExecutor;
}

/// Base class for each of the 12 MVP tools (`UDC-3` §5.6.1: one class per tool).
abstract class HostToolHandler {
  const HostToolHandler();

  String get name;

  Future<ToolHandlerOutput> execute(ToolExecutionContext context);
}

class MediaPlayPauseTool extends HostToolHandler {
  const MediaPlayPauseTool();

  @override
  String get name => 'media.play_pause';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final state = await context.channel.media('play_pause');
    return ToolHandlerOutput(
      text: 'Đã chuyển trạng thái phát nhạc ($state).',
      structuredContent: <String, Object?>{'state': state},
    );
  }
}

class MediaNextTool extends HostToolHandler {
  const MediaNextTool();

  @override
  String get name => 'media.next';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    await context.channel.media('next');
    return const ToolHandlerOutput(
      text: 'Đã chuyển bài tiếp theo.',
      structuredContent: <String, Object?>{},
    );
  }
}

class MediaPreviousTool extends HostToolHandler {
  const MediaPreviousTool();

  @override
  String get name => 'media.previous';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    await context.channel.media('previous');
    return const ToolHandlerOutput(
      text: 'Đã quay lại bài trước.',
      structuredContent: <String, Object?>{},
    );
  }
}

class MediaVolumeSetTool extends HostToolHandler {
  const MediaVolumeSetTool();

  @override
  String get name => 'media.volume_set';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final level = context.arguments['level'] as int;
    final applied = await context.channel.volumeSet(level);
    return ToolHandlerOutput(
      text: 'Đã đặt âm lượng $applied%.',
      structuredContent: <String, Object?>{'level': applied},
      toastBody: 'đã đặt âm lượng $applied%',
    );
  }
}

class MediaNowPlayingTool extends HostToolHandler {
  const MediaNowPlayingTool();

  @override
  String get name => 'media.now_playing';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final players = context.policy?.players ?? const <String>[];
    if (players.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'platform_unsupported',
      );
    }
    final snap = await context.channel.nowPlaying(players);
    return ToolHandlerOutput(
      text: 'Trạng thái nhạc: ${snap.state}.',
      structuredContent: snap.toStructuredContent(),
    );
  }
}

class AppListAllowedTool extends HostToolHandler {
  const AppListAllowedTool();

  @override
  String get name => 'app.list_allowed';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final seenIds = <String>{};
    final apps = <Map<String, Object?>>[];
    for (final app in context.policy?.apps ?? const <AllowedAppConfig>[]) {
      if (seenIds.add(app.id)) {
        apps.add(<String, Object?>{'id': app.id, 'name': app.name});
      }
    }
    final discovered = context.appScanner.discoverApps();
    for (final app in discovered) {
      if (seenIds.add(app.id)) {
        apps.add(<String, Object?>{'id': app.id, 'name': app.name});
      }
    }
    return ToolHandlerOutput(
      text: 'Có ${apps.length} ứng dụng được phép mở.',
      structuredContent: <String, Object?>{'apps': apps},
    );
  }
}

class AppLaunchTool extends HostToolHandler {
  const AppLaunchTool();

  @override
  String get name => 'app.launch';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final configured = context.evaluation.app;
    if (configured != null) {
      await context.channel.appLaunch(
        kind: configured.kind,
        target: configured.target,
      );
      return ToolHandlerOutput(
        text: 'Đã mở ${configured.name}.',
        structuredContent: <String, Object?>{'id': configured.id},
        toastBody: 'đã mở ${configured.name}',
      );
    }

    final requestedId = context.arguments['id'] as String? ?? '';
    final discovered = context.appScanner.findApp(requestedId);
    if (discovered == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'app_not_allowlisted',
      );
    }
    await context.channel.appLaunch(
      kind: discovered.kind,
      target: discovered.target,
    );
    return ToolHandlerOutput(
      text: 'Đã mở ${discovered.name}.',
      structuredContent: <String, Object?>{'id': discovered.id},
      toastBody: 'đã mở ${discovered.name}',
    );
  }
}

class UrlOpenTool extends HostToolHandler {
  const UrlOpenTool();

  @override
  String get name => 'url.open';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final url = context.arguments['url'] as String;
    final host = context.evaluation.normalizedUrlHost!;
    await context.channel.urlOpen(url);
    return ToolHandlerOutput(
      text: 'Đã mở $host.',
      structuredContent: <String, Object?>{'host': host},
      toastBody: 'đã mở $host',
    );
  }
}

class BrowserCurrentUrlTool extends HostToolHandler {
  const BrowserCurrentUrlTool();

  @override
  String get name => 'browser.current_url';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final requestedBrowser =
        (context.arguments['browser'] as String?) ?? 'auto';
    final snap = await context.channel.browserCurrentUrl(
      browser: requestedBrowser,
    );
    final urlCheck = validateHttpsUrlAgainstAllowlist(
      snap.url,
      context.policy?.urlDomains ?? const <String>[],
    );
    if (!urlCheck.validUrl || urlCheck.asciiHost == null) {
      throw XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: urlCheck.errorCode ?? 'url_invalid',
      );
    }
    final resolvedBrowser =
        const <String>{'edge', 'chrome', 'safari'}.contains(snap.browser)
        ? snap.browser
        : 'edge';
    final host = urlCheck.asciiHost!;
    return ToolHandlerOutput(
      text: 'Đã đọc liên kết hiện tại từ $resolvedBrowser ($host).',
      structuredContent: <String, Object?>{
        'url': snap.url,
        'host': host,
        'browser': resolvedBrowser,
      },
      toastBody: 'đã đọc liên kết $host',
    );
  }
}

class WorkflowListTool extends HostToolHandler {
  const WorkflowListTool();

  @override
  String get name => 'workflow.list';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final workflows = <Map<String, Object?>>[
      for (final wf in context.policy?.workflows ?? const <WorkflowConfig>[])
        <String, Object?>{'id': wf.id, 'name': wf.name, 'risk': wf.risk.wire},
    ];
    return ToolHandlerOutput(
      text: 'Có ${workflows.length} quy trình được phép chạy.',
      structuredContent: <String, Object?>{'workflows': workflows},
    );
  }
}

class WorkflowRunTool extends HostToolHandler {
  const WorkflowRunTool();

  @override
  String get name => 'workflow.run';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final wf = context.evaluation.workflow!;
    await context.channel.workflowRun(kind: wf.kind, target: wf.target);
    return ToolHandlerOutput(
      text: 'Đã chạy ${wf.name}.',
      structuredContent: <String, Object?>{'id': wf.id},
      toastBody: 'đã chạy ${wf.name}',
    );
  }
}

class HostStatusTool extends HostToolHandler {
  const HostStatusTool();

  @override
  String get name => 'host.status';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final info = await context.channel.hostInfo();
    final perms = await context.channel.permissions();
    return ToolHandlerOutput(
      text: 'Máy tính đang hoạt động (${info.platform.wire}).',
      structuredContent: <String, Object?>{
        'platform': info.platform.wire,
        'osVersion': info.osVersion,
        'agentVersion': context.agentVersion,
        'permissions': perms.toWireMap(),
      },
    );
  }
}

class HostNotifyTool extends HostToolHandler {
  const HostNotifyTool();

  @override
  String get name => 'host.notify';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final title = context.arguments['title'] as String;
    final body = context.arguments['body'] as String;
    await context.channel.showToast(title: title, body: body);
    return const ToolHandlerOutput(
      text: 'Đã hiển thị thông báo.',
      structuredContent: <String, Object?>{},
    );
  }
}

class DisplayWakeTool extends HostToolHandler {
  const DisplayWakeTool();

  @override
  String get name => 'display.wake';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final woken = await context.channel.displayWake();
    return ToolHandlerOutput(
      text: 'Đã đánh thức màn hình máy tính.',
      structuredContent: <String, Object?>{'woken': woken},
      toastBody: 'đã bật màn hình',
    );
  }
}

class WorkspaceOpenTool extends HostToolHandler {
  const WorkspaceOpenTool();

  @override
  String get name => 'workspace.open';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final project = context.arguments['project'] as String;
    final ide = (context.arguments['ide'] as String?) ?? 'auto';
    final ws = context.workspaceIndexer.resolveWorkspace(project);
    if (ws == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'workspace_not_found',
      );
    }
    final resolvedIde = context.appScanner.resolveCodingAgent(
      ide == 'auto' ? 'antigravity' : ide,
    ) ??
        context.appScanner.resolveCodingAgent('auto');
    if (resolvedIde == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'ide_not_found',
      );
    }
    final plan = await context.workspaceIndexer.launchCodingAgent(
      workspace: ws,
      agent: resolvedIde.agent,
      executable: resolvedIde.executable,
      resumeLast: false,
    );
    return ToolHandlerOutput(
      text: 'Đã mở dự án ${ws.alias} bằng ${plan.agent}.',
      structuredContent: <String, Object?>{
        'workspace': ws.alias,
        'ide': plan.agent,
      },
      toastBody: 'đã mở dự án ${ws.alias}',
    );
  }
}

class WorkspaceGitSummaryTool extends HostToolHandler {
  const WorkspaceGitSummaryTool();

  @override
  String get name => 'workspace.git_summary';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final project = (context.arguments['project'] as String?) ?? 'recent';
    final ws = context.workspaceIndexer.resolveWorkspace(project);
    if (ws == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'workspace_not_found',
      );
    }
    final summary = await context.workspaceIndexer.readGitSummary(ws);
    return ToolHandlerOutput(
      text:
          'Dự án ${summary.workspace} (nhánh ${summary.branch}, ${summary.modifiedCount + summary.untrackedCount} tệp thay đổi).',
      structuredContent: summary.toStructuredContent(),
    );
  }
}

class WorkspaceCodingAgentTool extends HostToolHandler {
  const WorkspaceCodingAgentTool();

  @override
  String get name => 'workspace.coding_agent';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final project = (context.arguments['project'] as String?) ?? 'recent';
    final agent = (context.arguments['agent'] as String?) ?? 'auto';
    final resumeLast = (context.arguments['resumeLast'] as bool?) ?? true;
    final prompt = context.arguments['prompt'] as String?;
    final ws = context.workspaceIndexer.resolveWorkspace(project);
    if (ws == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'workspace_not_found',
      );
    }
    final resolvedAgent = context.appScanner.resolveCodingAgent(agent);
    if (resolvedAgent == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'coding_agent_not_found',
      );
    }
    final plan = await context.workspaceIndexer.launchCodingAgent(
      workspace: ws,
      agent: resolvedAgent.agent,
      executable: resolvedAgent.executable,
      resumeLast: resumeLast,
      prompt: prompt,
    );
    return ToolHandlerOutput(
      text:
          'Đã mở ${plan.agent} tại dự án ${plan.workspace} và gửi yêu cầu tiếp tục công việc.',
      structuredContent: <String, Object?>{
        'workspace': plan.workspace,
        'agent': plan.agent,
        'resumed': plan.resumed,
        'promptSent': plan.promptSent,
      },
      toastBody: 'đã mở ${plan.agent} (${plan.workspace})',
    );
  }
}

class SelectionReadTool extends HostToolHandler {
  const SelectionReadTool();

  @override
  String get name => 'selection.read';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final maxChars = (context.arguments['maxChars'] as int?) ?? 1200;
    final raw = await context.channel.clipboardReadText();
    final redacted = redactSensitiveSelectionText(raw, maxChars: maxChars);
    return ToolHandlerOutput(
      text: redacted.text.isEmpty
          ? 'Không có văn bản đang chọn trong bộ nhớ tạm.'
          : 'Đã đọc đoạn văn bản đang chọn (${redacted.text.length} ký tự, ẩn ${redacted.redactedCount} mã nhạy cảm).',
      structuredContent: <String, Object?>{
        'text': redacted.text,
        'truncated': redacted.truncated,
        'redactedCount': redacted.redactedCount,
      },
      toastBody: 'đã đọc đoạn văn bản đang chọn',
    );
  }
}

class HostLockScreenTool extends HostToolHandler {
  const HostLockScreenTool();

  @override
  String get name => 'host.lock_screen';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final locked = await context.channel.lockScreen();
    return ToolHandlerOutput(
      text: 'Đã khóa màn hình máy tính.',
      structuredContent: <String, Object?>{'locked': locked},
      toastBody: 'đã khóa màn hình',
    );
  }
}

class WorkspaceWatchTaskTool extends HostToolHandler {
  const WorkspaceWatchTaskTool();

  @override
  String get name => 'workspace.watch_task';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final project = (context.arguments['project'] as String?) ?? 'recent';
    final ws = context.workspaceIndexer.resolveWorkspace(project);
    if (ws == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'workspace_not_found',
      );
    }
    final snap = await context.workspaceIndexer.inspectWorkspaceTask(ws);
    return ToolHandlerOutput(
      text: snap.summary,
      structuredContent: snap.toStructuredContent(),
    );
  }
}

class McpListServersTool extends HostToolHandler {
  const McpListServersTool();

  @override
  String get name => 'mcp.list_servers';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final servers = context.mcpBridge
        .discoverServers()
        .map((s) => s.toWireJson())
        .toList();
    return ToolHandlerOutput(
      text: 'Có ${servers.length} máy chủ MCP cục bộ khả dụng.',
      structuredContent: <String, Object?>{'servers': servers},
    );
  }
}

class McpCallTool extends HostToolHandler {
  const McpCallTool();

  @override
  String get name => 'mcp.call';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final serverId = context.arguments['server'] as String;
    final toolName = context.arguments['tool'] as String;
    final payloadJson = context.arguments['payloadJson'] as String?;
    final server = context.mcpBridge.findServer(serverId);
    if (server == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_found',
      );
    }
    final String summary;
    try {
      summary = await context.mcpBridge.callTool(
        server: server,
        toolName: toolName,
        payloadJson: payloadJson,
      );
    } on FormatException {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'schema_mismatch',
      );
    }
    return ToolHandlerOutput(
      text: summary,
      structuredContent: <String, Object?>{
        'server': server.id,
        'tool': toolName,
        'summary': summary,
      },
      toastBody: 'đã gọi MCP ${server.id}.$toolName',
    );
  }
}

class WindowActiveContextTool extends HostToolHandler {
  const WindowActiveContextTool();

  @override
  String get name => 'window.active_context';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final maxChars = (context.arguments['maxChars'] as int?) ?? 600;
    final snap = await context.channel.readActiveWindowContext(
      maxChars: maxChars,
    );
    if (snap.isElevated) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'elevated_window_forbidden',
      );
    }
    if (isHardDeniedAppOrProcess(snap.processName) ||
        isHardDeniedAppOrProcess(snap.appName)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'denylisted_target_forbidden',
      );
    }
    final titleRedacted = redactSensitiveSelectionText(
      snap.windowTitle,
      maxChars: 160,
    );
    final textRedacted = redactSensitiveSelectionText(
      snap.visibleText,
      maxChars: maxChars,
    );
    final totalRedacted =
        titleRedacted.redactedCount + textRedacted.redactedCount;
    return ToolHandlerOutput(
      text:
          'Đã đọc ngữ cảnh cửa sổ ${snap.appName} (${textRedacted.text.length} ký tự, ẩn $totalRedacted mã nhạy cảm).',
      structuredContent: <String, Object?>{
        'appName': snap.appName,
        'windowTitle': titleRedacted.text,
        'focusedRole': snap.focusedRole,
        'visibleSummary': textRedacted.text,
        'truncated': textRedacted.truncated,
        'redactedCount': totalRedacted,
      },
      toastBody: 'đã đọc cửa sổ ${snap.appName}',
    );
  }
}

class BrowserReadPageTool extends HostToolHandler {
  const BrowserReadPageTool();

  @override
  String get name => 'browser.read_page';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final requestedBrowser =
        (context.arguments['browser'] as String?) ?? 'auto';
    final maxChars = (context.arguments['maxChars'] as int?) ?? 800;
    final snap = await context.channel.readBrowserPageSummary(
      browser: requestedBrowser,
      maxChars: maxChars,
    );
    final urlCheck = validateHttpsUrlAgainstAllowlist(
      snap.url,
      context.policy?.urlDomains ?? const <String>[],
    );
    if (!urlCheck.validUrl || urlCheck.asciiHost == null) {
      throw XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: urlCheck.errorCode ?? 'url_invalid',
      );
    }
    final resolvedBrowser =
        const <String>{'edge', 'chrome', 'safari'}.contains(snap.browser)
            ? snap.browser
            : 'edge';
    final host = urlCheck.asciiHost!;
    final titleRedacted = redactSensitiveSelectionText(
      snap.title,
      maxChars: 160,
    );
    final excerptRedacted = redactSensitiveSelectionText(
      snap.excerpt,
      maxChars: maxChars,
    );
    var totalRedacted =
        titleRedacted.redactedCount + excerptRedacted.redactedCount;
    final redactedHeadings = <String>[];
    for (final h in snap.headings.take(8)) {
      final r = redactSensitiveSelectionText(h, maxChars: 120);
      totalRedacted += r.redactedCount;
      if (r.text.isNotEmpty) redactedHeadings.add(r.text);
    }
    final redactedActions = <String>[];
    for (final a in snap.actions.take(8)) {
      final r = redactSensitiveSelectionText(a, maxChars: 80);
      totalRedacted += r.redactedCount;
      if (r.text.isNotEmpty) redactedActions.add(r.text);
    }
    return ToolHandlerOutput(
      text: 'Đã tóm tắt trang web trên $resolvedBrowser ($host).',
      structuredContent: <String, Object?>{
        'browser': resolvedBrowser,
        'host': host,
        'title': titleRedacted.text,
        'headings': redactedHeadings,
        'actions': redactedActions,
        'excerpt': excerptRedacted.text,
        'redactedCount': totalRedacted,
        'playwrightMcpAvailable': context.mcpBridge.hasPlaywrightMcp,
      },
      toastBody: 'đã đọc trang $host',
    );
  }
}

class BeamTransferTool extends HostToolHandler {
  const BeamTransferTool();

  @override
  String get name => 'beam.transfer';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final direction = context.arguments['direction'] as String;
    final kind = context.arguments['kind'] as String;
    final fileName = context.arguments['fileName'] as String;
    final sizeBytes = context.arguments['sizeBytes'] as int;
    final sha256 = context.arguments['sha256'] as String;
    final dataBase64 = context.arguments['dataBase64'] as String?;

    if (!isValidBeamFileName(fileName)) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'schema_mismatch',
      );
    }

    if (dataBase64 != null) {
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(base64.decode(dataBase64));
      } on FormatException {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'schema_mismatch',
        );
      }
      if (bytes.length != sizeBytes || sha256Hex(bytes) != sha256) {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'beam_hash_mismatch',
        );
      }
      final baseDir = context.beamDirectoryPath;
      if (baseDir != null && baseDir.isNotEmpty) {
        final dir = Directory(baseDir);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        final outFile = File(
          '$baseDir${Platform.pathSeparator}$fileName',
        );
        outFile.writeAsBytesSync(bytes, flush: true);
      }
    }

    return ToolHandlerOutput(
      text: 'Đã truyền an toàn $fileName ($sizeBytes B) qua XUNA Beam.',
      structuredContent: <String, Object?>{
        'direction': direction,
        'kind': kind,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        'verified': true,
        'savedUnder': 'XUNA_Beam/$fileName',
      },
      toastBody: 'đã nhận $fileName qua Beam',
    );
  }
}

class WorkflowBatchStepsTool extends HostToolHandler {
  const WorkflowBatchStepsTool();

  @override
  String get name => 'workflow.batch_steps';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final steps = context.arguments['steps'] as List;
    final executor = context.subStepExecutor;
    if (executor == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'platform_unsupported',
      );
    }
    final completedTools = <String>[];
    for (final rawStep in steps) {
      if (context.cancellationToken.isCancelled) {
        break;
      }
      final stepMap = rawStep as Map;
      final stepTool = stepMap['tool'] as String;
      final rawArgs = stepMap['arguments'] as Map;
      final stepArgs = rawArgs.map((k, v) => MapEntry(k.toString(), v));
      await executor(stepTool, stepArgs);
      completedTools.add(stepTool);
    }
    return ToolHandlerOutput(
      text:
          'Đã chạy chuỗi ${completedTools.length}/${steps.length} bước liên hoàn.',
      structuredContent: <String, Object?>{
        'completedCount': completedTools.length,
        'totalSteps': steps.length,
        'executedTools': completedTools,
      },
      toastBody: 'đã chạy chuỗi ${completedTools.length} bước',
    );
  }
}

class ActionUndoTool extends HostToolHandler {
  const ActionUndoTool();

  @override
  String get name => 'action.undo';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final entry = context.actionLedger.popValid(context.nowUtc);
    if (entry == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'nothing_to_undo',
      );
    }
    final executor = context.subStepExecutor;
    if (executor == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'platform_unsupported',
      );
    }
    await executor(entry.inverseTool, entry.inverseArgs);
    return ToolHandlerOutput(
      text: 'Đã hoàn tác ${entry.originalTool} (${entry.description}).',
      structuredContent: <String, Object?>{
        'undoneTool': entry.originalTool,
        'inverseTool': entry.inverseTool,
        'restored': true,
      },
      toastBody: 'đã hoàn tác (${entry.description})',
    );
  }
}

/// Registry and dispatcher for all MVP, Dev Workspace, Desk Co-Pilot, and Ambient Co-Pilot tools (`UDC-3` §5.6.5, `UDC-11`..`UDC-13`).
class HostToolDispatcher {
  HostToolDispatcher({
    required this.policyStore,
    required this.channel,
    required this.auditStore,
    required this.stopController,
    required this.logger,
    this.enrollmentStore,
    this.computerUseManager,
    AutoAppScanner? appScanner,
    AutoWorkspaceIndexer? workspaceIndexer,
    AutoMcpBridge? mcpBridge,
    ReversibleActionLedger? actionLedger,
    this.beamDirectoryPath,
    this.agentVersion = '0.1.0',
    this.maxIdempotencyCacheEntries = 256,
    List<HostToolHandler>? handlers,
  }) : appScanner = appScanner ?? AutoAppScanner(),
       workspaceIndexer = workspaceIndexer ?? AutoWorkspaceIndexer(),
       mcpBridge = mcpBridge ?? AutoMcpBridge(),
       actionLedger = actionLedger ?? ReversibleActionLedger() {
    final registered =
        handlers ??
        <HostToolHandler>[
          const MediaPlayPauseTool(),
          const MediaNextTool(),
          const MediaPreviousTool(),
          const MediaVolumeSetTool(),
          const MediaNowPlayingTool(),
          const AppListAllowedTool(),
          const AppLaunchTool(),
          const UrlOpenTool(),
          const BrowserCurrentUrlTool(),
          const WorkflowListTool(),
          const WorkflowRunTool(),
          const HostStatusTool(),
          const HostNotifyTool(),
          const DisplayWakeTool(),
          const WorkspaceOpenTool(),
          const WorkspaceGitSummaryTool(),
          const WorkspaceCodingAgentTool(),
          const SelectionReadTool(),
          const HostLockScreenTool(),
          const WorkspaceWatchTaskTool(),
          const McpListServersTool(),
          const McpCallTool(),
          const WindowActiveContextTool(),
          const BrowserReadPageTool(),
          const BeamTransferTool(),
          const WorkflowBatchStepsTool(),
          const ActionUndoTool(),
          if (computerUseManager != null)
            ...computerUseManager!.buildHandlers(),
        ];
    for (final handler in registered) {
      ToolDescriptor.validateToolName(handler.name);
      _handlers[handler.name] = handler;
    }
    stopController.addCancelListener(_onEmergencyStop);
  }

  final HostPolicyStore policyStore;
  final XunaHostChannel channel;
  final AuditLogStore auditStore;
  final EmergencyStopController stopController;
  final ContentFreeLogger logger;
  final EnrollmentStateStore? enrollmentStore;
  final ComputerUseSessionManager? computerUseManager;
  final AutoAppScanner appScanner;
  final AutoWorkspaceIndexer workspaceIndexer;
  final AutoMcpBridge mcpBridge;
  final ReversibleActionLedger actionLedger;
  final String? beamDirectoryPath;
  final String agentVersion;
  final int maxIdempotencyCacheEntries;

  final Map<String, HostToolHandler> _handlers = <String, HostToolHandler>{};
  final LinkedHashMap<String, XtpResponse> _idempotencyCache =
      LinkedHashMap<String, XtpResponse>();
  final Map<Object, ToolCancellationToken> _inFlightByRequestId =
      <Object, ToolCancellationToken>{};

  /// Builds the `tools/list` manifest with current OS permission states.
  Future<List<ToolDescriptor>> buildManifest() async {
    HostPermissionSnapshot perms;
    try {
      perms = await channel.permissions();
    } catch (_) {
      perms = const HostPermissionSnapshot();
    }
    final mvp = buildMvpToolCatalog(
      defaultPermission: perms.accessibility,
      includeBrowserCurrentUrl: true,
      includeDevWorkspaceTools: true,
      includeDeskCopilotTools: true,
      includeAmbientCopilotTools: true,
    );
    if (computerUseManager == null) {
      return mvp;
    }
    return <ToolDescriptor>[
      ...mvp,
      ...buildComputerUseTools(defaultPermission: perms.accessibility),
    ];
  }

  /// Cancels an in-flight `tools/call` when `notifications/cancelled` arrives.
  void cancelRequest(Object requestId, String reason) {
    final token = _inFlightByRequestId[requestId];
    token?.cancel(reason);
  }

  /// Cancels all in-flight `tools/call` invocations (e.g., on host revocation).
  void cancelAllInFlight(String reason) {
    for (final token in _inFlightByRequestId.values) {
      token.cancel(reason);
    }
  }

  void _onEmergencyStop(StopReason reason) {
    for (final token in _inFlightByRequestId.values) {
      token.cancel('stopped:${reason.wire}');
    }
  }

  /// Dispatches a `tools/call` request following the 8 rules in `UDC-3` §5.6.5:
  /// 1. Idempotency check on `invocationId`.
  /// 2. Schema & URL validation (`invalid_args`).
  /// 3. Fail-closed local policy check (`denied`).
  /// 4. Approval binding check (`argsSha256` & expiry) for `>= R2` (`denied`).
  /// 5. Emergency stop check (`denied`, `errorCode = "stopped"`).
  /// 6. Provider execution with deadline and cancellation support.
  /// 7. User toast notification (`"XUNA: đã mở VS Code"`).
  /// 8. Rotating content-free local audit JSONL entry.
  Future<XtpResponse> dispatch({
    required Object requestId,
    required ToolsCallParams params,
    DateTime? nowUtc,
  }) async {
    // Rule 1: Idempotency cache on invocationId.
    final cached = _idempotencyCache[params.invocationId];
    if (cached != null) {
      return XtpResponse(id: requestId, result: cached.result);
    }

    final stopwatch = Stopwatch()..start();
    final evaluator = policyStore.evaluator;
    final enrolled = enrollmentStore?.current;
    final evaluation = evaluator.evaluateInvocation(
      toolName: params.name,
      arguments: params.arguments,
      approval: params.approval,
      isStopped: stopController.isStopped,
      hostId: enrolled?.hostId,
      pinnedPhonePublicKeys:
          enrolled?.pinnedPhonePublicKeyBytes ?? const <Uint8List>[],
      isInApprovedCuSession: computerUseManager?.hasActiveSession ?? false,
      allowZeroConfigAppDiscovery: true,
      nowUtc: nowUtc,
    );

    if (!evaluation.allowed) {
      stopwatch.stop();
      final response = XtpResponse.toolCallResult(
        id: requestId,
        text:
            'Từ chối thực thi ${params.name} (${evaluation.errorCode ?? evaluation.status.wire}).',
        structuredContent: const <String, Object?>{},
        status: evaluation.status,
        durationMs: stopwatch.elapsedMilliseconds,
        errorCode: evaluation.errorCode,
      );
      await _recordOutcome(
        invocationId: params.invocationId,
        toolName: params.name,
        status: evaluation.status,
        errorCode: evaluation.errorCode,
        durationMs: stopwatch.elapsedMilliseconds,
        response: response,
        nowUtc: nowUtc,
      );
      return response;
    }

    final handler = _handlers[params.name];
    if (handler == null) {
      stopwatch.stop();
      final response = XtpResponse.toolCallResult(
        id: requestId,
        text: 'Công cụ chưa được hỗ trợ (${params.name}).',
        structuredContent: const <String, Object?>{},
        status: XtpStatus.unsupported,
        durationMs: stopwatch.elapsedMilliseconds,
        errorCode: 'platform_unsupported',
      );
      await _recordOutcome(
        invocationId: params.invocationId,
        toolName: params.name,
        status: XtpStatus.unsupported,
        errorCode: 'platform_unsupported',
        durationMs: stopwatch.elapsedMilliseconds,
        response: response,
        nowUtc: nowUtc,
      );
      return response;
    }

    final cancelToken = ToolCancellationToken();
    _inFlightByRequestId[requestId] = cancelToken;

    XtpStatus status = XtpStatus.ok;
    String? errorCode;
    String text = '';
    Map<String, Object?> structuredContent = const <String, Object?>{};
    String? toastBody;

    final effectiveNow = (nowUtc ?? DateTime.now()).toUtc();
    try {
      Future<ToolHandlerOutput> executeSubStep(
        String stepToolName,
        Map<String, Object?> stepArgs,
      ) async {
        final subHandler = _handlers[stepToolName];
        if (subHandler == null) {
          throw const XunaHostChannelException(
            status: XtpStatus.unsupported,
            errorCode: 'platform_unsupported',
          );
        }
        final syntheticApproval = ApprovalToken(
          approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c98',
          scope: 'once',
          expiresAt: effectiveNow.add(const Duration(minutes: 5)),
          argsSha256: argsSha256(stepArgs),
        );
        final subEval = evaluator.evaluateInvocation(
          toolName: stepToolName,
          arguments: stepArgs,
          approval: syntheticApproval,
          isStopped: stopController.isStopped,
          hostId: enrolled?.hostId,
          pinnedPhonePublicKeys:
              enrolled?.pinnedPhonePublicKeyBytes ?? const <Uint8List>[],
          isInApprovedCuSession: false,
          allowZeroConfigAppDiscovery: true,
          nowUtc: effectiveNow,
        );
        if (!subEval.allowed) {
          throw XunaHostChannelException(
            status: subEval.status,
            errorCode: subEval.errorCode ?? 'policy_blocked',
          );
        }
        final subContext = ToolExecutionContext(
          arguments: stepArgs,
          evaluation: subEval,
          policy: evaluator.policy,
          channel: channel,
          appScanner: appScanner,
          workspaceIndexer: workspaceIndexer,
          mcpBridge: mcpBridge,
          actionLedger: actionLedger,
          cancellationToken: cancelToken,
          agentVersion: agentVersion,
          nowUtc: effectiveNow,
          beamDirectoryPath: beamDirectoryPath,
        );
        final subOut = await subHandler.execute(subContext);
        actionLedger.record(
          originalTool: stepToolName,
          arguments: stepArgs,
          nowUtc: effectiveNow,
        );
        return subOut;
      }

      final execContext = ToolExecutionContext(
        arguments: params.arguments,
        evaluation: evaluation,
        policy: evaluator.policy,
        channel: channel,
        appScanner: appScanner,
        workspaceIndexer: workspaceIndexer,
        mcpBridge: mcpBridge,
        actionLedger: actionLedger,
        cancellationToken: cancelToken,
        agentVersion: agentVersion,
        nowUtc: effectiveNow,
        beamDirectoryPath: beamDirectoryPath,
        subStepExecutor: executeSubStep,
      );

      final deadline = Duration(milliseconds: params.deadlineMs);
      final output = await Future.any<ToolHandlerOutput?>(
        <Future<ToolHandlerOutput?>>[
          handler.execute(execContext),
          cancelToken.onCancelled.then((_) => null),
        ],
      ).timeout(deadline);

      if (cancelToken.isCancelled || output == null) {
        if (stopController.isStopped) {
          status = XtpStatus.denied;
          errorCode = 'stopped';
          text = 'Đã dừng khẩn cấp XUNA.';
        } else {
          status = XtpStatus.cancelled;
          errorCode = 'cancelled_by_caller';
          text = 'Đã hủy thực thi ${params.name}.';
        }
      } else {
        status = XtpStatus.ok;
        text = output.text;
        structuredContent = output.structuredContent;
        toastBody = output.toastBody;
        if (params.name != 'action.undo') {
          actionLedger.record(
            originalTool: params.name,
            arguments: params.arguments,
            nowUtc: effectiveNow,
          );
        }
      }
    } on TimeoutException {
      status = XtpStatus.timeout;
      errorCode = 'deadline_exceeded';
      text = 'Quá thời gian thực thi ${params.name}.';
    } on XunaHostChannelException catch (error) {
      status = error.status;
      errorCode = error.errorCode;
      text = 'Không thể thực thi ${params.name} (${error.errorCode}).';
    } catch (_) {
      status = XtpStatus.failed;
      errorCode = 'os_error';
      text = 'Lỗi hệ thống khi thực thi ${params.name}.';
    } finally {
      _inFlightByRequestId.remove(requestId);
      stopwatch.stop();
    }

    if (status == XtpStatus.ok && toastBody != null && toastBody.isNotEmpty) {
      try {
        await channel.showToast(title: 'XUNA', body: 'XUNA: $toastBody');
      } catch (_) {
        // Non-fatal if OS toast notification is unavailable.
      }
    }

    final response = XtpResponse.toolCallResult(
      id: requestId,
      text: text,
      structuredContent: structuredContent,
      status: status,
      durationMs: stopwatch.elapsedMilliseconds,
      errorCode: errorCode,
    );

    await _recordOutcome(
      invocationId: params.invocationId,
      toolName: params.name,
      status: status,
      errorCode: errorCode,
      durationMs: stopwatch.elapsedMilliseconds,
      response: response,
      nowUtc: nowUtc,
    );
    return response;
  }

  Future<void> _recordOutcome({
    required String invocationId,
    required String toolName,
    required XtpStatus status,
    required String? errorCode,
    required int durationMs,
    required XtpResponse response,
    DateTime? nowUtc,
  }) async {
    while (_idempotencyCache.length >= maxIdempotencyCacheEntries) {
      _idempotencyCache.remove(_idempotencyCache.keys.first);
    }
    _idempotencyCache[invocationId] = response;

    logger.info('tool.call', <String, Object?>{
      'invocationId': invocationId,
      'tool': toolName,
      'status': status.wire,
      if (errorCode != null) 'errorCode': errorCode,
      'durationMs': durationMs,
    });

    try {
      await auditStore.append(
        AuditLogRecord(
          ts: (nowUtc ?? DateTime.now()).toUtc(),
          invocationId: invocationId,
          tool: toolName,
          status: status,
          durationMs: durationMs,
        ),
      );
    } catch (_) {
      // Do not fail the RPC response if disk audit write encounters an error.
    }
  }

  void dispose() {
    stopController.removeCancelListener(_onEmergencyStop);
  }
}
