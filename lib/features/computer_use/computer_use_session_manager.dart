import 'dart:async';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/computer_use/driver_map.dart';
import 'package:xuna_desktop/features/computer_use/mcp_stdio_client.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Snapshot of the active window returned by a [ComputerUseProvider].
class ActiveWindowObservation {
  const ActiveWindowObservation({
    required this.appId,
    required this.processName,
    required this.windowTitle,
    required this.nodes,
    this.browserUrl,
    this.isElevated = false,
    this.pid = 1000,
    this.windowId = 1,
    this.focusedRole,
  });

  final String appId;
  final String processName;
  final String windowTitle;
  final List<Map<String, Object?>> nodes;
  final String? browserUrl;

  /// Normalised role of the element holding keyboard focus (`searchfield`,
  /// `textfield`, `textarea`…), or `null` when the adapter cannot tell it
  /// exactly. Exact means role *and* subrole are known, so a secure field is
  /// never reported as a text field. `null` keeps Enter/Space at R3
  /// (ADR-0015 D2).
  final String? focusedRole;
  final bool isElevated;
  final int pid;
  final int windowId;

  /// Computes a canonical state fingerprint over window title and nodes so the
  /// agent can verify whether an `input.*` action actually changed the UI
  /// (`SendInput` fails silently under Windows UIPI; `UDC-8` §3 & §4.2).
  String stateDigest() => argsSha256(<String, Object?>{
    'appId': appId,
    'windowTitle': windowTitle,
    'nodes': redactUiTreeNodes(nodes),
  });
}

/// Captured JPEG screenshot returned by `screen.capture` (`UDC-8` §4.2).
class ScreenCaptureObservation {
  const ScreenCaptureObservation({
    this.mimeType = 'image/jpeg',
    required this.width,
    required this.height,
    required this.dataBase64,
  });

  final String mimeType;
  final int width;
  final int height;
  final String dataBase64;
}

/// Provider abstraction for desktop computer use (`UDC-8` §4.1):
/// backed either by a bounded `cua-driver mcp` child process
/// ([CuaDriverComputerUseProvider]), a `vercel-labs/agent-desktop mcp` child
/// process ([AgentDesktopComputerUseProvider]), or the native UIA/AX fallback
/// provider ([FallbackUiaAxComputerUseProvider]).
abstract interface class ComputerUseProvider {
  Future<void> startSession({
    required String sessionId,
    required String capabilityManifestYaml,
  });

  Future<ActiveWindowObservation> inspectActiveWindow({required int maxNodes});

  Future<ScreenCaptureObservation> captureScreen({
    required String scope,
    required int maxEdge,
  });

  Future<void> performClick({
    required ActiveWindowObservation window,
    String? elementId,
    int? x,
    int? y,
  });

  Future<void> performTypeText({
    required ActiveWindowObservation window,
    required String elementId,
    required String text,
  });

  Future<void> performKey({
    required ActiveWindowObservation window,
    required String combo,
  });

  Future<void> performScroll({
    required ActiveWindowObservation window,
    String? elementId,
    required String direction,
    required int amount,
  });

  Future<void> endSession({required String sessionId});
}

/// Computer-use provider driving a bounded `cua-driver mcp` stdio child
/// (`UDC-8` S8.1 & S8.2).
class CuaDriverComputerUseProvider implements ComputerUseProvider {
  CuaDriverComputerUseProvider({required this.clientFactory});

  final Future<McpStdioClient> Function(String capabilityManifestYaml)
  clientFactory;

  McpStdioClient? _client;
  String? _activeSessionId;

  @override
  Future<void> startSession({
    required String sessionId,
    required String capabilityManifestYaml,
  }) async {
    await _client?.close();
    _client = await clientFactory(capabilityManifestYaml);
    _activeSessionId = sessionId;
    await _client!.callTool(
      name: CuaDriverMap.toCuaDriverTool(xunaToolName: 'cu.session_start'),
      arguments: CuaDriverMap.toCuaDriverArguments(
        xunaToolName: 'cu.session_start',
        sessionId: sessionId,
        arguments: const <String, Object?>{},
      ),
    );
  }

  @override
  Future<ActiveWindowObservation> inspectActiveWindow({
    required int maxNodes,
  }) async {
    final client = _requireClient();
    final raw = await client.callTool(
      name: CuaDriverMap.toCuaDriverTool(xunaToolName: 'ui.inspect'),
      arguments: CuaDriverMap.toCuaDriverArguments(
        xunaToolName: 'ui.inspect',
        sessionId: _activeSessionId ?? 'default',
        arguments: <String, Object?>{
          'scope': 'active_window',
          'maxNodes': maxNodes,
        },
      ),
    );
    final structured =
        (raw['structuredContent'] as Map?)?.cast<String, Object?>() ?? raw;
    final rawNodes = structured['nodes'] as List? ?? const <Object?>[];
    final nodes = <Map<String, Object?>>[
      for (final item in rawNodes)
        if (item is Map) item.cast<String, Object?>(),
    ];
    return ActiveWindowObservation(
      appId: (structured['appId'] as String?) ?? 'unknown',
      processName:
          (structured['processName'] as String?) ??
          (structured['appId'] as String?) ??
          'unknown',
      windowTitle: (structured['windowTitle'] as String?) ?? '',
      browserUrl: structured['browserUrl'] as String?,
      isElevated: structured['isElevated'] == true,
      pid: (structured['pid'] as int?) ?? 1000,
      windowId: (structured['windowId'] as int?) ?? 1,
      nodes: nodes,
    );
  }

