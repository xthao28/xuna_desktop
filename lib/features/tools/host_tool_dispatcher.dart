import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_mcp_bridge.dart';
import 'package:xuna_desktop/features/discovery/auto_smart_home_bridge.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
import 'package:xuna_desktop/features/discovery/auto_tv_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/exec/exec_tools.dart';
import 'package:xuna_desktop/features/exec/fs_tools.dart';
import 'package:xuna_desktop/features/native_bridge/macos_native_app_bridge.dart';
import 'package:xuna_desktop/features/native_bridge/native_app_bridge.dart';
import 'package:xuna_desktop/features/native_bridge/windows_native_app_bridge.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/browser_bridge/browser_engine_provider.dart';
import 'package:xuna_desktop/features/browser_bridge/cdp_browser_engine_provider.dart';
import 'package:xuna_desktop/features/tools/browser_tool_handlers.dart';
import 'package:xuna_desktop/features/tools/handlers/forge_claw_tool_handlers.dart';
import 'package:xuna_desktop/features/tools/handlers/mvp_tool_handlers.dart';
import 'package:xuna_desktop/features/tools/handlers/symbiotic_tool_handlers.dart';
import 'package:xuna_desktop/features/tools/handlers/tv_smarthome_handlers.dart';
import 'package:xuna_desktop/features/tools/handlers/workspace_copilot_handlers.dart';
import 'package:xuna_desktop/features/tools/native_app_handlers.dart';
import 'package:xuna_desktop/features/watch/acp_harness_adapter.dart';
import 'package:xuna_desktop/features/watch/protocol_task_registry.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

export 'package:xuna_desktop/features/tools/browser_tool_handlers.dart';
export 'package:xuna_desktop/features/tools/handlers/forge_claw_tool_handlers.dart';
export 'package:xuna_desktop/features/tools/handlers/mvp_tool_handlers.dart';
export 'package:xuna_desktop/features/tools/handlers/symbiotic_tool_handlers.dart';
export 'package:xuna_desktop/features/tools/handlers/tv_smarthome_handlers.dart';
export 'package:xuna_desktop/features/tools/handlers/workspace_copilot_handlers.dart';
export 'package:xuna_desktop/features/tools/native_app_handlers.dart';

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
      pushEntry(entry);
    }
  }

  void pushEntry(ReversibleActionEntry entry) {
    if (_stack.length >= maxEntries) {
      _stack.removeAt(0);
    }
    _stack.add(entry);
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

typedef SubStepExecutor =
    Future<ToolHandlerOutput> Function(
      String toolName,
      Map<String, Object?> arguments, [
      ApprovalToken? approval,
    ]);

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
    required this.tvScanner,
    required this.smartHomeBridge,
    required this.symbioticService,
    required this.actionLedger,
    required this.cancellationToken,
    required this.agentVersion,
    required this.nowUtc,
    this.beamDirectoryPath,
    this.subStepExecutor,
    this.computerUseManager,
    this.protocolTaskRegistry,
    this.acpHarnessAdapter,
    this.hasVerifiedR3Approval = false,
    this.execRegistry,
    this.execFsContext,
    this.deadlineMs,
  });

  /// RAM-only registry of `exec.run` children (`ADR-0018`).
  final ExecProcessRegistry? execRegistry;

  /// Host facts used to classify `fs.*` / `exec.*` paths (home, symlinks).
  final ExecFsHostContext? execFsContext;

  /// The `tools/call` deadline (`xuna/deadlineMs`), when known.
  final int? deadlineMs;

  /// Whether the call carries an approval the host verified as R3-grade:
  /// bound to these arguments, unexpired, scope `once` and signed by an
  /// enrolled phone key. Handlers that raise the risk from the live screen
  /// (`input.*`, UDC-17 S17.1) read this instead of the argument-derived risk.
  final bool hasVerifiedR3Approval;

  final Map<String, Object?> arguments;
  final PolicyEvaluationResult evaluation;
  final HostPolicy? policy;
  final XunaHostChannel channel;
  final AutoAppScanner appScanner;
  final AutoWorkspaceIndexer workspaceIndexer;
  final AutoMcpBridge mcpBridge;
  final AutoTvScanner tvScanner;
  final AutoSmartHomeBridge smartHomeBridge;
  final AutoSymbioticService symbioticService;
  final ReversibleActionLedger actionLedger;
  final ToolCancellationToken cancellationToken;
  final String agentVersion;
  final DateTime nowUtc;
  final String? beamDirectoryPath;
  final SubStepExecutor? subStepExecutor;
  final ComputerUseSessionManager? computerUseManager;
  final ProtocolTaskRegistry? protocolTaskRegistry;
  final AcpHarnessAdapter? acpHarnessAdapter;
}

