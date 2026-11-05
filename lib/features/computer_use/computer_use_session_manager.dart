import 'dart:async';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/computer_use/driver_map.dart';
import 'package:xuna_desktop/features/computer_use/mcp_stdio_client.dart';
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
  });

  final String appId;
  final String processName;
  final String windowTitle;
  final List<Map<String, Object?>> nodes;
  final String? browserUrl;
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
          'name':
              (map['name'] as String?) ?? (map['title'] as String?) ?? '',
          if (map['value'] != null) 'value': '${map['value']}',
          'enabled':
              map['enabled'] != false && !states.contains('disabled'),
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
          (data['dataBase64'] as String?) ??
          (data['base64'] as String?) ??
          '',
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
  NativeHostChannelComputerUseProvider({
    required this.channel,
    this.agentDesktopBinaryPath,
  });

  final XunaHostChannel channel;
  final String? agentDesktopBinaryPath;
  AgentDesktopComputerUseProvider? _externalDelegate;

  static const Set<String> _browserAppIds = <String>{
    'msedge',
    'edge',
    'chrome',
    'firefox',
    'brave',
    'safari',
    'arc',
    'browser',
  };

  @override
  Future<void> startSession({
    required String sessionId,
    required String capabilityManifestYaml,
  }) async {
    _externalDelegate = null;
    final binPath = (agentDesktopBinaryPath ??
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
      maxNodes: maxNodes.clamp(1, 80),
    );
    final rawProc =
        (ctx.processName.trim().isNotEmpty && ctx.processName != 'unknown')
            ? ctx.processName.trim()
            : (tree.appName.trim().isNotEmpty
                ? tree.appName.trim()
                : 'explorer.exe');
    final appId = _normalizeAppIdFromProcess(rawProc);
    final winTitle = tree.windowTitle.trim().isNotEmpty
        ? tree.windowTitle.trim()
        : ctx.windowTitle.trim();

    String? browserUrl;
    if (_browserAppIds.contains(appId)) {
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
      final role = isPwd
          ? 'password'
          : _normalizeNativeRole((raw['role'] as String?) ?? 'button');
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
      message: 'No screen-capture driver is configured on this host; use '
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
    final canonicalRef = _toNativeUiRefId(elementId, fallback: 'ui_1');
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
    final canonicalRef = _toNativeUiRefId(elementId, fallback: 'ui_1');
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
    final canonicalRef = _toNativeUiRefId(elementId, fallback: 'ui_1');
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

  static String _normalizeAppIdFromProcess(String rawProcess) {
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
    return clean.isEmpty ? 'explorer' : clean;
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

  static String _toNativeUiRefId(String? rawElementId, {required String fallback}) {
    if (rawElementId == null || rawElementId.trim().isEmpty) {
      return fallback;
    }
    final trimmed = rawElementId.trim();
    if (trimmed.startsWith('ui_') || trimmed.startsWith('shortcut:')) {
      return trimmed;
    }
    final parsed = parseSnapshotElementRef(trimmed);
    if (parsed != null) {
      return 'ui_${parsed.elementNumber}';
    }
    final trailingDigits = RegExp(r'(\d+)$').firstMatch(trimmed);
    if (trailingDigits != null) {
      return 'ui_${trailingDigits.group(1)}';
    }
    return trimmed;
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
    required this.allowedDomains,
    required this.maxSteps,
    required this.maxMinutes,
    required this.startedAtUtc,
  });

  final String sessionId;
  final String goal;
  final Set<String> allowedApps;
  final List<String> allowedDomains;
  final int maxSteps;
  final int maxMinutes;
  final DateTime startedAtUtc;

  int stepsExecuted = 0;
  int consecutiveNoChange = 0;
  String? lastActionSignature;
  int snapshotCounter = 0;
  String? latestSnapshotId;
  final Map<String, SnapshotElementIdentity> snapshotRefMaps =
      <String, SnapshotElementIdentity>{};

  String mintNextSnapshotId() {
    snapshotCounter++;
    final id = 's${snapshotCounter.toRadixString(16).padLeft(8, '0')}';
    latestSnapshotId = id;
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
  }) {
    stopController.addCancelListener(_onEmergencyStop);
  }

  final ComputerUseProvider provider;
  final EmergencyStopController stopController;

  ComputerUseSessionState? _activeSession;
  int _sessionCounter = 0;
  final StreamController<ComputerUseSessionState?> _stateController =
      StreamController<ComputerUseSessionState?>.broadcast();

  ComputerUseSessionState? get activeSession => _activeSession;
  bool get hasActiveSession => _activeSession != null;
  Stream<ComputerUseSessionState?> get sessionChanges =>
      _stateController.stream;

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
    String? requestedSessionId,
    DateTime? nowUtc,
  }) async {
    if (_activeSession != null) {
      await endSession(
        sessionId: _activeSession!.sessionId,
        outcome: 'stopped',
      );
    }

    for (final appId in apps) {
      if (isHardDeniedAppOrProcess(appId)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'denylisted_target_forbidden',
        );
      }
      final cfg = policy.findApp(appId);
      if (cfg == null) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'policy_blocked',
        );
      }
      if (isHardDeniedAppOrProcess(cfg.target)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'denylisted_target_forbidden',
        );
      }
    }

    final normalizedDomains = <String>[
      for (final d in domains) normalizeDomainAllowlistEntry(d),
    ];

    final sessionId =
        requestedSessionId ?? 'cu-session-${++_sessionCounter}';
    final allowedAppConfigs = <AllowedAppConfig>[
      for (final appId in apps)
        if (policy.findApp(appId) != null) policy.findApp(appId)!,
    ];

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
      allowedDomains: normalizedDomains,
      maxSteps: maxSteps.clamp(1, 20),
      maxMinutes: maxMinutes.clamp(1, 10),
      startedAtUtc: (nowUtc ?? DateTime.now()).toUtc(),
    );
    _activeSession = state;
    _stateController.add(state);
    return sessionId;
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
    final explicitElementName = arguments['elementName'] as String?;
    if (explicitElementName != null &&
        isPasswordUiNode(<String, Object?>{'name': explicitElementName})) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'password_field_forbidden',
      );
    }

    // Check if the actual UI node in the tree has a consequential name even if
    // the LLM omitted or disguised `elementName` in `input.click`!
    final effectiveElementName =
        (targetNode?['name'] as String?) ?? explicitElementName;
    if (toolName == 'input.click' &&
        isConsequentialElementName(effectiveElementName) &&
        !hasR3Approval) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'approval_required',
      );
    }

    // Pre-dispatch Actionability Battery (`agent-desktop` actionability checks).
    if (targetNode != null) {
      _enforceActionabilityBattery(
        toolName: toolName,
        targetNode: targetNode,
        allNodes: beforeWindow.nodes,
      );
    }

    // Duplicate-action detection (`UDC-8` §4.3): same action on the same
    // element twice in a row stops the session.
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
    final route = (!headed &&
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
    final openSurfaces = extractOverlaySurfaces(afterWindow.nodes);

    return <String, Object?>{
      'effect': changed ? 'changed' : 'no_change',
      'route': route,
      'disposition': disposition,
      if (session.latestSnapshotId != null)
        'snapshotId': session.latestSnapshotId,
      if (openSurfaces.isNotEmpty) 'surfaces': openSurfaces,
      if (waitSatisfied != null) 'waitSatisfied': waitSatisfied,
    };
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
  _pollPostActionWaitCondition({
    String? waitFor,
    String? waitForGone,
  }) async {
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
    if (!session.allowedApps.contains(window.appId)) {
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

  /// Builds the 8 [HostToolHandler] instances for computer use.
  List<HostToolHandler> buildHandlers() => <HostToolHandler>[
    CuSessionStartTool(this),
    ScreenCaptureTool(this),
    UiInspectTool(this),
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
    );
    return ToolHandlerOutput(
      text: 'Đã bắt đầu phiên điều khiển màn hình ($sessionId).',
      structuredContent: <String, Object?>{'sessionId': sessionId},
      toastBody: 'bắt đầu phiên điều khiển màn hình',
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
      hasR3Approval: context.evaluation.effectiveRisk >= RiskTier.r3,
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
      hasR3Approval: true,
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
      hasR3Approval: context.evaluation.effectiveRisk >= RiskTier.r3,
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
      hasR3Approval: false,
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