  @override
  Future<ScreenCaptureObservation> captureScreen({
    required String scope,
    required int maxEdge,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{'scope': scope, 'maxEdge': maxEdge};
    final raw = await client.callTool(
      name: CuaDriverMap.toCuaDriverTool(
        xunaToolName: 'screen.capture',
        arguments: args,
      ),
      arguments: CuaDriverMap.toCuaDriverArguments(
        xunaToolName: 'screen.capture',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
      ),
    );
    final structured =
        (raw['structuredContent'] as Map?)?.cast<String, Object?>() ?? raw;
    return ScreenCaptureObservation(
      mimeType: (structured['mimeType'] as String?) ?? 'image/jpeg',
      width: (structured['width'] as int?) ?? 1280,
      height: (structured['height'] as int?) ?? 720,
      dataBase64: (structured['dataBase64'] as String?) ?? '',
    );
  }

  @override
  Future<void> performClick({
    required ActiveWindowObservation window,
    String? elementId,
    int? x,
    int? y,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{
      if (elementId != null) 'elementId': elementId,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
    };
    await client.callTool(
      name: CuaDriverMap.toCuaDriverTool(
        xunaToolName: 'input.click',
        arguments: args,
      ),
      arguments: CuaDriverMap.toCuaDriverArguments(
        xunaToolName: 'input.click',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
        targetPid: window.pid,
        targetWindowId: window.windowId,
      ),
    );
  }

  @override
  Future<void> performTypeText({
    required ActiveWindowObservation window,
    required String elementId,
    required String text,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{'elementId': elementId, 'text': text};
    await client.callTool(
      name: CuaDriverMap.toCuaDriverTool(
        xunaToolName: 'input.type_text',
        arguments: args,
      ),
      arguments: CuaDriverMap.toCuaDriverArguments(
        xunaToolName: 'input.type_text',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
        targetPid: window.pid,
        targetWindowId: window.windowId,
      ),
    );
  }

  @override
  Future<void> performKey({
    required ActiveWindowObservation window,
    required String combo,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{'combo': combo};
    await client.callTool(
      name: CuaDriverMap.toCuaDriverTool(
        xunaToolName: 'input.key',
        arguments: args,
      ),
      arguments: CuaDriverMap.toCuaDriverArguments(
        xunaToolName: 'input.key',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
        targetPid: window.pid,
        targetWindowId: window.windowId,
      ),
    );
  }

  @override
  Future<void> performScroll({
    required ActiveWindowObservation window,
    String? elementId,
    required String direction,
    required int amount,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{
      if (elementId != null) 'elementId': elementId,
      'direction': direction,
      'amount': amount,
    };
    await client.callTool(
      name: CuaDriverMap.toCuaDriverTool(
        xunaToolName: 'input.scroll',
        arguments: args,
      ),
      arguments: CuaDriverMap.toCuaDriverArguments(
        xunaToolName: 'input.scroll',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
        targetPid: window.pid,
        targetWindowId: window.windowId,
      ),
    );
  }

  @override
  Future<void> endSession({required String sessionId}) async {
    final client = _client;
    _client = null;
    _activeSessionId = null;
    if (client == null) return;
    try {
      await client.callTool(
        name: CuaDriverMap.toCuaDriverTool(xunaToolName: 'cu.session_end'),
        arguments: CuaDriverMap.toCuaDriverArguments(
          xunaToolName: 'cu.session_end',
          sessionId: sessionId,
          arguments: <String, Object?>{
            'sessionId': sessionId,
            'outcome': 'completed',
          },
        ),
      );
    } catch (_) {
      // Ignore errors when shutting down the child process.
    } finally {
      await client.close();
    }
  }

  McpStdioClient _requireClient() {
    final client = _client;
    if (client == null || client.isClosed) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'cu_driver_not_running',
      );
    }
    return client;
  }
}

/// Computer-use provider driving a `vercel-labs/agent-desktop mcp` stdio child
/// (`AgentDesktopDriverMap`).
///
/// Unwraps `agent-desktop` JSON envelopes (`{"version": "1.0", "ok": bool, "data": ..., "error": ...}`),
/// maps `STALE_REF` / `AMBIGUOUS_TARGET` / `PERM_DENIED` errors to
/// [XunaHostChannelException], and routes headless semantic vs physical headed
/// actions.
class AgentDesktopComputerUseProvider implements ComputerUseProvider {
  AgentDesktopComputerUseProvider({
    required this.clientFactory,
    this.defaultAppId = 'explorer',
  });

  final Future<McpStdioClient> Function(String capabilityManifestYaml)
  clientFactory;
  final String defaultAppId;

  McpStdioClient? _client;
  String? _activeSessionId;

  @override
  Future<void> startSession({
    required String sessionId,
    required String capabilityManifestYaml,
  }) async {
    await _client?.close();
    _client = await clientFactory(capabilityManifestYaml);
    _activeSessionId = sessionId;
    final raw = await _client!.callTool(
      name: AgentDesktopDriverMap.toAgentDesktopTool(
        xunaToolName: 'cu.session_start',
      ),
      arguments: AgentDesktopDriverMap.toAgentDesktopArguments(
        xunaToolName: 'cu.session_start',
        sessionId: sessionId,
        arguments: const <String, Object?>{},
      ),
    );
    _unwrapEnvelopeOrThrow(raw);
  }

  @override
  Future<ActiveWindowObservation> inspectActiveWindow({
    required int maxNodes,
  }) async {
    final client = _requireClient();
    final raw = await client.callTool(
      name: AgentDesktopDriverMap.toAgentDesktopTool(
        xunaToolName: 'ui.inspect',
      ),
      arguments: AgentDesktopDriverMap.toAgentDesktopArguments(
        xunaToolName: 'ui.inspect',
        sessionId: _activeSessionId ?? 'default',
        arguments: <String, Object?>{
          'scope': 'active_window',
          'maxNodes': maxNodes,
        },
      ),
    );
    final data = _unwrapEnvelopeOrThrow(raw);
    final snapshotId = (data['snapshot_id'] as String?) ?? 's00000001';
    final windowMap = (data['window'] as Map?)?.cast<String, Object?>() ?? data;
    final rawApp =
        (windowMap['app'] as String?) ??
        (data['appId'] as String?) ??
        defaultAppId;
    final rawTitle =
        (windowMap['title'] as String?) ??
        (data['windowTitle'] as String?) ??
        '';
    final rawNodes =
        (data['nodes'] as List?) ??
        (data['tree'] is Map
            ? (data['tree'] as Map)['children'] as List?
            : null) ??
        const <Object?>[];

    final nodes = <Map<String, Object?>>[];
    var counter = 0;
    void collectNodes(List<Object?> list, {int depth = 0, String? parentId}) {
      for (final item in list) {
        if (nodes.length >= maxNodes) return;
        if (item is! Map) continue;
        final map = item.cast<String, Object?>();
        counter++;
        final ref =
            (map['ref_id'] as String?) ??
            (map['ref'] as String?) ??
            (map['id'] as String?) ??
            '@$snapshotId:e$counter';
        final id =
            (map['id'] as String?) ??
            (ref.startsWith('@') ? ref.substring(1) : ref);
        final states =
            (map['states'] as List?)?.map((e) => '$e'.toLowerCase()).toSet() ??
            const <String>{};
        final children = map['children'] as List?;
        nodes.add(<String, Object?>{
          'id': id,
          'ref': ref.startsWith('@') ? ref : '@$ref',
          'role': (map['role'] as String?) ?? 'unknown',
          'name': (map['name'] as String?) ?? (map['title'] as String?) ?? '',
          if (map['value'] != null) 'value': '${map['value']}',
          'enabled': map['enabled'] != false && !states.contains('disabled'),
          if (map['bounds'] is Map)
            'bounds': (map['bounds'] as Map).cast<String, Object?>(),
          if (map['visible'] is bool) 'visible': map['visible'],
          if (map['editable'] is bool) 'editable': map['editable'],
          if (map['occluded'] is bool) 'occluded': map['occluded'],
          if (map['modal'] is bool) 'modal': map['modal'],
          if (map['native_id'] is String) 'nativeId': map['native_id'],
          'depth': (map['depth'] as int?) ?? depth,
          if (parentId != null) 'parentId': parentId,
          if (children != null) 'childrenCount': children.length,
        });
        if (children != null && children.isNotEmpty) {
          collectNodes(children, depth: depth + 1, parentId: id);
        }
      }
    }

    collectNodes(rawNodes);
    return ActiveWindowObservation(
      appId: rawApp,
      processName: (data['processName'] as String?) ?? rawApp,
      windowTitle: rawTitle,
      browserUrl: data['browserUrl'] as String?,
      isElevated: data['isElevated'] == true,
      pid: (windowMap['pid'] as int?) ?? (data['pid'] as int?) ?? 1000,
      windowId: (data['windowId'] as int?) ?? 1,
      nodes: nodes,
    );
  }

  @override
  Future<ScreenCaptureObservation> captureScreen({
    required String scope,
    required int maxEdge,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{'scope': scope, 'maxEdge': maxEdge};
    final raw = await client.callTool(
      name: AgentDesktopDriverMap.toAgentDesktopTool(
        xunaToolName: 'screen.capture',
        arguments: args,
      ),
      arguments: AgentDesktopDriverMap.toAgentDesktopArguments(
        xunaToolName: 'screen.capture',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
      ),
    );
    final data = _unwrapEnvelopeOrThrow(raw);
    return ScreenCaptureObservation(
      mimeType: (data['mimeType'] as String?) ?? 'image/jpeg',
      width: (data['width'] as int?) ?? maxEdge,
      height: (data['height'] as int?) ?? ((maxEdge * 9) ~/ 16),
      dataBase64:
          (data['dataBase64'] as String?) ?? (data['base64'] as String?) ?? '',
    );
  }

  @override
  Future<void> performClick({
    required ActiveWindowObservation window,
    String? elementId,
    int? x,
    int? y,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{
      if (elementId != null) 'elementId': elementId,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
    };
    final raw = await client.callTool(
      name: AgentDesktopDriverMap.toAgentDesktopTool(
        xunaToolName: 'input.click',
        arguments: args,
      ),
      arguments: AgentDesktopDriverMap.toAgentDesktopArguments(
        xunaToolName: 'input.click',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
        targetApp: window.appId,
        targetWindowId: window.windowId,
      ),
    );
    _unwrapEnvelopeOrThrow(raw);
  }

  @override
  Future<void> performTypeText({
    required ActiveWindowObservation window,
    required String elementId,
    required String text,
    bool headed = false,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{
      'elementId': elementId,
      'text': text,
      if (headed) 'headed': true,
    };
    final raw = await client.callTool(
      name: AgentDesktopDriverMap.toAgentDesktopTool(
        xunaToolName: 'input.type_text',
        arguments: args,
      ),
      arguments: AgentDesktopDriverMap.toAgentDesktopArguments(
        xunaToolName: 'input.type_text',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
        targetApp: window.appId,
        targetWindowId: window.windowId,
      ),
    );
    _unwrapEnvelopeOrThrow(raw);
  }

  @override
  Future<void> performKey({
    required ActiveWindowObservation window,
    required String combo,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{'combo': combo};
    final raw = await client.callTool(
      name: AgentDesktopDriverMap.toAgentDesktopTool(
        xunaToolName: 'input.key',
        arguments: args,
      ),
      arguments: AgentDesktopDriverMap.toAgentDesktopArguments(
        xunaToolName: 'input.key',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
        targetApp: window.appId,
        targetWindowId: window.windowId,
      ),
    );
    _unwrapEnvelopeOrThrow(raw);
  }

  @override
  Future<void> performScroll({
    required ActiveWindowObservation window,
    String? elementId,
    required String direction,
    required int amount,
  }) async {
    final client = _requireClient();
    final args = <String, Object?>{
      if (elementId != null) 'elementId': elementId,
      'direction': direction,
      'amount': amount,
    };
    final raw = await client.callTool(
      name: AgentDesktopDriverMap.toAgentDesktopTool(
        xunaToolName: 'input.scroll',
        arguments: args,
      ),
      arguments: AgentDesktopDriverMap.toAgentDesktopArguments(
        xunaToolName: 'input.scroll',
        sessionId: _activeSessionId ?? 'default',
        arguments: args,
        targetApp: window.appId,
        targetWindowId: window.windowId,
      ),
    );
    _unwrapEnvelopeOrThrow(raw);
  }

  @override
  Future<void> endSession({required String sessionId}) async {
    final client = _client;
    _client = null;
    _activeSessionId = null;
    if (client == null) return;
    try {
      await client.callTool(
        name: AgentDesktopDriverMap.toAgentDesktopTool(
          xunaToolName: 'cu.session_end',
        ),
        arguments: AgentDesktopDriverMap.toAgentDesktopArguments(
          xunaToolName: 'cu.session_end',
          sessionId: sessionId,
          arguments: <String, Object?>{'sessionId': sessionId},
        ),
      );
    } catch (_) {
      // Ignore errors when shutting down the child process.
    } finally {
      await client.close();
    }
  }

  Map<String, Object?> _unwrapEnvelopeOrThrow(Map<String, Object?> raw) {
    final structured =
        (raw['structuredContent'] as Map?)?.cast<String, Object?>() ?? raw;
    if (structured['ok'] == false || raw['isError'] == true) {
      final errMap = (structured['error'] as Map?)?.cast<String, Object?>();
      final mapped = AgentDesktopDriverMap.mapErrorCode(
        errMap?['code'] as String?,
      );
      throw XunaHostChannelException(
        status: mapped.status,
        errorCode: mapped.errorCode,
      );
    }
    final data = structured['data'];
    if (data is Map) {
      return data.cast<String, Object?>();
    }
    return structured;
  }

  McpStdioClient _requireClient() {
    final client = _client;
    if (client == null || client.isClosed) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'cu_driver_not_running',
      );
    }
    return client;
  }
}

/// Live OS Computer-Use provider bridging [ComputerUseSessionManager] directly
/// to the native OS [XunaHostChannel] (`Windows IUIAutomation` in
/// `xuna_win_uia_engine.h`, `macOS AXUIElement` in `XunaMacHostPlugin.swift`,
/// or Linux X11 fallback), with optional delegation to an external
/// `agent-desktop` MCP binary when `XUNA_AGENT_DESKTOP_BIN` is configured.
class NativeHostChannelComputerUseProvider implements ComputerUseProvider {
  /// Largest number of controls the native layer can act on by `ui_N` ref.
  ///
  /// Native refs are ordinals in a list that `invokeWindowUiControl` rebuilds
  /// with a cap of 60 (`xuna_win_uia_engine.h`, `ExecuteInvokeWindowUiControl`).
  /// `inspectWindowUiTree` can list up to 80, so refs 61..80 would be offered to
  /// the model but could never be invoked. Inspecting no more than this cap keeps
  /// every offered ref actionable. Keep it equal to the native invoke cap.
  static const int nativeActionableNodeCap = 60;

  NativeHostChannelComputerUseProvider({
    required this.channel,
    this.agentDesktopBinaryPath,
    bool? isWindowsHost,
  }) : isWindowsHost = isWindowsHost ?? Platform.isWindows;

  final XunaHostChannel channel;
  final String? agentDesktopBinaryPath;

  /// The Windows UIA engine reports a UIA `Document` (a whole web page or a
  /// document body) as `AXTextArea`. On Windows that role is therefore mapped
  /// to `document`, which is not a draft text field (ADR-0015 D1).
  final bool isWindowsHost;
  AgentDesktopComputerUseProvider? _externalDelegate;

  static const Set<String> _browserAppIds = <String>{
    'msedge',
    'microsoft_edge',
    'edge',
    'chrome',
    'google_chrome',
    'firefox',
    'brave',
    'brave_browser',
    'safari',
    'arc',
    'browser',
  };

  static const Set<String> _browserBundleIds = <String>{
    'com.apple.safari',
    'com.google.chrome',
    'com.microsoft.edgemac',
    'org.mozilla.firefox',
    'com.brave.browser',
    'company.thebrowser.browser',
  };

  /// Returns `true` only when an external screen-capture MCP driver binary is
  /// configured and present on disk (`H6` manifest truthfulness).
  bool get hasExternalCaptureDriver {
    if (_externalDelegate != null) return true;
    final binPath =
        (agentDesktopBinaryPath ??
                Platform.environment['XUNA_AGENT_DESKTOP_BIN'] ??
                '')
            .trim();
    return binPath.isNotEmpty && File(binPath).existsSync();
  }

  @override
  Future<void> startSession({
    required String sessionId,
    required String capabilityManifestYaml,
  }) async {
    _externalDelegate = null;
    final binPath =
        (agentDesktopBinaryPath ??
                Platform.environment['XUNA_AGENT_DESKTOP_BIN'] ??
                '')
            .trim();
    if (binPath.isNotEmpty) {
      try {
        final delegate = AgentDesktopComputerUseProvider(
          clientFactory: (_) => McpStdioClient.spawn(
            executable: binPath,
            arguments: const <String>['mcp'],
          ),
        );
        await delegate.startSession(
          sessionId: sessionId,
          capabilityManifestYaml: capabilityManifestYaml,
        );
        _externalDelegate = delegate;
        return;
      } catch (_) {
        _externalDelegate = null;
      }
    }
  }

  @override
  Future<ActiveWindowObservation> inspectActiveWindow({
    required int maxNodes,
  }) async {
    if (_externalDelegate != null) {
      return _externalDelegate!.inspectActiveWindow(maxNodes: maxNodes);
    }
    final ctx = await channel.readActiveWindowContext(maxChars: 600);
    final tree = await channel.inspectWindowUiTree(
      maxNodes: maxNodes.clamp(1, nativeActionableNodeCap),
    );
    final rawProc =
        (ctx.processName.trim().isNotEmpty && ctx.processName != 'unknown')
        ? ctx.processName.trim()
        : (tree.appName.trim().isNotEmpty ? tree.appName.trim() : 'unknown');
    final rawAppName =
        (ctx.appName.trim().isNotEmpty && ctx.appName != 'unknown')
        ? ctx.appName.trim()
        : tree.appName.trim();
    final isReverseDnsBundleId =
        rawProc.contains('.') &&
        !rawProc.toLowerCase().endsWith('.exe') &&
        !rawProc.toLowerCase().endsWith('.app') &&
        !rawProc.contains('/') &&
        !rawProc.contains(r'\');
    final appId = (isReverseDnsBundleId && rawAppName.isNotEmpty)
        ? AutoAppScanner.normalizeId(rawAppName)
        : normalizeAppIdFromProcess(rawProc);
    final winTitle = tree.windowTitle.trim().isNotEmpty
        ? tree.windowTitle.trim()
        : ctx.windowTitle.trim();

    String? browserUrl;
    final isBrowser =
        _browserAppIds.contains(appId) ||
        _browserBundleIds.contains(rawProc.toLowerCase()) ||
        _browserAppIds.contains(normalizeAppIdFromProcess(rawProc));
    if (isBrowser) {
      try {
        final tab = await channel.browserCurrentUrl();
        if (tab.url.trim().isNotEmpty) {
          browserUrl = tab.url.trim();
        }
      } catch (_) {
        // Best-effort browser URL lookup.
      }
    }

    final mappedNodes = <Map<String, Object?>>[];
    for (var i = 0; i < tree.nodes.length; i++) {
      final raw = tree.nodes[i];
      final refId = (raw['refId'] as String?) ?? 'ui_${i + 1}';
      final isPwd = raw['isPassword'] == true;
      final rawRole = (raw['role'] as String?) ?? 'button';
      final role = isPwd
          ? 'password'
          : (isWindowsHost && rawRole.trim().toLowerCase() == 'axtextarea')
          ? 'document'
          : _normalizeNativeRole(rawRole);
      final label = (raw['label'] as String?) ?? (raw['name'] as String?) ?? '';
      final val = raw['value']?.toString();
      final editable = raw['editable'] is bool
          ? raw['editable'] as bool
          : _isEditableRole(role);
      mappedNodes.add(<String, Object?>{
        'id': refId,
        'role': role,
        'name': label,
        if (val != null && val.isNotEmpty) 'value': val,
        'enabled': raw['enabled'] != false,
        'visible': raw['visible'] != false,
        'editable': editable,
        'isPassword': isPwd,
      });
    }

    return ActiveWindowObservation(
      appId: appId,
      processName: rawProc,
      windowTitle: winTitle,
      browserUrl: browserUrl,
      isElevated: ctx.isElevated,
      nodes: mappedNodes,
      // Not reported: `readActiveWindowContext` gives only the AX role on
      // macOS (a search or secure field is `AXTextField` with a subrole) and a
      // localized control type on Windows. Neither is exact, so Enter/Space
      // stay R3 until the native readers report role + subrole / control type
      // id (UDC-17 S17.2, native part).
      focusedRole: null,
    );
  }

  @override
  Future<ScreenCaptureObservation> captureScreen({
    required String scope,
    required int maxEdge,
  }) async {
    if (_externalDelegate != null) {
      return _externalDelegate!.captureScreen(scope: scope, maxEdge: maxEdge);
    }
    // No capture driver: an empty image would be reported as a successful screenshot.
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'screen_capture_unavailable',
      message:
          'No screen-capture driver is configured on this host; use '
          'ui.accessibility_tree to read the window instead.',
    );
  }

  @override
  Future<void> performClick({
    required ActiveWindowObservation window,
    String? elementId,
    int? x,
    int? y,
  }) async {
    if (_externalDelegate != null) {
      await _externalDelegate!.performClick(
        window: window,
        elementId: elementId,
        x: x,
        y: y,
      );
      return;
    }
    final canonicalRef = _toNativeUiRefId(elementId);
    final res = await channel.invokeWindowUiControl(
      action: 'invoke_ref',
      refId: canonicalRef,
      windowTitle: window.windowTitle,
      submit: false,
    );
    _verifyNativeControlResult(res);
  }

  @override
  Future<void> performTypeText({
    required ActiveWindowObservation window,
    required String elementId,
    required String text,
  }) async {
    if (_externalDelegate != null) {
      await _externalDelegate!.performTypeText(
        window: window,
        elementId: elementId,
        text: text,
      );
      return;
    }
    final canonicalRef = _toNativeUiRefId(elementId);
    final res = await channel.invokeWindowUiControl(
      action: 'set_value_ref',
      refId: canonicalRef,
      windowTitle: window.windowTitle,
      valueText: text,
      submit: false,
    );
    _verifyNativeControlResult(res);
  }

  @override
  Future<void> performKey({
    required ActiveWindowObservation window,
    required String combo,
  }) async {
    if (_externalDelegate != null) {
      await _externalDelegate!.performKey(window: window, combo: combo);
      return;
    }
    final spec = combo.startsWith('shortcut:') ? combo : 'shortcut:$combo';
    final res = await channel.invokeWindowUiControl(
      action: 'shortcut',
      refId: spec,
      windowTitle: window.windowTitle,
      valueText: combo,
      submit: false,
    );
    _verifyNativeControlResult(res);
  }

  @override
  Future<void> performScroll({
    required ActiveWindowObservation window,
    String? elementId,
    required String direction,
    required int amount,
  }) async {
    if (_externalDelegate != null) {
      await _externalDelegate!.performScroll(
        window: window,
        elementId: elementId,
        direction: direction,
        amount: amount,
      );
      return;
    }
    final dir = direction.trim().toLowerCase();
    final canonicalRef = _toNativeUiRefId(elementId);
    final res = await channel.invokeWindowUiControl(
      action: 'scroll_$dir',
      refId: canonicalRef,
      windowTitle: window.windowTitle,
      valueText: dir,
      submit: false,
    );
    _verifyNativeControlResult(res);
  }

  @override
  Future<void> endSession({required String sessionId}) async {
    final delegate = _externalDelegate;
    _externalDelegate = null;
    if (delegate != null) {
      await delegate.endSession(sessionId: sessionId);
    }
  }

  static String normalizeAppIdFromProcess(String rawProcess) {
    var lower = rawProcess.trim().toLowerCase();
    final slashIdx = lower.lastIndexOf(RegExp(r'[\\/]'));
    if (slashIdx >= 0 && slashIdx + 1 < lower.length) {
      lower = lower.substring(slashIdx + 1);
    }
    if (lower.endsWith('.exe') && lower.length > 4) {
      lower = lower.substring(0, lower.length - 4);
    }
    if (lower.endsWith('.app') && lower.length > 4) {
      lower = lower.substring(0, lower.length - 4);
    }
    final clean = lower
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return clean.isEmpty ? 'unknown' : clean;
  }

  static String _normalizeNativeRole(String rawRole) {
    final lower = rawRole.trim().toLowerCase();
    return switch (lower) {
      'axbutton' => 'button',
      'axtextfield' => 'textfield',
      'axsearchfield' => 'searchfield',
      'axcombobox' => 'combobox',
      'axtextarea' => 'textarea',
      'axcheckbox' => 'checkbox',
      'axradiobutton' => 'radiobutton',
      'axmenuitem' => 'menuitem',
      'axrow' => 'list_item',
      'axlink' => 'link',
      _ => lower.isEmpty ? 'button' : lower,
    };
  }

  static bool _isEditableRole(String normalizedRole) {
    return const <String>{
      'textfield',
      'axtextfield',
      'searchbox',
      'searchfield',
      'axsearchfield',
      'combobox',
      'axcombobox',
      'textarea',
      'axtextarea',
      'edit',
      'document',
    }.contains(normalizedRole.toLowerCase());
  }

  /// Maps a resolved element id to the native `ui_N` ref. Never guesses: a
  /// missing or unparseable id is an error (H3), not "the first control".
  static String _toNativeUiRefId(String? rawElementId) {
    if (rawElementId == null || rawElementId.trim().isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'target_required',
        message:
            'A resolved element ref is required; coordinates are not a target.',
      );
    }
    final trimmed = rawElementId.trim();
    if (trimmed.startsWith('ui_') || trimmed.startsWith('shortcut:')) {
      return trimmed;
    }
    final parsed = parseSnapshotElementRef(trimmed);
    if (parsed != null) {
      return 'ui_${parsed.elementNumber}';
    }
    throw const XunaHostChannelException(
      status: XtpStatus.invalidArgs,
      errorCode: 'ref_unresolvable',
      message: 'The element ref is not a native or snapshot ref.',
    );
  }

  static void _verifyNativeControlResult(WindowUiControlActionResult res) {
    if (res.detail == 'REFUSED_PASSWORD_CONTROL') {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'password_field_forbidden',
      );
    }
    if (res.detail == 'HARD_DENIED_OR_ELEVATED_WINDOW') {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'elevated_window_forbidden',
      );
    }
    if (!res.ok) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
        message: res.detail,
      );
    }
  }
}

