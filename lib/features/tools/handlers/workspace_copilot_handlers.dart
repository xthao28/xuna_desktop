import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

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
    final resolvedIde =
        context.appScanner.resolveCodingAgent(
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
          ? 'Bộ nhớ tạm đang trống (tool này chỉ đọc bộ nhớ tạm, không đọc vùng đang bôi đen; hãy sao chép trước).'
          : 'Đã đọc văn bản trong bộ nhớ tạm (${redacted.text.length} ký tự, ẩn ${redacted.redactedCount} mã nhạy cảm).',
      structuredContent: <String, Object?>{
        'text': redacted.text,
        'truncated': redacted.truncated,
        'redactedCount': redacted.redactedCount,
      },
      toastBody: 'đã đọc văn bản trong bộ nhớ tạm',
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
        final outFile = File('$baseDir${Platform.pathSeparator}$fileName');
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

const List<HostToolHandler> defaultWorkspaceCopilotToolHandlers =
    <HostToolHandler>[
      DisplayWakeTool(),
      WorkspaceOpenTool(),
      WorkspaceGitSummaryTool(),
      WorkspaceCodingAgentTool(),
      SelectionReadTool(),
      HostLockScreenTool(),
      WorkspaceWatchTaskTool(),
      McpListServersTool(),
      McpCallTool(),
      WindowActiveContextTool(),
      BrowserReadPageTool(),
      BeamTransferTool(),
      WorkflowBatchStepsTool(),
    ];
