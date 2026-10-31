import 'dart:async';

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
/// ([CuaDriverComputerUseProvider]) or the native UIA/AX fallback provider
/// ([FallbackUiaAxComputerUseProvider]).
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
  Future<Map<String, Object?>> inspectWindow({
    required int maxNodes,
    DateTime? nowUtc,
  }) async {
    final session = _requireActiveSession(nowUtc: nowUtc);
    final window = await provider.inspectActiveWindow(maxNodes: maxNodes);
    _enforceWindowHardRefusals(session: session, window: window);
    final redactedNodes = redactUiTreeNodes(
      window.nodes,
      maxNodes: maxNodes.clamp(1, 300),
    );
    return <String, Object?>{
      'appId': window.appId,
      'windowTitle': window.windowTitle.length > 120
          ? window.windowTitle.substring(0, 120)
          : window.windowTitle,
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
  /// duplicate-action detection, and post-action UI effect verification.
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

    // Check target element against password fields and consequential lexicon.
    final elementId = arguments['elementId'] as String?;
    Map<String, Object?>? targetNode;
    if (elementId != null && elementId.isNotEmpty) {
      for (final node in beforeWindow.nodes) {
        if (node['id'] == elementId) {
          targetNode = node;
          break;
        }
      }
    }

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

    switch (toolName) {
      case 'input.click':
        await provider.performClick(
          window: beforeWindow,
          elementId: elementId,
          x: arguments['x'] as int?,
          y: arguments['y'] as int?,
        );
      case 'input.type_text':
        await provider.performTypeText(
          window: beforeWindow,
          elementId: elementId!,
          text: arguments['text'] as String,
        );
      case 'input.key':
        await provider.performKey(
          window: beforeWindow,
          combo: arguments['combo'] as String,
        );
      case 'input.scroll':
        await provider.performScroll(
          window: beforeWindow,
          elementId: elementId,
          direction: arguments['direction'] as String,
          amount: arguments['amount'] as int,
        );
      default:
        throw const XunaHostChannelException(
          status: XtpStatus.unsupported,
          errorCode: 'platform_unsupported',
        );
    }

    // Re-inspect after acting to verify effect (`changed` vs `no_change`).
    final afterWindow = await provider.inspectActiveWindow(maxNodes: 300);
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

    return <String, Object?>{'effect': changed ? 'changed' : 'no_change'};
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
    final result = await manager.inspectWindow(maxNodes: maxNodes);
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