/// Fallback UIA (Windows) / AX + ScreenCaptureKit (macOS) provider skeleton
/// (`UDC-8` §4.1 & S8.2) used when the Cua Driver binary is unavailable or in
/// deterministic unit/E2E tests.
class FallbackUiaAxComputerUseProvider implements ComputerUseProvider {
  FallbackUiaAxComputerUseProvider({
    ActiveWindowObservation? initialWindow,
    this.simulateSilentUipiDrop = false,
  }) : currentWindow =
           initialWindow ??
           const ActiveWindowObservation(
             appId: 'explorer',
             processName: 'explorer.exe',
             windowTitle: 'Reports',
             nodes: <Map<String, Object?>>[
               <String, Object?>{
                 'id': 's00000001:1',
                 'role': 'list_item',
                 'name': 'BaoCao_2026_10_31.pdf',
                 'enabled': true,
               },
               <String, Object?>{
                 'id': 's00000001:2',
                 'role': 'textfield',
                 'name': 'Tìm kiếm báo cáo',
                 'enabled': true,
               },
             ],
           );

  ActiveWindowObservation currentWindow;
  bool simulateSilentUipiDrop;
  String? lastManifestYaml;
  final List<String> recordedCalls = <String>[];
  int _mutationCounter = 0;

  @override
  Future<void> startSession({
    required String sessionId,
    required String capabilityManifestYaml,
  }) async {
    lastManifestYaml = capabilityManifestYaml;
    recordedCalls.add('startSession:$sessionId');
  }

  @override
  Future<ActiveWindowObservation> inspectActiveWindow({
    required int maxNodes,
  }) async {
    recordedCalls.add('inspect:$maxNodes');
    return ActiveWindowObservation(
      appId: currentWindow.appId,
      processName: currentWindow.processName,
      windowTitle: currentWindow.windowTitle,
      browserUrl: currentWindow.browserUrl,
      isElevated: currentWindow.isElevated,
      pid: currentWindow.pid,
      windowId: currentWindow.windowId,
      nodes: currentWindow.nodes.take(maxNodes).toList(),
      focusedRole: currentWindow.focusedRole,
    );
  }