/// Base class for each of the 12 MVP tools (`UDC-3` §5.6.1: one class per tool).
abstract class HostToolHandler {
  const HostToolHandler();

  String get name;

  Future<ToolHandlerOutput> execute(ToolExecutionContext context);
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
    if (entry.originalTool == 'pipeline.execute_universal') {
      context.symbioticService.undoLastBatchFileOps();
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

/// Registry and dispatcher for all MVP, Dev Workspace, Desk Co-Pilot, Ambient Co-Pilot, Smart TV/Home, and Symbiotic Co-Pilot tools (`UDC-3` §5.6.5, `UDC-11`..`UDC-15`).
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
    AutoTvScanner? tvScanner,
    AutoSmartHomeBridge? smartHomeBridge,
    AutoSymbioticService? symbioticService,
    ReversibleActionLedger? actionLedger,
    this.beamDirectoryPath,
    this.agentVersion = '0.1.0',
    this.maxIdempotencyCacheEntries = 256,
    NativeAppBridge? nativeAppBridge,
    BrowserEngineProvider? browserEngineProvider,
    ProtocolTaskRegistry? protocolTaskRegistry,
    AcpHarnessAdapter? acpHarnessAdapter,
    ExecProcessRegistry? execRegistry,
    List<HostToolHandler>? handlers,
  }) : execRegistry =
           execRegistry ??
           ExecProcessRegistry(stopController: stopController, logger: logger),
       _ownsProtocolTaskRegistry = protocolTaskRegistry == null,
       protocolTaskRegistry =
           protocolTaskRegistry ??
           ProtocolTaskRegistry(stopController: stopController),
       nativeAppBridge =
           nativeAppBridge ??
           (Platform.isMacOS
               ? MacosNativeAppBridge()
               : WindowsNativeAppBridge()),
       browserEngineProvider =
           browserEngineProvider ?? CdpBrowserEngineProvider(),
       appScanner = appScanner ?? AutoAppScanner(),
       workspaceIndexer = workspaceIndexer ?? AutoWorkspaceIndexer(),
       tvScanner = tvScanner ?? AutoTvScanner(),
       smartHomeBridge = smartHomeBridge ?? AutoSmartHomeBridge(),
       symbioticService = symbioticService ?? AutoSymbioticService(),
       actionLedger = actionLedger ?? ReversibleActionLedger() {
    this.acpHarnessAdapter =
        acpHarnessAdapter ??
        AcpHarnessAdapter(taskRegistry: this.protocolTaskRegistry);
    this.mcpBridge =
        mcpBridge ?? AutoMcpBridge(taskRegistry: this.protocolTaskRegistry);
    final registered =
        handlers ??
        <HostToolHandler>[
          ...defaultMvpToolHandlers,
          ...defaultWorkspaceCopilotToolHandlers,
          const ActionUndoTool(),
          ...defaultTvSmartHomeToolHandlers,
          ...defaultSymbioticToolHandlers,
          ...defaultForgeClawToolHandlers,
          ...defaultNativeAppToolHandlers(this.nativeAppBridge),
          ...defaultBrowserToolHandlers(this.browserEngineProvider),
          ...defaultFsToolHandlers,
          ...defaultExecToolHandlers,
          if (computerUseManager != null)
            ...computerUseManager!.buildHandlers(),
        ];
    for (final handler in registered) {
      ToolDescriptor.validateToolName(handler.name);
      _handlers[handler.name] = handler;
    }
    stopController.addCancelListener(_onEmergencyStop);
    // ADR-0018: `exec.*` permission is part of the manifest, so a local
    // shellControl change must refresh the backend's copy (tools/list_changed).
    _shellEnabled = policyStore.evaluator.policy?.shellControl.enabled ?? false;
    _policySub = policyStore.changes.listen((evaluator) {
      final enabled = evaluator.policy?.shellControl.enabled ?? false;
      if (enabled == _shellEnabled) return;
      _shellEnabled = enabled;
      if (!enabled) unawaited(this.execRegistry.killAll());
      if (!_toolsListChanged.isClosed) _toolsListChanged.add(null);
    });
  }

  bool _shellEnabled = false;
  StreamSubscription<HostPolicyEvaluator>? _policySub;

  final HostPolicyStore policyStore;
  final XunaHostChannel channel;
  final AuditLogStore auditStore;

  /// `exec.run` children of this host (`ADR-0018`); killed on E-Stop.
  final ExecProcessRegistry execRegistry;
  final EmergencyStopController stopController;
  final ContentFreeLogger logger;
  final EnrollmentStateStore? enrollmentStore;
  final ComputerUseSessionManager? computerUseManager;
  final NativeAppBridge nativeAppBridge;
  final BrowserEngineProvider browserEngineProvider;
  final AutoAppScanner appScanner;
  final AutoWorkspaceIndexer workspaceIndexer;
  late final AutoMcpBridge mcpBridge;
  final AutoTvScanner tvScanner;
  final AutoSmartHomeBridge smartHomeBridge;
  final AutoSymbioticService symbioticService;
  final ReversibleActionLedger actionLedger;
  final ProtocolTaskRegistry protocolTaskRegistry;
  late final AcpHarnessAdapter acpHarnessAdapter;
  final bool _ownsProtocolTaskRegistry;
  final String? beamDirectoryPath;
  final String agentVersion;
  final int maxIdempotencyCacheEntries;

  final Map<String, HostToolHandler> _handlers = <String, HostToolHandler>{};
  final LinkedHashMap<String, XtpResponse> _idempotencyCache =
      LinkedHashMap<String, XtpResponse>();
  final Map<Object, ToolCancellationToken> _inFlightByRequestId =
      <Object, ToolCancellationToken>{};
  final StreamController<void> _toolsListChanged =
      StreamController<void>.broadcast();
  Future<void> _serialLaneTail = Future<void>.value();
  int _parallelReadLaneCount = 0;
  int _serialActionLaneCount = 0;

  /// Broadcast stream that fires whenever the dynamic forged-tool catalog changes
  /// (`FORGE-LATM` — triggers `notifications/tools/list_changed` on the active XTP session).
  Stream<void> get toolsListChanged => _toolsListChanged.stream;

  /// Number of read-only / observation tool calls executed on the concurrent
  /// `ParallelReadLane` (`CLAW-4`).
  int get parallelReadLaneCount => _parallelReadLaneCount;

  /// Number of state-changing tool calls serialized on `SerialActionLane` (`CLAW-4`).
  int get serialActionLaneCount => _serialActionLaneCount;

  static const Set<String> _parallelReadLaneTools = <String>{
    'host.status',
    'media.now_playing',
    'app.list_allowed',
    'workflow.list',
    'browser.current_url',
    'browser.read_page',
    'workspace.git_summary',
    'workspace.watch_task',
    'workspace.capture_capsule',
    'workspace.list_capsules',
    'selection.read',
    'window.active_context',
    'mcp.list_servers',
    'mcp.task_result',
    'tv.list_devices',
    'smarthome.list_entities',
    'dev.ports',
    'system.vitals',
    'pocket.list_items',
    'watchdog.watch_process_or_port',
    'watchdog.watch_resource_threshold',
    'watchdog.list_and_clear',
    'habit.propose_workflow',
    'forge.synthesize_skill',
    'forge.list_and_manage',
    'teach.record_session',
    'skill.markdown_bridge',
    'skill.record_correction',
    'skill.workshop_sync',
    'memory.markdown_vault',
    'browser.semantic_snapshot',
    'heartbeat.configure_and_tick',
    'screen.capture',
    'ui.inspect',
    'ui.observe_hybrid',
    'ui.find',
    'notes.search',
    'calendar.list_events',
    'finder.reveal',
    'web.snapshot',
    'web.extract',
    'web.wait_for',
    'fs.list_files',
    'fs.read_file',
    'fs.grep',
    'exec.status',
    'exec.cancel',
  };

  /// Builds the `tools/list` manifest with current OS permission states.
  Future<List<ToolDescriptor>> buildManifest() async {
    HostPermissionSnapshot perms;
    try {
      perms = await channel.permissions();
    } catch (_) {
      // A failed read is not a grant: advertise the state as undetermined.
      perms = const HostPermissionSnapshot.unknown();
    }
    final mvp = buildMvpToolCatalog(
      defaultPermission: perms.accessibility,
      includeBrowserCurrentUrl: true,
      includeDevWorkspaceTools: true,
      includeDeskCopilotTools: true,
      includeAmbientCopilotTools: true,
      includeSmartTvHomeTools: true,
      includeSymbioticCopilotTools: true,
      includeSymbioticEvolutionTools: true,
      includeSymbioticSentinelTools: true,
      includeOmniForgeTools: true,
      includeClawPulseTools: true,
      includeExecFsTools: true,
      shellEnabled: policyStore.evaluator.policy?.shellControl.enabled ?? false,
    );
    final dynamicForged = symbioticService.buildDynamicToolDescriptors(
      defaultPermission: perms.accessibility,
    );
    final nativeCatalog = buildNativeAppToolCatalog(
      defaultPermission: perms.accessibility,
    );
    final browserCatalog = buildBrowserToolCatalog(
      defaultPermission: perms.accessibility,
    );
    if (computerUseManager == null) {
      return <ToolDescriptor>[
        ...mvp,
        ...dynamicForged,
        ...nativeCatalog,
        ...browserCatalog,
      ];
    }
    return <ToolDescriptor>[
      ...mvp,
      ...dynamicForged,
      ...nativeCatalog,
      ...browserCatalog,
      ...buildComputerUseTools(
        defaultPermission: perms.accessibility,
        screenCapturePermission: computerUseManager!.supportsScreenCapture
            ? perms.screenRecording
            : XtpPermissionState.notDetermined,
      ),
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
      cuSessionApprovedApps:
          computerUseManager?.activeSession?.allowedAppIdentifiers,
      allowZeroConfigAppDiscovery: true,
      allowPublicHttpsDomains: true,
      nowUtc: nowUtc,
      execFsContext: buildExecFsHostContext(execRegistry),
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

    final isDynamicForgedTool = params.name.startsWith('forge.custom_');
    final handler = isDynamicForgedTool
        ? _handlers['forge.run_skill']
        : _handlers[params.name];
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
        Map<String, Object?> stepArgs, [
        ApprovalToken? stepApproval,
      ]) async {
        // Terminal GUI hard-denial defense (Wave D Feature 7)
        if (isHardDeniedAppOrProcess(stepToolName)) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'policy_blocked',
          );
        }
        final checkApp =
            stepArgs['appId']?.toString() ??
            stepArgs['app']?.toString() ??
            stepArgs['process']?.toString();
        if (checkApp != null && isHardDeniedAppOrProcess(checkApp)) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'policy_blocked',
          );
        }

        // Resolve effective approval:
        // Eradicate synthetic approvals (hardcoded fake IDs).
        // If an approval is explicitly provided for this step, use it.
        // Otherwise, if the parent outer tool call carries a valid unexpired approval,
        // R2 sub-steps may inherit that parent approval token with signature: null (unsigned).
        // Any R3 sub-step strictly requires a fresh phone-signed P-256 signature, failing with
        // 'approval_signature_invalid' if absent or unsigned.
        ApprovalToken? effectiveApproval = stepApproval;
        if (effectiveApproval == null && stepArgs.containsKey('_approval')) {
          final raw = stepArgs['_approval'];
          if (raw is ApprovalToken) {
            effectiveApproval = raw;
          } else if (raw is Map) {
            effectiveApproval = ApprovalToken.fromJson(
              raw.map((k, v) => MapEntry(k.toString(), v)),
            );
          }
        }
        final parentApproval = params.approval;
        if (effectiveApproval == null &&
            parentApproval != null &&
            parentApproval.expiresAt.isAfter(effectiveNow)) {
          effectiveApproval = ApprovalToken(
            approvalId: parentApproval.approvalId,
            scope: parentApproval.scope,
            expiresAt: parentApproval.expiresAt,
            argsSha256: argsSha256(stepArgs),
            signature: null, // Sub-steps are never pre-signed with phone key
          );
        }

        final subEval = evaluator.evaluateInvocation(
          toolName: stepToolName,
          arguments: stepArgs,
          approval: effectiveApproval,
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

        final subHandler = _handlers[stepToolName];
        if (subHandler == null) {
          throw const XunaHostChannelException(
            status: XtpStatus.unsupported,
            errorCode: 'platform_unsupported',
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
          tvScanner: tvScanner,
          smartHomeBridge: smartHomeBridge,
          symbioticService: symbioticService,
          actionLedger: actionLedger,
          cancellationToken: cancelToken,
          agentVersion: agentVersion,
          nowUtc: effectiveNow,
          beamDirectoryPath: beamDirectoryPath,
          computerUseManager: computerUseManager,
          protocolTaskRegistry: protocolTaskRegistry,
          acpHarnessAdapter: acpHarnessAdapter,
        );
        final subOut = await subHandler.execute(subContext);
        actionLedger.record(
          originalTool: stepToolName,
          arguments: stepArgs,
          nowUtc: effectiveNow,
        );
        return subOut;
      }

      final effectiveArguments = isDynamicForgedTool
          ? <String, Object?>{'skillId': params.name, ...params.arguments}
          : params.arguments;

      final approval = params.approval;
      final hasVerifiedR3Approval =
          approval != null &&
          verifyPhoneSignedApproval(
                approval: approval,
                arguments: params.arguments,
                nowUtc: effectiveNow,
                hostId: enrolled?.hostId,
                pinnedPhonePublicKeys:
                    enrolled?.pinnedPhonePublicKeyBytes ?? const <Uint8List>[],
              ) ==
              null;

      final execContext = ToolExecutionContext(
        hasVerifiedR3Approval: hasVerifiedR3Approval,
        arguments: effectiveArguments,
        evaluation: evaluation,
        policy: evaluator.policy,
        channel: channel,
        appScanner: appScanner,
        workspaceIndexer: workspaceIndexer,
        mcpBridge: mcpBridge,
        tvScanner: tvScanner,
        smartHomeBridge: smartHomeBridge,
        symbioticService: symbioticService,
        actionLedger: actionLedger,
        cancellationToken: cancelToken,
        agentVersion: agentVersion,
        nowUtc: effectiveNow,
        beamDirectoryPath: beamDirectoryPath,
        subStepExecutor: executeSubStep,
        computerUseManager: computerUseManager,
        protocolTaskRegistry: protocolTaskRegistry,
        acpHarnessAdapter: acpHarnessAdapter,
        execRegistry: execRegistry,
        execFsContext: buildExecFsHostContext(execRegistry),
        deadlineMs: params.deadlineMs,
      );

      final deadline = Duration(milliseconds: params.deadlineMs);
      Future<ToolHandlerOutput?> runInAssignedLane() async {
        if (_parallelReadLaneTools.contains(params.name)) {
          _parallelReadLaneCount++;
          return handler.execute(execContext);
        }
        _serialActionLaneCount++;
        final prev = _serialLaneTail;
        final gate = Completer<void>();
        _serialLaneTail = gate.future;
        try {
          await prev;
          return await handler.execute(execContext);
        } finally {
          if (!gate.isCompleted) {
            gate.complete();
          }
        }
      }

      final output = await Future.any<ToolHandlerOutput?>(
        <Future<ToolHandlerOutput?>>[
          runInAssignedLane(),
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
          symbioticService.recordToolExecution(params.name);
        }
        if (const <String>{
          'forge.synthesize_skill',
          'forge.list_and_manage',
          'skill.workshop_sync',
          'skill.markdown_bridge',
          'teach.record_session',
        }.contains(params.name)) {
          if (!_toolsListChanged.isClosed) {
            _toolsListChanged.add(null);
          }
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
      // Agent-authored diagnostics (e.g. `missing_ref` candidates) let the model recover
      // instead of seeing only an opaque code.
      final message = error.message;
      structuredContent = <String, Object?>{
        'errorCode': error.errorCode,
        if (message != null && message.isNotEmpty)
          'message': message.length > 600 ? message.substring(0, 600) : message,
      };
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

    late final XtpResponse response;
    try {
      response = XtpResponse.toolCallResult(
        id: requestId,
        text: text,
        structuredContent: structuredContent,
        status: status,
        durationMs: stopwatch.elapsedMilliseconds,
        errorCode: errorCode,
      );
    } on XtpProtocolException {
      status = XtpStatus.failed;
      errorCode = 'payload_too_large';
      text =
          'Kết quả ${params.name} vượt quá giới hạn kích thước khung truyền.';
      response = XtpResponse.toolCallResult(
        id: requestId,
        text: text,
        structuredContent: const <String, Object?>{
          'errorCode': 'payload_too_large',
        },
        status: status,
        durationMs: stopwatch.elapsedMilliseconds,
        errorCode: errorCode,
      );
    } catch (_) {
      status = XtpStatus.failed;
      errorCode = 'os_error';
      text = 'Lỗi đóng gói kết quả ${params.name}.';
      response = XtpResponse.toolCallResult(
        id: requestId,
        text: text,
        structuredContent: const <String, Object?>{'errorCode': 'os_error'},
        status: status,
        durationMs: stopwatch.elapsedMilliseconds,
        errorCode: errorCode,
      );
    }

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

  /// Input tools whose risk the host decides from the live screen.
  static const Set<String> _liveClassifiedInputTools = <String>{
    'input.click',
    'input.drag',
    'input.type_text',
    'input.key',
    'input.scroll',
  };

  /// Answers `xuna/preflight` (`XUNA_XTP_V1_CONTRACT.md` §4.2.8, UDC-17
  /// S17.1): the risk this host would enforce for [params] and, for `input.*`,
  /// the live element it would act on. Executes nothing.
  ///
  /// The local policy runs without an approval: `approval_required` means
  /// "allowed at this risk once approved"; any other refusal is returned as a
  /// refusal so the backend does not ask the owner for a call that cannot run.
  Future<XtpResponse> preflight({
    required Object requestId,
    required PreflightParams params,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final enrolled = enrollmentStore?.current;
    final evaluation = policyStore.evaluator.evaluateInvocation(
      toolName: params.name,
      arguments: params.arguments,
      isStopped: stopController.isStopped,
      hostId: enrolled?.hostId,
      pinnedPhonePublicKeys:
          enrolled?.pinnedPhonePublicKeyBytes ?? const <Uint8List>[],
      isInApprovedCuSession: computerUseManager?.hasActiveSession ?? false,
      cuSessionApprovedApps:
          computerUseManager?.activeSession?.allowedAppIdentifiers,
      allowZeroConfigAppDiscovery: true,
      allowPublicHttpsDomains: true,
      nowUtc: now,
      execFsContext: buildExecFsHostContext(execRegistry),
    );

    XtpResponse refuse(XtpStatus status, String errorCode) {
      logger.info('tool.preflight', <String, Object?>{
        'tool': params.name,
        'status': status.wire,
        'errorCode': errorCode,
      });
      return XtpResponse.preflightResult(
        id: requestId,
        status: status,
        errorCode: errorCode,
      );
    }

    if (!evaluation.allowed && evaluation.errorCode != 'approval_required') {
      return refuse(
        evaluation.status,
        evaluation.errorCode ?? 'policy_blocked',
      );
    }

    var risk = evaluation.effectiveRisk;
    var reasonCode = evaluation.reasonCode ?? 'policy';
    String? elementRole;
    String? elementName;
    final manager = computerUseManager;
    if (_liveClassifiedInputTools.contains(params.name) && manager != null) {
      try {
        final isAutopilot =
            policyStore.evaluator.policy?.trustPreset == TrustPreset.autopilot;
        final live = await manager.preflightInputAction(
          toolName: params.name,
          arguments: params.arguments,
          autopilot: isAutopilot,
          nowUtc: now,
        );
        if (live.stepRisk.risk > risk) risk = live.stepRisk.risk;
        reasonCode = live.stepRisk.reasonCode;
        elementRole = live.elementRole;
        elementName = live.elementName;
      } on XunaHostChannelException catch (error) {
        return refuse(error.status, error.errorCode);
      } catch (_) {
        // The live screen could not be read: unclassifiable is R3 (ADR-0015).
        risk = RiskTier.r3;
        reasonCode = 'unclassified_target';
      }
    }

    logger.info('tool.preflight', <String, Object?>{
      'tool': params.name,
      'status': XtpStatus.ok.wire,
      'risk': risk.wire,
      'reasonCode': reasonCode,
    });
    return XtpResponse.preflightResult(
      id: requestId,
      status: XtpStatus.ok,
      effectiveRisk: risk,
      reasonCode: reasonCode,
      elementRole: elementRole,
      elementName: elementName,
    );
  }

  /// Returns the current policy, allow/deny rules, and discovered apps for `xuna/get_policy` (UDC-18).
  Future<XtpResponse> getPolicy({required Object requestId}) async {
    final policy = policyStore.evaluator.policy;
    final discovered = appScanner.discoverApps().map((a) => a.id).toList();
    final result = <String, Object?>{
      'schemaVersion': 1,
      'trustPreset': policy?.trustPreset.value ?? 'standard',
      'allowApps': policy?.apps.map((a) => a.id).toList() ?? const <String>[],
      'denyApps': policy?.denyApps ?? const <String>[],
      'allowDomains': policy?.urlDomains ?? const <String>[],
      'denyDomains': policy?.denyDomains ?? const <String>[],
      'discoveredApps': discovered,
      // Local-only switch: only the boolean summary leaves the host.
      'shellEnabled': policy?.shellControl.enabled ?? false,
    };
    return XtpResponse(id: requestId, result: result);
  }

  /// Validates and saves updated policy rules for `xuna/set_policy` (UDC-18).
  ///
  /// Safety hard guard: Immediately rejects with `policy_blocked` if any app in
  /// `allowApps` is empty or matches `isHardDeniedAppOrProcess` (15 Terminal GUIs:
  /// Terminal, iTerm, iTerm2, Warp, Alacritty, Kitty, WezTerm, wezterm-gui, Ghostty,
  /// Hyper, cmd, powershell, pwsh, wt, wsl, conhost, bash, zsh).
  ///
  /// R3 phone-signed approval gate is strictly preserved regardless of preset.
  Future<XtpFrame> setPolicy({
    required Object requestId,
    required SetPolicyParams params,
  }) async {
    for (final app in params.allowApps) {
      if (app.trim().isEmpty || isHardDeniedAppOrProcess(app)) {
        return XtpErrorResponse(
          id: requestId,
          code: JsonRpcErrorCode.invalidParams,
          message:
              'policy_blocked: Application "$app" is restricted or disallowed',
        );
      }
    }

    final currentPolicy = policyStore.evaluator.policy;
    final preset = TrustPreset.fromValue(params.trustPreset);

    final updatedApps = <AllowedAppConfig>[];
    final seenAppIds = <String>{};
    for (final appId in params.allowApps) {
      if (params.denyApps.any(
        (d) => d.trim().toLowerCase() == appId.trim().toLowerCase(),
      )) {
        continue;
      }
      final existing = currentPolicy?.findApp(appId);
      if (existing != null) {
        if (seenAppIds.add(existing.id)) {
          updatedApps.add(existing);
        }
      } else {
        final discovered = appScanner.findApp(appId);
        if (discovered != null) {
          if (seenAppIds.add(discovered.id)) {
            updatedApps.add(
              AllowedAppConfig(
                id: discovered.id,
                name: discovered.name,
                kind: discovered.kind,
                target: discovered.target,
                risk: RiskTier.r2,
              ),
            );
          }
        } else {
          final normalizedId = AutoAppScanner.normalizeId(appId);
          if (!isValidShortId(normalizedId)) {
            return XtpErrorResponse(
              id: requestId,
              code: JsonRpcErrorCode.invalidParams,
              message:
                  'policy_blocked: Application "$appId" has an invalid identifier',
            );
          }
          if (seenAppIds.add(normalizedId)) {
            updatedApps.add(
              AllowedAppConfig(
                id: normalizedId,
                name: appId.trim(),
                kind: Platform.isMacOS
                    ? AppLaunchKind.bundle
                    : AppLaunchKind.exe,
                target: appId.trim(),
                risk: RiskTier.r2,
              ),
            );
          }
        }
      }
    }

    final updatedPolicy = HostPolicy(
      schemaVersion: 1,
      trustPreset: preset,
      families:
          currentPolicy?.families ??
          <ToolFamily, FamilyPolicyDecision>{
            for (final f in ToolFamily.values) f: FamilyPolicyDecision.allow,
          },
      apps: List.unmodifiable(updatedApps),
      urlDomains: List.unmodifiable(params.allowDomains),
      workflows: currentPolicy?.workflows ?? const <WorkflowConfig>[],
      players: currentPolicy?.players ?? const <String>[],
      denyApps: List.unmodifiable(params.denyApps),
      denyDomains: List.unmodifiable(params.denyDomains),
      protocolHarnesses:
          currentPolicy?.protocolHarnesses ?? const <ProtocolHarnessConfig>[],
      // Local-only (ADR-0018): a remote policy write never changes it.
      shellControl:
          currentPolicy?.shellControl ?? const ShellControlPolicy.disabled(),
    );

    await policyStore.savePolicy(updatedPolicy);

    return XtpResponse(
      id: requestId,
      result: const <String, Object?>{'schemaVersion': 1, 'status': 'ok'},
    );
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
    unawaited(_policySub?.cancel());
    if (_ownsProtocolTaskRegistry) {
      unawaited(protocolTaskRegistry.dispose());
    }
    unawaited(_toolsListChanged.close());
  }
}