  @override
  Future<ScreenCaptureObservation> captureScreen({
    required String scope,
    required int maxEdge,
  }) async {
    recordedCalls.add('capture:$scope:$maxEdge');
    return ScreenCaptureObservation(
      width: maxEdge,
      height: (maxEdge * 9) ~/ 16,
      dataBase64: 'dGVzdC1qcGVnLWJ5dGVz',
    );
  }

  @override
  Future<void> performClick({
    required ActiveWindowObservation window,
    String? elementId,
    int? x,
    int? y,
  }) async {
    recordedCalls.add('click:${elementId ?? "$x,$y"}');
    _mutateWindowIfAllowed('click:${elementId ?? "$x,$y"}');
  }

  @override
  Future<void> performTypeText({
    required ActiveWindowObservation window,
    required String elementId,
    required String text,
  }) async {
    recordedCalls.add('type:$elementId');
    _mutateWindowIfAllowed('type:$elementId');
  }

  @override
  Future<void> performKey({
    required ActiveWindowObservation window,
    required String combo,
  }) async {
    recordedCalls.add('key:$combo');
    _mutateWindowIfAllowed('key:$combo');
  }

  @override
  Future<void> performScroll({
    required ActiveWindowObservation window,
    String? elementId,
    required String direction,
    required int amount,
  }) async {
    recordedCalls.add('scroll:$direction:$amount');
    _mutateWindowIfAllowed('scroll:$direction:$amount');
  }

  @override
  Future<void> endSession({required String sessionId}) async {
    recordedCalls.add('endSession:$sessionId');
  }

  void _mutateWindowIfAllowed(String actionTag) {
    if (simulateSilentUipiDrop) return;
    _mutationCounter++;
    currentWindow = ActiveWindowObservation(
      appId: currentWindow.appId,
      processName: currentWindow.processName,
      windowTitle: '${currentWindow.windowTitle} [$_mutationCounter]',
      browserUrl: currentWindow.browserUrl,
      isElevated: currentWindow.isElevated,
      pid: currentWindow.pid,
      windowId: currentWindow.windowId,
      nodes: currentWindow.nodes,
      focusedRole: currentWindow.focusedRole,
    );
  }
}

/// Snapshot-indexed element identity recorded during `ui.inspect` so
/// subsequent `input.*` actions can detect `stale_ref` or `ambiguous_target`
/// mutations (`agent-desktop` strict ref resolution).
class SnapshotElementIdentity {
  const SnapshotElementIdentity({
    required this.snapshotId,
    required this.rawId,
    required this.qualifiedRef,
    required this.role,
    required this.name,
    this.nativeId,
    this.bounds,
  });

  final String snapshotId;
  final String rawId;
  final String qualifiedRef;
  final String role;
  final String name;
  final String? nativeId;
  final Map<String, Object?>? bounds;
}

/// Active computer-use session state on the Desktop Agent (`UDC-8` §4.2–§4.3).
class ComputerUseSessionState {
  ComputerUseSessionState({
    required this.sessionId,
    required this.goal,
    required this.allowedApps,
    Set<String>? allowedAppIdentifiers,
    Map<String, String>? bundleIdByIdentifier,
    required this.allowedDomains,
    required this.maxSteps,
    required this.maxMinutes,
    required this.startedAtUtc,
  }) : allowedAppIdentifiers = allowedAppIdentifiers ?? allowedApps,
       bundleIdByIdentifier = bundleIdByIdentifier ?? <String, String>{};

  final String sessionId;
  final String goal;
  final Set<String> allowedApps;
  final Set<String> allowedAppIdentifiers;

  /// For allowed apps whose bundle id is known (a `bundle` policy entry or a
  /// discovered macOS app): each of the app's other identifiers mapped to
  /// that bundle id, lower case (UDC-17 S17.6).
  final Map<String, String> bundleIdByIdentifier;
  final List<String> allowedDomains;
  final int maxSteps;
  final int maxMinutes;
  final DateTime startedAtUtc;

  /// Whether the active window belongs to an app of this session.
  ///
  /// When the window reports a bundle id (macOS gives it as `processName`),
  /// the bundle id decides: it matches an allowed app's bundle id, or the
  /// window matches an allowed app only by name **and** that app's bundle id
  /// is unknown. A window whose display name copies an allowed app but whose
  /// bundle id differs from the known one is refused (UDC-17 S17.6).
  bool isWindowAppAllowed(String appId, String processName) {
    final appLower = appId.trim().toLowerCase();
    final procLower = processName.trim().toLowerCase();
    if (looksLikeBundleId(procLower)) {
      if (allowedAppIdentifiers.contains(procLower)) return true;
      final nameKeys = <String>{appId, appLower}.where(
        (k) => allowedApps.contains(k) || allowedAppIdentifiers.contains(k),
      );
      return nameKeys.isNotEmpty &&
          nameKeys.every((k) => !bundleIdByIdentifier.containsKey(k));
    }
    if (allowedApps.contains(appId)) return true;
    final normProc =
        NativeHostChannelComputerUseProvider.normalizeAppIdFromProcess(
          processName,
        );
    return allowedAppIdentifiers.contains(appLower) ||
        allowedAppIdentifiers.contains(procLower) ||
        allowedAppIdentifiers.contains(normProc);
  }

  int stepsExecuted = 0;

  /// Whether [value] (lower case) is a reverse-DNS bundle id such as
  /// `com.apple.notes`, not an executable or a path.
  static bool looksLikeBundleId(String value) =>
      value.contains('.') &&
      !value.endsWith('.exe') &&
      !value.endsWith('.app') &&
      !value.contains('/') &&
      !value.contains(r'\') &&
      RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$').hasMatch(value);

  /// Characters typed in this session without a per-call signature
  /// (ADR-0015 D1). Consumed only at execution, never by preflight.
  int draftCharsTyped = 0;

  int get draftCharsRemaining => maxCuSessionDraftChars - draftCharsTyped;

  /// Whether unsigned draft text was typed since the last signed click or key
  /// (the last possible commit). While it is, unnamed click targets are R3.
  bool hasUncommittedDraft = false;

  int consecutiveNoChange = 0;
  String? lastActionSignature;
  int snapshotCounter = 0;
  String? latestSnapshotId;
  final Map<String, SnapshotElementIdentity> snapshotRefMaps =
      <String, SnapshotElementIdentity>{};

  /// Element number the next ref added to the latest snapshot gets, so refs
  /// added by `ui.find` or after an action never reuse a number (UDC-17 S17.4).
  int nextElementNumber = 1;

  String mintNextSnapshotId() {
    snapshotCounter++;
    final id = 's${snapshotCounter.toRadixString(16).padLeft(8, '0')}';
    latestSnapshotId = id;
    nextElementNumber = 1;
    return id;
  }

  bool isWallClockExpired(DateTime nowUtc) =>
      nowUtc.difference(startedAtUtc) > Duration(minutes: maxMinutes);
}

/// Manages the lifecycle, hard refusals, step/time budgets, and overlay state
/// of a desktop computer-use session (`UDC-8` S8.2).
class ComputerUseSessionManager {
  ComputerUseSessionManager({
    required this.provider,
    required this.stopController,
    this.appScanner,
  }) {
    stopController.addCancelListener(_onEmergencyStop);
  }

  final ComputerUseProvider provider;
  final EmergencyStopController stopController;
  final AutoAppScanner? appScanner;

  ComputerUseSessionState? _activeSession;
  int _sessionCounter = 0;
  final StreamController<ComputerUseSessionState?> _stateController =
      StreamController<ComputerUseSessionState?>.broadcast();

  ComputerUseSessionState? get activeSession => _activeSession;
  bool get hasActiveSession => _activeSession != null;
  Stream<ComputerUseSessionState?> get sessionChanges =>
      _stateController.stream;

  /// Whether the underlying [provider] supports `screen.capture`.
  bool get supportsScreenCapture {
    final prov = provider;
    if (prov is NativeHostChannelComputerUseProvider) {
      return prov.hasExternalCaptureDriver;
    }
    return true;
  }

  static void _collectAppIdentifiers({
    required Set<String> out,
    required String requestedId,
    required String canonicalId,
    required String displayName,
    required String target,
    String? bundleId,
  }) {
    for (final raw in <String>[
      requestedId,
      canonicalId,
      AutoAppScanner.normalizeId(displayName),
      NativeHostChannelComputerUseProvider.normalizeAppIdFromProcess(target),
      if (bundleId != null && bundleId.trim().isNotEmpty) ...<String>[
        bundleId.trim().toLowerCase(),
        NativeHostChannelComputerUseProvider.normalizeAppIdFromProcess(
          bundleId,
        ),
      ],
    ]) {
      final clean = raw.trim().toLowerCase();
      if (clean.isNotEmpty && clean != 'unknown') {
        out.add(clean);
      }
    }
    final targetLower = target.trim().toLowerCase();
    if (targetLower.contains('.') &&
        !targetLower.contains('/') &&
        !targetLower.contains(r'\') &&
        !targetLower.endsWith('.exe') &&
        !targetLower.endsWith('.app')) {
      out.add(targetLower);
    }
  }

  void _onEmergencyStop(StopReason _) {
    final current = _activeSession;
    if (current != null) {
      unawaited(endSession(sessionId: current.sessionId, outcome: 'stopped'));
    }
  }

  /// Starts a new bounded computer-use session (`cu.session_start`).
  Future<String> startSession({
    required String goal,
    required List<String> apps,
    required List<String> domains,
    required int maxSteps,
    required int maxMinutes,
    required HostPolicy policy,
    AutoAppScanner? appScanner,
    bool allowZeroConfigAppDiscovery = false,
    String? requestedSessionId,
    DateTime? nowUtc,
  }) async {
    if (_activeSession != null) {
      await endSession(
        sessionId: _activeSession!.sessionId,
        outcome: 'stopped',
      );
    }

    final resolved = _resolveSessionApps(
      apps: apps,
      policy: policy,
      scanner: appScanner ?? this.appScanner,
      allowZeroConfig: allowZeroConfigAppDiscovery,
    );
    final allowedAppConfigs = resolved.configs;
    final allowedIdentifiers = resolved.identifiers;

    final normalizedDomains = <String>[
      for (final d in domains) normalizeDomainAllowlistEntry(d),
    ];

    final sessionId = requestedSessionId ?? 'cu-session-${++_sessionCounter}';

    final manifestYaml = CuaDriverMap.buildBoundedCapabilityManifestYaml(
      allowedApps: allowedAppConfigs,
      allowedDomains: normalizedDomains,
      maxMinutes: maxMinutes,
    );

    await provider.startSession(
      sessionId: sessionId,
      capabilityManifestYaml: manifestYaml,
    );

    final state = ComputerUseSessionState(
      sessionId: sessionId,
      goal: goal,
      allowedApps: apps.toSet(),
      allowedAppIdentifiers: allowedIdentifiers,
      bundleIdByIdentifier: resolved.bundleIds,
      allowedDomains: normalizedDomains,
      maxSteps: maxSteps.clamp(1, maxCuSessionSteps),
      maxMinutes: maxMinutes.clamp(1, maxCuSessionMinutes),
      startedAtUtc: (nowUtc ?? DateTime.now()).toUtc(),
    );
    _activeSession = state;
    _stateController.add(state);
    return sessionId;
  }

  /// Adds apps and domains to the running session (`cu.session_extend`,
  /// UDC-17 S17.3) with the same checks as [startSession]. Budgets and the
  /// start time do not change.
  ///
  /// External MCP drivers received their capability manifest at session start,
  /// so they may still refuse a newly added app; that fails closed.
  Future<({List<String> apps, List<String> domains})> extendSession({
    required String sessionId,
    required List<String> apps,
    required List<String> domains,
    required HostPolicy policy,
    AutoAppScanner? appScanner,
    bool allowZeroConfigAppDiscovery = false,
    DateTime? nowUtc,
  }) async {
    final session = _requireActiveSession(nowUtc: nowUtc);
    if (session.sessionId != sessionId) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'cu_session_required',
      );
    }
    final resolved = _resolveSessionApps(
      apps: apps,
      policy: policy,
      scanner: appScanner ?? this.appScanner,
      allowZeroConfig: allowZeroConfigAppDiscovery,
    );
    final newDomains = <String>[
      for (final d in domains) normalizeDomainAllowlistEntry(d),
    ];
    final nextApps = <String>{...session.allowedApps, ...apps};
    final nextDomains = <String>{...session.allowedDomains, ...newDomains};
    if (nextApps.length > maxCuSessionApps ||
        nextDomains.length > maxCuSessionDomains) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'session_scope_limit',
      );
    }
    session.allowedApps.addAll(apps);
    session.allowedAppIdentifiers.addAll(resolved.identifiers);
    session.bundleIdByIdentifier.addAll(resolved.bundleIds);
    for (final d in newDomains) {
      if (!session.allowedDomains.contains(d)) session.allowedDomains.add(d);
    }
    _stateController.add(session);
    return (
      apps: session.allowedApps.toList(growable: false),
      domains: List<String>.unmodifiable(session.allowedDomains),
    );
  }

  /// Resolves requested app ids to allowlisted configs and window identifiers,
  /// refusing denylisted targets and, unless zero-config discovery is allowed,
  /// apps missing from `host-policy.json`. Shared by start and extend.
  ({
    List<AllowedAppConfig> configs,
    Set<String> identifiers,
    Map<String, String> bundleIds,
  })
  _resolveSessionApps({
    required List<String> apps,
    required HostPolicy policy,
    required AutoAppScanner? scanner,
    required bool allowZeroConfig,
  }) {
    final effectiveScanner = scanner;
    final allowedAppConfigs = <AllowedAppConfig>[];
    final allowedIdentifiers = <String>{};
    final bundleIds = <String, String>{};

    void addApp({
      required String requestedId,
      required String canonicalId,
      required String displayName,
      required String target,
      String? bundleId,
    }) {
      final appIdentifiers = <String>{};
      _collectAppIdentifiers(
        out: appIdentifiers,
        requestedId: requestedId,
        canonicalId: canonicalId,
        displayName: displayName,
        target: target,
        bundleId: bundleId,
      );
      allowedIdentifiers.addAll(appIdentifiers);
      final bundle = bundleId?.trim().toLowerCase();
      if (bundle != null && ComputerUseSessionState.looksLikeBundleId(bundle)) {
        for (final id in appIdentifiers) {
          if (id != bundle) bundleIds[id] = bundle;
        }
      }
    }

    for (final appId in apps) {
      if (isHardDeniedAppOrProcess(appId)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'denylisted_target_forbidden',
        );
      }
      final cfg = policy.findApp(appId);
      if (cfg != null) {
        if (isHardDeniedAppOrProcess(cfg.target) ||
            isHardDeniedAppOrProcess(cfg.name)) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'denylisted_target_forbidden',
          );
        }
        final discoveredMatch = effectiveScanner?.findApp(appId);
        allowedAppConfigs.add(cfg);
        addApp(
          requestedId: appId,
          canonicalId: cfg.id,
          displayName: cfg.name,
          target: cfg.target,
          bundleId:
              discoveredMatch?.bundleId ??
              (cfg.kind == AppLaunchKind.bundle ? cfg.target : null),
        );
        continue;
      }

      final discovered = allowZeroConfig
          ? effectiveScanner?.findApp(appId)
          : null;
      if (discovered == null) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'policy_blocked',
        );
      }
      if (isHardDeniedAppOrProcess(discovered.id) ||
          isHardDeniedAppOrProcess(discovered.name) ||
          isHardDeniedAppOrProcess(discovered.target) ||
          (discovered.bundleId != null &&
              isHardDeniedAppOrProcess(discovered.bundleId!))) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'denylisted_target_forbidden',
        );
      }
      allowedAppConfigs.add(
        AllowedAppConfig(
          id: discovered.id,
          name: discovered.name,
          kind: discovered.kind,
          target: discovered.bundleId ?? discovered.target,
          risk: RiskTier.r2,
        ),
      );
      addApp(
        requestedId: appId,
        canonicalId: discovered.id,
        displayName: discovered.name,
        target: discovered.target,
        bundleId: discovered.bundleId,
      );
    }

    return (
      configs: allowedAppConfigs,
      identifiers: allowedIdentifiers,
      bundleIds: bundleIds,
    );
  }

  /// Ends the active computer-use session (`cu.session_end`).
  Future<void> endSession({
    required String sessionId,
    required String outcome,
  }) async {
    final current = _activeSession;
    _activeSession = null;
    _stateController.add(null);
    if (current != null) {
      await provider.endSession(sessionId: current.sessionId);
    }
  }

  /// Inspects the active window after enforcing all hard refusals (`ui.inspect`).
  ///
  /// Supports `agent-desktop` progressive observation options:
  /// - [skeleton]: shallow container overview (`depth <= 2`) with `childrenCount`
  /// - [interactiveOnly]: only interactive controls and overlay surfaces
  /// - [rootElementId]: drill down into a specific container subtree
  /// - [collapseWebWrappers]: skip unnamed, non-actionable `group`/`custom`/`pane` wrappers
  Future<Map<String, Object?>> inspectWindow({
    required int maxNodes,
    bool skeleton = false,
    bool interactiveOnly = false,
    String? rootElementId,
    bool collapseWebWrappers = false,
    DateTime? nowUtc,
  }) async {
    final session = _requireActiveSession(nowUtc: nowUtc);
    final window = await provider.inspectActiveWindow(maxNodes: maxNodes);
    _enforceWindowHardRefusals(session: session, window: window);
    final snapshotId = session.mintNextSnapshotId();
    final collapsedWrappersCount = collapseWebWrappers
        ? window.nodes.where(isTransparentWebWrapperNode).length
        : 0;
    final surfaces = extractOverlaySurfaces(window.nodes);
    final redactedNodes = redactUiTreeNodes(
      window.nodes,
      maxNodes: maxNodes.clamp(1, 300),
      snapshotId: snapshotId,
      collapseWebWrappers: collapseWebWrappers,
      skeleton: skeleton,
      interactiveOnly: interactiveOnly,
      rootElementId: rootElementId,
    );

    for (final node in redactedNodes) {
      _registerSnapshotNode(session, node, snapshotId);
    }

    return <String, Object?>{
      'appId': window.appId,
      'windowTitle': window.windowTitle.length > 120
          ? window.windowTitle.substring(0, 120)
          : window.windowTitle,
      'snapshotId': snapshotId,
      'surfaces': surfaces,
      'collapsedWrappersCount': collapsedWrappersCount,
      'nodes': redactedNodes,
    };
  }

  /// Records the identity behind a redacted, ref-tagged [node] so `input.*`
  /// can resolve its ref and detect `stale_ref` / `ambiguous_target`.
  void _registerSnapshotNode(
    ComputerUseSessionState session,
    Map<String, Object?> node,
    String snapshotId,
  ) {
    final rawId = (node['id'] as String?) ?? '';
    final qualRef = (node['ref'] as String?) ?? rawId;
    final identity = SnapshotElementIdentity(
      snapshotId: snapshotId,
      rawId: rawId,
      qualifiedRef: qualRef,
      role: (node['role'] as String?) ?? 'unknown',
      name: (node['name'] as String?) ?? '',
      nativeId: node['nativeId'] as String?,
      bounds: (node['bounds'] as Map?)?.cast<String, Object?>(),
    );
    if (rawId.isNotEmpty) {
      session.snapshotRefMaps[rawId] = identity;
    }
    if (qualRef.isNotEmpty) {
      session.snapshotRefMaps[qualRef] = identity;
      if (qualRef.startsWith('@')) {
        session.snapshotRefMaps[qualRef.substring(1)] = identity;
      }
    }
    final parsed = parseSnapshotElementRef(qualRef);
    if (parsed != null &&
        parsed.snapshotId == snapshotId &&
        parsed.elementNumber >= session.nextElementNumber) {
      session.nextElementNumber = parsed.elementNumber + 1;
    }
  }

  /// Redacts [rawNode] like `ui.inspect` and gives it a ref in the latest
  /// snapshot: the ref it already has when the same element (same raw id,
  /// role and name) is registered there, otherwise the next free number.
  Map<String, Object?> _redactAndRegisterInLatestSnapshot(
    ComputerUseSessionState session,
    Map<String, Object?> rawNode,
  ) {
    final snapshotId = session.latestSnapshotId!;
    final redacted = redactUiTreeNodes(<Map<String, Object?>>[
      rawNode,
    ], maxNodes: 1).single;
    final rawId = (redacted['id'] as String?) ?? '';
    final known = rawId.isEmpty ? null : session.snapshotRefMaps[rawId];
    if (known != null &&
        known.snapshotId == snapshotId &&
        known.rawId == rawId &&
        _identitySignature(known) == uiNodeSignature(rawNode)) {
      redacted['ref'] = known.qualifiedRef;
      return redacted;
    }
    redacted['ref'] = '@$snapshotId:e${session.nextElementNumber}';
    final nativeId = rawNode['nativeId'];
    _registerSnapshotNode(session, <String, Object?>{
      ...redacted,
      if (nativeId is String) 'nativeId': nativeId,
    }, snapshotId);
    return redacted;
  }

  /// Same key as [uiNodeSignature], from a recorded identity (whose role and
  /// name were stored already redacted).
  static String _identitySignature(SnapshotElementIdentity identity) =>
      '${identity.role.trim().toLowerCase()}\u0000${identity.name}';

  /// Finds elements of the active window by name and/or role (`ui.find`,
  /// UDC-17 S17.4) after the same hard refusals as [inspectWindow].
  ///
  /// Read-only on the screen. Candidates join the latest snapshot (one is
  /// minted when the session has none), so refs from an earlier `ui.inspect`
  /// stay valid. Every ref is still re-checked against the live element when
  /// an `input.*` call uses it.
  Future<Map<String, Object?>> findElements({
    String? query,
    String? role,
    int maxResults = defaultUiFindResults,
    DateTime? nowUtc,
  }) async {
    final session = _requireActiveSession(nowUtc: nowUtc);
    final window = await provider.inspectActiveWindow(maxNodes: 300);
    _enforceWindowHardRefusals(session: session, window: window);
    final found = findUiNodes(
      window.nodes,
      query: query,
      role: role,
      maxResults: maxResults,
    );
    final snapshotId = session.latestSnapshotId ?? session.mintNextSnapshotId();
    final matches = <Map<String, Object?>>[
      for (final node in found.matches)
        _redactAndRegisterInLatestSnapshot(session, node),
    ];
    return <String, Object?>{
      'appId': window.appId,
      'windowTitle': window.windowTitle.length > 120
          ? window.windowTitle.substring(0, 120)
          : window.windowTitle,
      'snapshotId': snapshotId,
      'searchedNodes': window.nodes.length,
      'total': found.total,
      'truncated': found.total > matches.length,
      'matches': matches,
    };
  }

  /// Most entries per list in an action's `changes`.
  static const int maxChangeEntries = 15;

  /// Brings the latest snapshot up to date after an `input.*` action and
  /// describes what changed (UDC-17 S17.4), or returns `null` when no
  /// snapshot was taken yet.
  ///
  /// A registered element keeps its ref only when it is provably the same
  /// element in [after]:
  /// 1. the same `nativeId`, unique in [before] and [after]; or
  /// 2. a non-empty name whose role+name is unique both [before] and [after]
  ///    (the raw id is re-bound if native ordinals shifted); or
  /// 3. the same raw id at the same position, when the window's structure
  ///    did not change at all (every node's raw id, role and name equal, in
  ///    order, e.g. after typing a draft or a button turning enabled).
  /// Anything else is dropped (`removed`), so its ref fails with `stale_ref`
  /// instead of reaching another element. Unnamed or duplicated controls are
  /// therefore dropped whenever the structure changed: an identical-looking
  /// control inserted before them cannot be told apart without a native id.
  /// Controls that appeared, or that replace dropped ones, get new refs
  /// (`added`).
  ///
  /// When [after] fails the window hard refusals (another app came to the
  /// front), no element of it is described.
  Map<String, Object?>? _reconcileSnapshotAfterAction({
    required ComputerUseSessionState session,
    required ActiveWindowObservation before,
    required ActiveWindowObservation after,
    required bool afterWindowAllowed,
  }) {
    final snapshotId = session.latestSnapshotId;
    if (snapshotId == null) return null;
    if (!afterWindowAllowed) {
      return <String, Object?>{
        'snapshotId': snapshotId,
        'windowOutsideSession': true,
      };
    }

    final beforeSigs = <String>[
      for (final n in before.nodes) uiNodeSignature(n),
    ];
    final afterSigs = <String>[for (final n in after.nodes) uiNodeSignature(n)];
    Map<String, int> countOf(List<String> sigs) {
      final counts = <String, int>{};
      for (final sig in sigs) {
        counts[sig] = (counts[sig] ?? 0) + 1;
      }
      return counts;
    }

    final beforeCounts = countOf(beforeSigs);
    final afterCounts = countOf(afterSigs);
    var structureUnchanged = beforeSigs.length == afterSigs.length;
    for (var i = 0; structureUnchanged && i < beforeSigs.length; i++) {
      structureUnchanged =
          beforeSigs[i] == afterSigs[i] &&
          before.nodes[i]['id'] == after.nodes[i]['id'];
    }

    int? uniqueIndexWhere(
      List<Map<String, Object?>> nodes,
      bool Function(Map<String, Object?>) test,
    ) {
      int? found;
      for (var i = 0; i < nodes.length; i++) {
        if (!test(nodes[i])) continue;
        if (found != null) return null;
        found = i;
      }
      return found;
    }

    final current = <SnapshotElementIdentity>{
      for (final identity in session.snapshotRefMaps.values)
        if (identity.snapshotId == snapshotId) identity,
    };
    final carriedAfter = <int>{};
    final droppedSigs = <String>{};
    final removed = <String>[];
    final changed = <Map<String, Object?>>[];

    for (final identity in current) {
      final sig = _identitySignature(identity);
      int? beforeIdx;
      int? afterIdx;
      final nativeId = identity.nativeId;
      if (nativeId != null && nativeId.isNotEmpty) {
        beforeIdx = uniqueIndexWhere(
          before.nodes,
          (n) => n['nativeId'] == nativeId,
        );
        afterIdx = uniqueIndexWhere(
          after.nodes,
          (n) => n['nativeId'] == nativeId,
        );
      } else if (identity.name.isNotEmpty &&
          beforeCounts[sig] == 1 &&
          afterCounts[sig] == 1) {
        beforeIdx = beforeSigs.indexOf(sig);
        afterIdx = afterSigs.indexOf(sig);
      } else if (identity.rawId.isNotEmpty) {
        final idx = uniqueIndexWhere(
          before.nodes,
          (n) => n['id'] == identity.rawId,
        );
        if (idx != null && structureUnchanged && beforeSigs[idx] == sig) {
          beforeIdx = idx;
          afterIdx = idx;
        }
      }
      if (afterIdx == null ||
          afterSigs[afterIdx] != sig ||
          carriedAfter.contains(afterIdx)) {
        _dropIdentity(session, identity);
        droppedSigs.add(sig);
        removed.add(identity.qualifiedRef);
        continue;
      }
      carriedAfter.add(afterIdx);
      final live = after.nodes[afterIdx];
      final liveId = (live['id'] as String?) ?? '';
      if (liveId != identity.rawId) {
        // Native ordinals shifted: the ref now points at the element's new id.
        _dropIdentity(session, identity);
        _registerSnapshotNode(session, <String, Object?>{
          'id': liveId,
          'ref': identity.qualifiedRef,
          'role': identity.role,
          'name': identity.name,
          if (live['nativeId'] is String) 'nativeId': live['nativeId'],
          if (live['bounds'] is Map) 'bounds': live['bounds'],
        }, snapshotId);
      }
      if (beforeIdx != null) {
        final prev = before.nodes[beforeIdx];
        final enabledNow = live['enabled'] != false;
        final visibleNow = live['visible'] != false;
        if ((prev['enabled'] != false) != enabledNow ||
            (prev['visible'] != false) != visibleNow) {
          changed.add(<String, Object?>{
            'ref': identity.qualifiedRef,
            'enabled': enabledNow,
            'visible': visibleNow,
          });
        }
      }
    }

    final addedCandidates = <Map<String, Object?>>[];
    for (var i = 0; i < after.nodes.length; i++) {
      if (carriedAfter.contains(i)) continue;
      final node = after.nodes[i];
      if (!isInteractiveUiNode(node) && !isOverlaySurfaceNode(node)) continue;
      final sig = afterSigs[i];
      final grew = (afterCounts[sig] ?? 0) > (beforeCounts[sig] ?? 0);
      if (!grew && !droppedSigs.contains(sig)) continue;
      addedCandidates.add(node);
    }
    final added = <Map<String, Object?>>[
      for (final node in addedCandidates.take(maxChangeEntries))
        _slimChangeNode(_redactAndRegisterInLatestSnapshot(session, node)),
    ];
    return <String, Object?>{
      'snapshotId': snapshotId,
      'added': added,
      'removed': removed.take(maxChangeEntries).toList(),
      'changed': changed.take(maxChangeEntries).toList(),
      'truncated':
          addedCandidates.length > maxChangeEntries ||
          removed.length > maxChangeEntries ||
          changed.length > maxChangeEntries,
    };
  }

  /// Fields of a redacted node kept in `changes.added`. Layout fields
  /// (`bounds`, `depth`, `parentId`…) are left out so a full `changes` stays
  /// well inside the backend's tool-output byte limit; `ui.inspect` still
  /// returns them.
  static const List<String> _changeNodeKeys = <String>[
    'ref',
    'id',
    'role',
    'name',
    'enabled',
    'visible',
    'editable',
    'isPassword',
    'modal',
  ];

  static Map<String, Object?> _slimChangeNode(Map<String, Object?> node) =>
      <String, Object?>{
        for (final key in _changeNodeKeys)
          if (node.containsKey(key)) key: node[key],
      };

  /// Removes every key of `snapshotRefMaps` that points at [identity], so its
  /// ref resolves to `stale_ref`.
  void _dropIdentity(
    ComputerUseSessionState session,
    SnapshotElementIdentity identity,
  ) {
    session.snapshotRefMaps.removeWhere((_, v) => identical(v, identity));
  }

  /// Captures the active window or screen JPEG after enforcing hard refusals
  /// (`screen.capture`).
  Future<Map<String, Object?>> captureScreen({
    required String scope,
    required int maxEdge,
    DateTime? nowUtc,
  }) async {
    final session = _requireActiveSession(nowUtc: nowUtc);
    final window = await provider.inspectActiveWindow(maxNodes: 50);
    _enforceWindowHardRefusals(session: session, window: window);
    final capture = await provider.captureScreen(
      scope: scope,
      maxEdge: maxEdge.clamp(320, 1280),
    );
    return <String, Object?>{
      'mimeType': capture.mimeType,
      'width': capture.width,
      'height': capture.height,
      'dataBase64': capture.dataBase64,
    };
  }

  /// Executes an `input.*` action (`input.click`, `input.type_text`,
  /// `input.key`, `input.scroll`) with pre-action hard refusals, budget checks,
  /// strict `@s<id>:e<N>` ref resolution, actionability battery, duplicate-action
  /// detection, post-action UI effect verification, and optional `waitFor`/`waitForGone`.
  Future<Map<String, Object?>> executeInputAction({
    required String toolName,
    required Map<String, Object?> arguments,
    required bool hasR3Approval,
    DateTime? nowUtc,
  }) async {
    final session = _requireActiveSession(nowUtc: nowUtc);
    if (session.stepsExecuted >= session.maxSteps) {
      await endSession(
        sessionId: session.sessionId,
        outcome: 'budget_exceeded',
      );
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'step_budget_exceeded',
      );
    }

    final beforeWindow = await provider.inspectActiveWindow(maxNodes: 300);
    _enforceWindowHardRefusals(session: session, window: beforeWindow);

    final rawElementId = arguments['elementId'] as String?;
    final resolvedTarget = _resolveAndValidateTargetElement(
      session: session,
      window: beforeWindow,
      toolName: toolName,
      rawElementId: rawElementId,
    );
    final targetNode = resolvedTarget.targetNode;
    final effectiveElementId = resolvedTarget.effectiveElementId;

    if (targetNode != null && isPasswordUiNode(targetNode)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'password_field_forbidden',
      );
    }
    // The model's declared name counts only when it types: a click on
    // "Quên mật khẩu" is not typing into a password field (UDC-17 S17.6).
    final explicitElementName = arguments['elementName'] as String?;
    if (toolName != 'input.click' &&
        explicitElementName != null &&
        isPasswordUiNode(<String, Object?>{'name': explicitElementName})) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'password_field_forbidden',
      );
    }

    // The same classifier answers `xuna/preflight`, so the risk the owner was
    // asked to approve is the risk enforced here (UDC-17 S17.1). It reads the
    // live node, so a disguised or missing `elementName` cannot lower it.
    final stepRisk = classifyInputStepRisk(
      toolName: toolName,
      arguments: arguments,
      liveTarget: targetNode,
      focusedRole: beforeWindow.focusedRole,
      draftCharsRemaining: session.draftCharsRemaining,
      hasUncommittedDraft: session.hasUncommittedDraft,
    );
    if (stepRisk.risk >= RiskTier.r3 && !hasR3Approval) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'approval_required',
      );
    }
    if (toolName == 'input.type_text' && !hasR3Approval) {
      // An unsigned draft (ADR-0015 D1) spends the session's draft budget
      // before anything is typed.
      session.draftCharsTyped += (arguments['text'] as String).length;
      session.hasUncommittedDraft = true;
    } else if (hasR3Approval &&
        (toolName == 'input.click' || toolName == 'input.key')) {
      // The owner signed a possible commit; drafts before it are settled.
      session.hasUncommittedDraft = false;
    }

    // Pre-dispatch Actionability Battery (`agent-desktop` actionability checks).
    if (targetNode != null) {
      _enforceActionabilityBattery(
        toolName: toolName,
        targetNode: targetNode,
        allNodes: beforeWindow.nodes,
      );
    }

    // Duplicate-action detection (`UDC-8` §4.3): the same action on the same
    // element right after it changed nothing on screen stops the session. A
    // repeat after a visible change (next page, a "+" stepper) is progress:
    // refs survive actions now (UDC-17 S17.4), so it has the same arguments.
    final actionSignature = '$toolName:${argsSha256(arguments)}';
    if (session.lastActionSignature == actionSignature) {
      await endSession(sessionId: session.sessionId, outcome: 'stopped');
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'duplicate_action',
      );
    }
    session.lastActionSignature = actionSignature;

    final beforeDigest = beforeWindow.stateDigest();
    session.stepsExecuted++;
    _stateController.add(session);

    final headed = arguments['headed'] == true;
    final hasElementTarget =
        effectiveElementId != null && effectiveElementId.isNotEmpty;
    final route =
        (!headed &&
            (toolName == 'input.type_text' ||
                (toolName == 'input.click' && hasElementTarget) ||
                (toolName == 'input.scroll' && hasElementTarget)))
        ? 'semantic_headless'
        : 'physical_headed';

    switch (toolName) {
      case 'input.click':
        await provider.performClick(
          window: beforeWindow,
          elementId: effectiveElementId,
          x: arguments['x'] as int?,
          y: arguments['y'] as int?,
        );
      case 'input.type_text':
        final prov = provider;
        if (prov is AgentDesktopComputerUseProvider) {
          await prov.performTypeText(
            window: beforeWindow,
            elementId: effectiveElementId!,
            text: arguments['text'] as String,
            headed: headed,
          );
        } else {
          await prov.performTypeText(
            window: beforeWindow,
            elementId: effectiveElementId!,
            text: arguments['text'] as String,
          );
        }
      case 'input.key':
        await provider.performKey(
          window: beforeWindow,
          combo: arguments['combo'] as String,
        );
      case 'input.scroll':
        await provider.performScroll(
          window: beforeWindow,
          elementId: effectiveElementId,
          direction: arguments['direction'] as String,
          amount: arguments['amount'] as int,
        );
      default:
        throw const XunaHostChannelException(
          status: XtpStatus.unsupported,
          errorCode: 'platform_unsupported',
        );
    }

    // Optional bounded post-action wait (`waitFor` / `waitForGone`).
    final waitFor = arguments['waitFor'] as String?;
    final waitForGone = arguments['waitForGone'] as String?;
    bool? waitSatisfied;
    ActiveWindowObservation afterWindow;
    if ((waitFor != null && waitFor.trim().isNotEmpty) ||
        (waitForGone != null && waitForGone.trim().isNotEmpty)) {
      final waitOutcome = await _pollPostActionWaitCondition(
        waitFor: waitFor?.trim(),
        waitForGone: waitForGone?.trim(),
      );
      afterWindow = waitOutcome.window;
      waitSatisfied = waitOutcome.satisfied;
      if (!waitOutcome.satisfied) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'wait_timeout',
        );
      }
    } else {
      afterWindow = await provider.inspectActiveWindow(maxNodes: 300);
    }

    final changed = afterWindow.stateDigest() != beforeDigest;
    if (changed) {
      session.consecutiveNoChange = 0;
      session.lastActionSignature = null;
    } else {
      session.consecutiveNoChange++;
      if (session.consecutiveNoChange >= 3) {
        await endSession(sessionId: session.sessionId, outcome: 'stopped');
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'no_progress',
        );
      }
    }

    final disposition = <String, Object?>{
      'delivery': changed ? 'delivered_verified' : 'delivered_unverified',
      'retry': 'unsafe',
    };
    var afterWindowAllowed = true;
    try {
      _enforceWindowHardRefusals(session: session, window: afterWindow);
    } on XunaHostChannelException {
      afterWindowAllowed = false;
    }
    // Nothing from a window outside the session reaches the model.
    final openSurfaces = afterWindowAllowed
        ? extractOverlaySurfaces(afterWindow.nodes)
        : const <Map<String, Object?>>[];
    final changes = _reconcileSnapshotAfterAction(
      session: session,
      before: beforeWindow,
      after: afterWindow,
      afterWindowAllowed: afterWindowAllowed,
    );

    return <String, Object?>{
      'effect': changed ? 'changed' : 'no_change',
      'route': route,
      'disposition': disposition,
      if (session.latestSnapshotId != null)
        'snapshotId': session.latestSnapshotId,
      if (openSurfaces.isNotEmpty) 'surfaces': openSurfaces,
      if (waitSatisfied != null) 'waitSatisfied': waitSatisfied,
      if (changes != null) 'changes': changes,
    };
  }

  /// Answers `xuna/preflight` for an `input.*` step (UDC-17 S17.1): which risk
  /// the host would enforce and which live element the step would hit.
  ///
  /// Strictly read-only. It does not mint a snapshot, count a step, record the
  /// action signature or end the session, so the real call that follows sees
  /// the same state. Every refusal [executeInputAction] would raise before
  /// acting (no session, budget, window refusals, stale or ambiguous ref,
  /// password field) is thrown here as the same [XunaHostChannelException].
  Future<({InputStepRisk stepRisk, String? elementRole, String? elementName})>
  preflightInputAction({
    required String toolName,
    required Map<String, Object?> arguments,
    DateTime? nowUtc,
  }) async {
    final session = _activeSession;
    if (session == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'cu_session_required',
      );
    }
    if (session.isWallClockExpired((nowUtc ?? DateTime.now()).toUtc())) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'time_budget_exceeded',
      );
    }
    if (session.stepsExecuted >= session.maxSteps) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'step_budget_exceeded',
      );
    }

    final window = await provider.inspectActiveWindow(maxNodes: 300);
    _enforceWindowHardRefusals(session: session, window: window);
    final resolved = _resolveAndValidateTargetElement(
      session: session,
      window: window,
      toolName: toolName,
      rawElementId: arguments['elementId'] as String?,
    );
    final targetNode = resolved.targetNode;
    final declaredName = arguments['elementName'];
    if ((targetNode != null && isPasswordUiNode(targetNode)) ||
        (toolName != 'input.click' &&
            declaredName is String &&
            isPasswordUiNode(<String, Object?>{'name': declaredName}))) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'password_field_forbidden',
      );
    }
    final stepRisk = classifyInputStepRisk(
      toolName: toolName,
      arguments: arguments,
      liveTarget: targetNode,
      focusedRole: window.focusedRole,
      draftCharsRemaining: session.draftCharsRemaining,
      hasUncommittedDraft: session.hasUncommittedDraft,
    );
    final rawName = targetNode?['name'];
    final label = rawName is String ? sanitizePreflightLabel(rawName) : '';
    return (
      stepRisk: stepRisk,
      elementRole: targetNode == null
          ? null
          : sanitizePreflightRole(targetNode['role'] as String?),
      elementName: label.isEmpty ? null : label,
    );
  }

  /// Resolves [rawElementId] against `beforeWindow.nodes` and `session.snapshotRefMaps`,
  /// enforcing `stale_ref` and `ambiguous_target` (`agent-desktop` strict ref
  /// resolution).
  ({Map<String, Object?>? targetNode, String? effectiveElementId})
  _resolveAndValidateTargetElement({
    required ComputerUseSessionState session,
    required ActiveWindowObservation window,
    required String toolName,
    required String? rawElementId,
  }) {
    if (rawElementId == null || rawElementId.trim().isEmpty) {
      return (targetNode: null, effectiveElementId: rawElementId);
    }
    final trimmed = rawElementId.trim();
    final recorded =
        session.snapshotRefMaps[trimmed] ??
        (trimmed.startsWith('@')
            ? session.snapshotRefMaps[trimmed.substring(1)]
            : session.snapshotRefMaps['@$trimmed']);
    final parsedRef = parseSnapshotElementRef(trimmed);
    final isExplicitAtRef = trimmed.startsWith('@');
    if (isExplicitAtRef &&
        parsedRef != null &&
        session.latestSnapshotId != null &&
        parsedRef.snapshotId != session.latestSnapshotId) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'stale_ref',
      );
    }

    // Find nodes matching by explicit ID or ref in the live window.
    final idMatches = <Map<String, Object?>>[];
    for (final node in window.nodes) {
      final nodeId = (node['id'] as String?) ?? '';
      final nodeRef = (node['ref'] as String?) ?? '';
      if (nodeId == trimmed ||
          nodeRef == trimmed ||
          (trimmed.startsWith('@') && nodeId == trimmed.substring(1)) ||
          (recorded != null &&
              recorded.rawId.isNotEmpty &&
              nodeId == recorded.rawId)) {
        idMatches.add(node);
      }
    }

    if (idMatches.length > 1) {
      if (recorded?.nativeId != null) {
        final nativeMatches = idMatches
            .where((n) => n['nativeId'] == recorded!.nativeId)
            .toList();
        if (nativeMatches.length == 1) {
          final matched = nativeMatches.first;
          return (
            targetNode: matched,
            effectiveElementId: (matched['id'] as String?) ?? trimmed,
          );
        }
      }
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'ambiguous_target',
      );
    }

    if (idMatches.length == 1) {
      final matched = idMatches.first;
      if (recorded != null && !isPasswordUiNode(matched)) {
        final liveRole = (matched['role'] as String?) ?? 'unknown';
        final liveName = (matched['name'] as String?) ?? '';
        final roleChanged =
            recorded.role.toLowerCase() != liveRole.toLowerCase();
        final nameChanged =
            recorded.name.isNotEmpty &&
            liveName.isNotEmpty &&
            recorded.name != liveName;
        if (roleChanged || nameChanged) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'stale_ref',
          );
        }
        if (isExplicitAtRef && recorded.name.isNotEmpty) {
          final semanticDuplicates = window.nodes.where((n) {
            final r = (n['role'] as String?) ?? '';
            final nm = (n['name'] as String?) ?? '';
            return r.toLowerCase() == recorded.role.toLowerCase() &&
                nm == recorded.name;
          }).toList();
          if (semanticDuplicates.length > 1 && matched['nativeId'] == null) {
            throw const XunaHostChannelException(
              status: XtpStatus.failed,
              errorCode: 'ambiguous_target',
            );
          }
        }
      }
      return (
        targetNode: matched,
        effectiveElementId: (matched['id'] as String?) ?? trimmed,
      );
    }

    if (recorded != null) {
      final semanticMatches = window.nodes.where((n) {
        final r = isPasswordUiNode(n)
            ? 'password'
            : ((n['role'] as String?) ?? 'unknown');
        final nm = (n['name'] as String?) ?? '';
        return r.toLowerCase() == recorded.role.toLowerCase() &&
            nm == recorded.name &&
            recorded.name.isNotEmpty;
      }).toList();
      if (semanticMatches.length > 1) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'ambiguous_target',
        );
      }
      if (semanticMatches.length == 1) {
        if (session.latestSnapshotId != null &&
            recorded.snapshotId != session.latestSnapshotId) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'stale_ref',
          );
        }
        final matched = semanticMatches.first;
        return (
          targetNode: matched,
          effectiveElementId: (matched['id'] as String?) ?? trimmed,
        );
      }
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'stale_ref',
      );
    }

    if (isExplicitAtRef ||
        (parsedRef != null && session.snapshotRefMaps.isNotEmpty)) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'stale_ref',
      );
    }

    return (targetNode: null, effectiveElementId: trimmed);
  }

  /// Enforces pre-dispatch actionability checks on [targetNode] before sending
  /// any input (`element_not_visible`, `element_not_enabled`,
  /// `element_occluded`, `element_not_editable`).
  void _enforceActionabilityBattery({
    required String toolName,
    required Map<String, Object?> targetNode,
    required List<Map<String, Object?>> allNodes,
  }) {
    if (targetNode['visible'] == false || targetNode['offscreen'] == true) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'element_not_visible',
      );
    }
    final bounds = targetNode['bounds'];
    if (bounds is Map) {
      final w = bounds['w'] ?? bounds['width'];
      final h = bounds['h'] ?? bounds['height'];
      if ((w is num && w <= 0) || (h is num && h <= 0)) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'element_not_visible',
        );
      }
    }
    if (targetNode['enabled'] == false) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'element_not_enabled',
      );
    }
    if (targetNode['occluded'] == true) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'element_occluded',
      );
    }
    if (!isOverlaySurfaceNode(targetNode)) {
      final modalNodes = allNodes
          .where((n) => isOverlaySurfaceNode(n) && n['modal'] != false)
          .toList();
      if (modalNodes.isNotEmpty) {
        final targetSurfaceId =
            (targetNode['parentSurfaceId'] as String?) ??
            (targetNode['parentId'] as String?) ??
            '';
        final modalIds = modalNodes
            .map((m) => (m['id'] as String?) ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
        if (modalIds.isNotEmpty &&
            targetNode['insideModal'] != true &&
            !modalIds.contains(targetSurfaceId)) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'element_occluded',
          );
        }
      }
    }
    if (toolName == 'input.type_text') {
      if (targetNode['editable'] == false || targetNode['readOnly'] == true) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'element_not_editable',
        );
      }
    }
  }

  /// Polls `provider.inspectActiveWindow` up to 4 times to verify post-action
  /// [waitFor] or [waitForGone] conditions (`role:<r>`, `name:<n>`,
  /// `window:<title>`, `surface:<kind>`, or text substring).
  Future<({ActiveWindowObservation window, bool satisfied})>
  _pollPostActionWaitCondition({String? waitFor, String? waitForGone}) async {
    const maxAttempts = 4;
    late ActiveWindowObservation latestWindow;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      latestWindow = await provider.inspectActiveWindow(maxNodes: 300);
      if (waitFor != null && waitFor.isNotEmpty) {
        if (_matchesWaitSelector(latestWindow, waitFor)) {
          return (window: latestWindow, satisfied: true);
        }
      } else if (waitForGone != null && waitForGone.isNotEmpty) {
        if (!_matchesWaitSelector(latestWindow, waitForGone)) {
          return (window: latestWindow, satisfied: true);
        }
      }
    }
    return (window: latestWindow, satisfied: false);
  }

  bool _matchesWaitSelector(ActiveWindowObservation window, String selector) {
    final trimmed = selector.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('window:')) {
      final needle = lower.substring('window:'.length).trim();
      return window.windowTitle.toLowerCase().contains(needle);
    }
    if (lower.startsWith('surface:')) {
      final needle = lower.substring('surface:'.length).trim();
      final surfaces = extractOverlaySurfaces(window.nodes);
      return surfaces.any(
        (s) =>
            '${s['kind']}'.toLowerCase().contains(needle) ||
            '${s['title']}'.toLowerCase().contains(needle),
      );
    }
    if (lower.startsWith('role:')) {
      final needle = lower.substring('role:'.length).trim();
      return window.nodes.any(
        (n) => ((n['role'] as String?) ?? '').toLowerCase() == needle,
      );
    }
    if (lower.startsWith('name:')) {
      final needle = lower.substring('name:'.length).trim();
      return window.nodes.any(
        (n) => ((n['name'] as String?) ?? '').toLowerCase().contains(needle),
      );
    }
    if (window.windowTitle.toLowerCase().contains(lower)) {
      return true;
    }
    for (final node in window.nodes) {
      final id = ((node['id'] as String?) ?? '').toLowerCase();
      final ref = ((node['ref'] as String?) ?? '').toLowerCase();
      final name = ((node['name'] as String?) ?? '').toLowerCase();
      final val = ((node['value'] as String?) ?? '').toLowerCase();
      if (id == lower ||
          ref == lower ||
          name.contains(lower) ||
          val.contains(lower)) {
        return true;
      }
    }
    return false;
  }

  ComputerUseSessionState _requireActiveSession({DateTime? nowUtc}) {
    final session = _activeSession;
    if (session == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'cu_session_required',
      );
    }
    final now = (nowUtc ?? DateTime.now()).toUtc();
    if (session.isWallClockExpired(now)) {
      unawaited(
        endSession(sessionId: session.sessionId, outcome: 'budget_exceeded'),
      );
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'time_budget_exceeded',
      );
    }
    return session;
  }

  /// Hard refusals executed by XUNA before any observation or input reaches the
  /// provider (`UDC-8` §4.2):
  /// 1. Denylisted terminals, password managers, banking apps, system settings.
  /// 2. Elevated windows (UIPI boundary).
  /// 3. Active window's appId not in the session's `allowedApps`.
  /// 4. Browser window's URL domain not in the session's `allowedDomains`.
  void _enforceWindowHardRefusals({
    required ComputerUseSessionState session,
    required ActiveWindowObservation window,
  }) {
    if (isHardDeniedAppOrProcess(window.appId) ||
        isHardDeniedAppOrProcess(window.processName)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'denylisted_target_forbidden',
      );
    }
    if (window.isElevated) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'elevated_window_forbidden',
      );
    }
    if (!session.isWindowAppAllowed(window.appId, window.processName)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'target_outside_allowlist',
      );
    }
    if (window.browserUrl != null && window.browserUrl!.isNotEmpty) {
      final urlCheck = validateHttpsUrlAgainstAllowlist(
        window.browserUrl!,
        session.allowedDomains,
      );
      if (!urlCheck.validUrl || !urlCheck.domainAllowed) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'domain_outside_allowlist',
        );
      }
    }
  }

  /// Builds the 10 [HostToolHandler] instances for computer use.
  List<HostToolHandler> buildHandlers() => <HostToolHandler>[
    CuSessionStartTool(this),
    CuSessionExtendTool(this),
    ScreenCaptureTool(this),
    UiInspectTool(this),
    UiFindTool(this),
    InputClickTool(this),
    InputTypeTextTool(this),
    InputKeyTool(this),
    InputScrollTool(this),
    CuSessionEndTool(this),
  ];

  void dispose() {
    stopController.removeCancelListener(_onEmergencyStop);
    unawaited(_stateController.close());
  }
}

class CuSessionStartTool extends HostToolHandler {
  const CuSessionStartTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'cu.session_start';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final goal = context.arguments['goal'] as String;
    final apps = (context.arguments['apps'] as List).cast<String>();
    final domains = (context.arguments['domains'] as List).cast<String>();
    final maxSteps = context.arguments['maxSteps'] as int;
    final maxMinutes = context.arguments['maxMinutes'] as int;
    final sessionId = await manager.startSession(
      goal: goal,
      apps: apps,
      domains: domains,
      maxSteps: maxSteps,
      maxMinutes: maxMinutes,
      policy: context.policy!,
      appScanner: context.appScanner,
      allowZeroConfigAppDiscovery: true,
    );
    return ToolHandlerOutput(
      text: 'Đã bắt đầu phiên điều khiển màn hình ($sessionId).',
      structuredContent: <String, Object?>{'sessionId': sessionId},
      toastBody: 'bắt đầu phiên điều khiển màn hình',
    );
  }
}

class CuSessionExtendTool extends HostToolHandler {
  const CuSessionExtendTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'cu.session_extend';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final result = await manager.extendSession(
      sessionId: context.arguments['sessionId'] as String,
      apps: (context.arguments['apps'] as List).cast<String>(),
      domains: (context.arguments['domains'] as List).cast<String>(),
      policy: context.policy!,
      appScanner: context.appScanner,
      allowZeroConfigAppDiscovery: true,
    );
    return ToolHandlerOutput(
      text: 'Đã mở rộng phiên điều khiển màn hình.',
      structuredContent: <String, Object?>{
        'sessionId': context.arguments['sessionId'],
        'apps': result.apps,
        'domains': result.domains,
      },
      toastBody: 'đã thêm ứng dụng/tên miền vào phiên điều khiển',
    );
  }
}

class ScreenCaptureTool extends HostToolHandler {
  const ScreenCaptureTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'screen.capture';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final scope = context.arguments['scope'] as String;
    final maxEdge = context.arguments['maxEdge'] as int;
    final result = await manager.captureScreen(scope: scope, maxEdge: maxEdge);
    return ToolHandlerOutput(
      text: 'Đã chụp màn hình ($scope).',
      structuredContent: result,
    );
  }
}

class UiInspectTool extends HostToolHandler {
  const UiInspectTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'ui.inspect';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final maxNodes = context.arguments['maxNodes'] as int;
    final skeleton = context.arguments['skeleton'] == true;
    final interactiveOnly = context.arguments['interactiveOnly'] == true;
    final rootElementId = context.arguments['rootElementId'] as String?;
    final collapseWebWrappers =
        context.arguments['collapseWebWrappers'] == true;
    final result = await manager.inspectWindow(
      maxNodes: maxNodes,
      skeleton: skeleton,
      interactiveOnly: interactiveOnly,
      rootElementId: rootElementId,
      collapseWebWrappers: collapseWebWrappers,
    );
    return ToolHandlerOutput(
      text: 'Đã đọc cây giao diện (${result['appId']}).',
      structuredContent: result,
    );
  }
}

class UiFindTool extends HostToolHandler {
  const UiFindTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'ui.find';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final result = await manager.findElements(
      query: context.arguments['query'] as String?,
      role: context.arguments['role'] as String?,
      maxResults:
          (context.arguments['maxResults'] as int?) ?? defaultUiFindResults,
    );
    return ToolHandlerOutput(
      text: 'Đã tìm phần tử giao diện (${result['total']} kết quả).',
      structuredContent: result,
    );
  }
}

class InputClickTool extends HostToolHandler {
  const InputClickTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'input.click';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final result = await manager.executeInputAction(
      toolName: name,
      arguments: context.arguments,
      hasR3Approval: context.hasVerifiedR3Approval,
    );
    return ToolHandlerOutput(
      text: 'Đã nhấn chuột (${result['effect']}).',
      structuredContent: result,
    );
  }
}

class InputTypeTextTool extends HostToolHandler {
  const InputTypeTextTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'input.type_text';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final result = await manager.executeInputAction(
      toolName: name,
      arguments: context.arguments,
      hasR3Approval: context.hasVerifiedR3Approval,
    );
    return ToolHandlerOutput(
      text: 'Đã nhập văn bản (${result['effect']}).',
      structuredContent: result,
      toastBody: 'đã nhập văn bản vào ô được chọn',
    );
  }
}

class InputKeyTool extends HostToolHandler {
  const InputKeyTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'input.key';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final result = await manager.executeInputAction(
      toolName: name,
      arguments: context.arguments,
      hasR3Approval: context.hasVerifiedR3Approval,
    );
    return ToolHandlerOutput(
      text: 'Đã nhấn phím (${result['effect']}).',
      structuredContent: result,
    );
  }
}

class InputScrollTool extends HostToolHandler {
  const InputScrollTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'input.scroll';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final result = await manager.executeInputAction(
      toolName: name,
      arguments: context.arguments,
      hasR3Approval: context.hasVerifiedR3Approval,
    );
    return ToolHandlerOutput(
      text: 'Đã cuộn trang (${result['effect']}).',
      structuredContent: result,
    );
  }
}

class CuSessionEndTool extends HostToolHandler {
  const CuSessionEndTool(this.manager);
  final ComputerUseSessionManager manager;

  @override
  String get name => 'cu.session_end';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final sessionId = context.arguments['sessionId'] as String;
    final outcome = context.arguments['outcome'] as String;
    await manager.endSession(sessionId: sessionId, outcome: outcome);
    return const ToolHandlerOutput(
      text: 'Đã kết thúc phiên điều khiển màn hình.',
      structuredContent: <String, Object?>{'ended': true},
      toastBody: 'đã kết thúc phiên điều khiển màn hình',
    );
  }
}
