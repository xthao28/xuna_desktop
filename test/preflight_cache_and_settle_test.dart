import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

const String _hostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';

class _ScriptedNativeChannel extends FakeXunaHostChannel {
  List<Map<String, Object?>> treeNodes = <Map<String, Object?>>[
    <String, Object?>{
      'refId': 'ui_1',
      'role': 'AXSearchField',
      'label': 'Tìm kiếm',
      'isPassword': false,
      'bounds': <double>[0.1, 0.1, 0.5, 0.2],
    },
    <String, Object?>{
      'refId': 'ui_2',
      'role': 'AXButton',
      'label': 'Mở trang tiếp',
      'isPassword': false,
      'bounds': <double>[0.1, 0.3, 0.4, 0.4],
    },
    <String, Object?>{
      'refId': 'ui_3',
      'role': 'AXButton',
      'label': 'Xóa tài khoản',
      'isPassword': false,
      'bounds': <double>[0.1, 0.5, 0.4, 0.6],
    },
    <String, Object?>{
      'refId': 'ui_4',
      'role': 'AXSecureTextField',
      'label': 'Mật khẩu',
      'isPassword': true,
      'bounds': <double>[0.1, 0.7, 0.5, 0.8],
    },
  ];
  String treeWindowTitleOverride = '';
  bool mutateNodesOnEachInspect = false;
  bool bumpTitleOnControlInvoke = false;
  String? overrideCaptureBase64;
  int _inspectTick = 0;
  int _controlTick = 0;

  int get inspectUiTreeCount =>
      invokedMethods.where((m) => m.startsWith('inspectWindowUiTree')).length;

  int get readContext200Count =>
      invokedMethods.where((m) => m == 'readActiveWindowContext:200').length;

  int get invokeControlCount =>
      invokedMethods.where((m) => m.startsWith('invokeWindowUiControl')).length;

  @override
  Future<WindowUiTreeSnapshot> inspectWindowUiTree({
    String? windowTitle,
    int maxNodes = 35,
  }) async {
    invokedMethods.add(
      'inspectWindowUiTree:${windowTitle ?? 'active'}:$maxNodes',
    );
    _inspectTick++;
    final nodes = mutateNodesOnEachInspect
        ? <Map<String, Object?>>[
            ...treeNodes,
            <String, Object?>{
              'refId': 'ui_${100 + _inspectTick}',
              'role': 'AXStaticText',
              'label': 'Tick $_inspectTick',
              'isPassword': false,
            },
          ]
        : treeNodes;
    return WindowUiTreeSnapshot(
      windowTitle: treeWindowTitleOverride.isNotEmpty
          ? treeWindowTitleOverride
          : activeWindowContextResult.windowTitle,
      appName: activeWindowContextResult.appName,
      nodes: nodes,
    );
  }

  @override
  Future<HostScreenCaptureResult> captureScreen({
    String scope = 'active_window',
    int maxEdge = 1280,
    List<Map<String, Object?>>? somMarks,
  }) async {
    if (overrideCaptureBase64 != null) {
      invokedMethods.add('captureScreen:$scope:$maxEdge');
      return HostScreenCaptureResult(
        mimeType: 'image/jpeg',
        width: 960,
        height: 600,
        dataBase64: overrideCaptureBase64!,
      );
    }
    return super.captureScreen(
      scope: scope,
      maxEdge: maxEdge,
      somMarks: somMarks,
    );
  }

  @override
  Future<WindowUiControlActionResult> invokeWindowUiControl({
    required String action,
    required String refId,
    String? windowTitle,
    String? valueText,
    bool submit = true,
  }) async {
    if (bumpTitleOnControlInvoke) {
      treeWindowTitleOverride = 'Notes #${++_controlTick}';
    }
    return super.invokeWindowUiControl(
      action: action,
      refId: refId,
      windowTitle: windowTitle,
      valueText: valueText,
      submit: submit,
    );
  }
}

class _CountingFallbackProvider extends FallbackUiaAxComputerUseProvider {
  _CountingFallbackProvider({required super.initialWindow});

  int inspectCalls = 0;
  bool mutateOnInspect = false;

  @override
  Future<ActiveWindowObservation> inspectActiveWindow({
    required int maxNodes,
  }) async {
    inspectCalls++;
    final base = await super.inspectActiveWindow(maxNodes: maxNodes);
    if (!mutateOnInspect) return base;
    return ActiveWindowObservation(
      appId: base.appId,
      processName: base.processName,
      windowTitle: '${base.windowTitle} #$inspectCalls',
      nodes: base.nodes,
      browserUrl: base.browserUrl,
      isElevated: base.isElevated,
      focusedRole: base.focusedRole,
    );
  }
}

HostPolicy _buildF11Policy() => HostPolicy(
  schemaVersion: 1,
  families: const <ToolFamily, FamilyPolicyDecision>{
    ToolFamily.cu: FamilyPolicyDecision.allow,
    ToolFamily.screen: FamilyPolicyDecision.allow,
    ToolFamily.ui: FamilyPolicyDecision.allow,
    ToolFamily.input: FamilyPolicyDecision.allow,
    ToolFamily.app: FamilyPolicyDecision.allow,
  },
  apps: <AllowedAppConfig>[
    AllowedAppConfig(
      id: 'notes',
      name: 'Notes',
      kind: AppLaunchKind.bundle,
      target: 'com.apple.Notes',
      risk: RiskTier.r2,
    ),
    AllowedAppConfig(
      id: 'spotify',
      name: 'Spotify',
      kind: AppLaunchKind.bundle,
      target: 'com.spotify.client',
      risk: RiskTier.r2,
    ),
    AllowedAppConfig(
      id: 'safari',
      name: 'Safari',
      kind: AppLaunchKind.bundle,
      target: 'com.apple.Safari',
      risk: RiskTier.r2,
    ),
  ],
  urlDomains: const <String>['example.com'],
  workflows: const <WorkflowConfig>[],
  players: const <String>[],
);

Future<
  ({
    Directory tempDir,
    HostPolicy policy,
    _ScriptedNativeChannel channel,
    ComputerUseSessionManager manager,
    HostToolDispatcher dispatcher,
    int nowMs,
    void Function(int ms) setNowMs,
    List<int> recordedDelaysMs,
    Future<void> Function() dispose,
  })
>
_createF11Harness({
  ComputerUseProvider Function(_ScriptedNativeChannel ch)? buildProvider,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('xuna_f11_test_');
  final paths = AgentPaths.resolve(overrideRootDir: tempDir);
  await paths.ensureDirectories();

  final logger = ContentFreeLogger();
  final policy = _buildF11Policy();
  final policyStore = HostPolicyStore(
    policyFile: paths.policyFile,
    logger: logger,
  );
  await policyStore.savePolicy(policy);

  final phonePrivate = Uint8List.fromList(
    List<int>.generate(32, (i) => (i + 31) & 0xff),
  );
  final phonePublic = deriveP256PublicKey(phonePrivate);
  final enrollment = EnrollmentStateStore(stateFile: paths.enrollmentStateFile);
  await enrollment.save(hostId: _hostId, alias: 'Mac F11 Test');
  await enrollment.updatePhonePublicKeys(<String>[base64.encode(phonePublic)]);

  var virtualNowMs = 0;
  final recordedDelaysMs = <int>[];
  final channel = _ScriptedNativeChannel()
    ..activeWindowContextResult = const ActiveWindowContextSnapshot(
      appName: 'Notes',
      processName: 'com.apple.Notes',
      windowTitle: 'Notes',
      focusedRole: 'AXSearchField',
      exactFocusedRole: 'searchfield',
      visibleText: '',
    );
  final stop = EmergencyStopController(logger: logger);
  final scanner = AutoAppScanner(
    scanFileSystem: false,
    seedApps: const <DiscoveredApp>[
      DiscoveredApp(
        id: 'notes',
        name: 'Notes',
        kind: AppLaunchKind.bundle,
        target: 'com.apple.Notes',
        bundleId: 'com.apple.Notes',
      ),
      DiscoveredApp(
        id: 'spotify',
        name: 'Spotify',
        kind: AppLaunchKind.bundle,
        target: 'com.spotify.client',
        bundleId: 'com.spotify.client',
      ),
      DiscoveredApp(
        id: 'safari',
        name: 'Safari',
        kind: AppLaunchKind.bundle,
        target: 'com.apple.Safari',
        bundleId: 'com.apple.Safari',
      ),
    ],
  );
  final provider =
      buildProvider?.call(channel) ??
      NativeHostChannelComputerUseProvider(
        channel: channel,
        enableNativePointerAndCapture: true,
      );
  final manager = ComputerUseSessionManager(
    provider: provider,
    stopController: stop,
    appScanner: scanner,
    monotonicNowMs: () => virtualNowMs,
    settleDelay: (Duration d) async {
      recordedDelaysMs.add(d.inMilliseconds);
      virtualNowMs += d.inMilliseconds;
    },
  );
  final dispatcher = HostToolDispatcher(
    policyStore: policyStore,
    channel: channel,
    auditStore: AuditLogStore(auditDir: paths.auditDir),
    stopController: stop,
    logger: logger,
    enrollmentStore: enrollment,
    computerUseManager: manager,
    appScanner: scanner,
  );

  return (
    tempDir: tempDir,
    policy: policy,
    channel: channel,
    manager: manager,
    dispatcher: dispatcher,
    nowMs: virtualNowMs,
    setNowMs: (int ms) => virtualNowMs = ms,
    recordedDelaysMs: recordedDelaysMs,
    dispose: () async {
      dispatcher.dispose();
      await tempDir.delete(recursive: true);
    },
  );
}

void main() {
  group('F11 — 800ms Preflight->Execute Cache & ADR-0015 Live Safety', () {
    test(
      'Native provider: cache hit at 799ms avoids duplicate inspectWindowUiTree & runs readActiveWindowContext:200; expires at 800ms',
      () async {
        final h = await _createF11Harness();
        try {
          await h.manager.startSession(
            goal: 'Cache hit test',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);
          final baseInspects = h.channel.inspectUiTreeCount;

          // Preflight at t=0
          h.setNowMs(0);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
          );
          expect(h.channel.inspectUiTreeCount, equals(baseInspects + 1));

          // Execute at t=799 (< 800ms) -> cache hit for beforeWindow!
          // Post-action immediate + 1 settle poll = 2 inspect calls (total +3 vs +4 without cache).
          h.setNowMs(799);
          final ctxCountBefore = h.channel.readContext200Count;
          final execRes = await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
            hasR3Approval: false,
          );
          expect(execRes['route'], equals('semantic_headless'));
          expect(h.channel.readContext200Count, equals(ctxCountBefore + 1));
          expect(h.channel.inspectUiTreeCount, equals(baseInspects + 3));

          // Preflight again at t=1000 on e1, execute at t=1800 (>= 800ms) -> cache expired!
          h.setNowMs(1000);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e1'},
          );
          final inspectsAfterSecondPreflight = h.channel.inspectUiTreeCount;
          h.setNowMs(1800);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e1'},
            hasR3Approval: false,
          );
          // Fresh beforeWindow (+1) + immediate afterWindow (+1) + 1 settle poll (+1) = +3
          expect(
            h.channel.inspectUiTreeCount,
            equals(inspectsAfterSecondPreflight + 3),
          );
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'FallbackUiaAxComputerUseProvider: cache hit at 799ms avoids duplicate beforeWindow inspect',
      () async {
        late _CountingFallbackProvider fb;
        final h = await _createF11Harness(
          buildProvider: (_) {
            fb = _CountingFallbackProvider(
              initialWindow: const ActiveWindowObservation(
                appId: 'notes',
                processName: 'Notes',
                windowTitle: 'Notes',
                focusedRole: 'searchfield',
                nodes: <Map<String, Object?>>[
                  <String, Object?>{
                    'id': 'ui_1',
                    'role': 'button',
                    'name': 'Mở',
                    'enabled': true,
                  },
                ],
              ),
            );
            return fb;
          },
        );
        try {
          await h.manager.startSession(
            goal: 'Fallback cache hit',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);
          final baseInspects = fb.inspectCalls;

          h.setNowMs(0);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e1'},
          );
          expect(fb.inspectCalls, equals(baseInspects + 1));

          h.setNowMs(799);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e1'},
            hasR3Approval: false,
          );
          // beforeWindow skipped via cache; only post-action immediate + 1 settle poll = +2
          expect(fb.inspectCalls, equals(baseInspects + 3));
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'Spotify/Safari overridden windowTitle still hits cache via contextWindowTitle',
      () async {
        final h = await _createF11Harness();
        try {
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: 'Spotify',
                processName: 'com.spotify.client',
                windowTitle: 'Spotify',
                focusedRole: 'AXSearchField',
                exactFocusedRole: 'searchfield',
                visibleText: '',
              );
          h.channel.treeWindowTitleOverride = 'Spotify — Lofi Beats (playing)';

          await h.manager.startSession(
            goal: 'Spotify title cache',
            apps: const <String>['spotify'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);

          h.setNowMs(0);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
          );
          final afterPreflight = h.channel.inspectUiTreeCount;

          h.setNowMs(400);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
            hasR3Approval: false,
          );
          // Should hit cache despite windowTitle != ctx.windowTitle (+2 post-action only, NOT +3).
          expect(h.channel.inspectUiTreeCount, equals(afterPreflight + 2));
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'ADR-0015 live safety checks on native <800ms cache hit refuse password, elevated, hard-denied, outside-allowlist, and invalidate on focus/title shift',
      () async {
        final h = await _createF11Harness();
        try {
          await h.manager.startSession(
            goal: 'Safety check test',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 20,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);

          Future<void> warmPreflight() async {
            h.channel.activeWindowContextResult =
                const ActiveWindowContextSnapshot(
                  appName: 'Notes',
                  processName: 'com.apple.Notes',
                  windowTitle: 'Notes',
                  focusedRole: 'AXSearchField',
                  exactFocusedRole: 'searchfield',
                  visibleText: '',
                );
            h.setNowMs(0);
            await h.manager.preflightInputAction(
              toolName: 'input.click',
              arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
            );
          }

          // 1. Password focus shift
          await warmPreflight();
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: 'Notes',
                processName: 'com.apple.Notes',
                windowTitle: 'Notes',
                focusedRole: 'AXSecureTextField',
                exactFocusedRole: 'password',
                visibleText: '',
              );
          h.setNowMs(200);
          await expectLater(
            h.manager.executeInputAction(
              toolName: 'input.click',
              arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
              hasR3Approval: false,
            ),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'password_field_forbidden',
              ),
            ),
          );
          expect(h.channel.invokeControlCount, equals(0));

          // 2. Elevated window
          await warmPreflight();
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: 'Notes',
                processName: 'com.apple.Notes',
                windowTitle: 'Notes',
                focusedRole: 'AXSearchField',
                exactFocusedRole: 'searchfield',
                visibleText: '',
                isElevated: true,
              );
          h.setNowMs(200);
          await expectLater(
            h.manager.executeInputAction(
              toolName: 'input.click',
              arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
              hasR3Approval: false,
            ),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'elevated_window_forbidden',
              ),
            ),
          );

          // 3. Hard-denied app (1Password / Terminal)
          await warmPreflight();
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: '1Password',
                processName: 'com.1password.1password',
                windowTitle: 'Vault',
                focusedRole: 'AXWindow',
                visibleText: '',
              );
          h.setNowMs(200);
          await expectLater(
            h.manager.executeInputAction(
              toolName: 'input.click',
              arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
              hasR3Approval: false,
            ),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'denylisted_target_forbidden',
              ),
            ),
          );

          // 4. Outside allowlist
          await warmPreflight();
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: 'Calculator',
                processName: 'com.apple.calculator',
                windowTitle: 'Calculator',
                focusedRole: 'AXWindow',
                visibleText: '',
              );
          h.setNowMs(200);
          await expectLater(
            h.manager.executeInputAction(
              toolName: 'input.click',
              arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
              hasR3Approval: false,
            ),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'target_outside_allowlist',
              ),
            ),
          );

          // 5. Focus/title change within allowed app triggers fresh re-inspect (+3 vs +2)
          await warmPreflight();
          final afterPreflight = h.channel.inspectUiTreeCount;
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: 'Notes',
                processName: 'com.apple.Notes',
                windowTitle: 'Notes — Edited',
                focusedRole: 'AXButton',
                exactFocusedRole: 'button',
                visibleText: '',
              );
          h.setNowMs(200);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
            hasR3Approval: false,
          );
          expect(h.channel.inspectUiTreeCount, equals(afterPreflight + 3));
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'Cache invalidation occurs on inspectWindow, findElements, observeHybrid, inspectWindowForAppLaunch, startSession, endSession, and executeInputAction error finally',
      () async {
        final h = await _createF11Harness();
        try {
          await h.manager.startSession(
            goal: 'Invalidation test',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 20,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);

          h.channel.bumpTitleOnControlInvoke = true;
          Future<void> assertCacheInvalidatedBy(
            Future<void> Function() action, {
            String elementSuffix = 'e2',
          }) async {
            h.setNowMs(0);
            final preSnapId = h.manager.activeSession!.latestSnapshotId!;
            await h.manager.preflightInputAction(
              toolName: 'input.click',
              arguments: <String, Object?>{
                'elementId': '@$preSnapId:$elementSuffix',
              },
            );
            await action();
            final beforeExec = h.channel.inspectUiTreeCount;
            h.setNowMs(100);
            final snapId = h.manager.activeSession!.latestSnapshotId!;
            await h.manager.executeInputAction(
              toolName: 'input.click',
              arguments: <String, Object?>{
                'elementId': '@$snapId:$elementSuffix',
              },
              hasR3Approval: false,
            );
            // Cache missed -> beforeWindow (+1) + immediate (+1) + settle (+1) = +3
            expect(h.channel.inspectUiTreeCount, equals(beforeExec + 3));
          }

          await assertCacheInvalidatedBy(() async {
            await h.manager.inspectWindow(maxNodes: 20);
          }, elementSuffix: 'e2');
          await assertCacheInvalidatedBy(() async {
            await h.manager.findElements(query: 'Mở');
          }, elementSuffix: 'e1');
          await assertCacheInvalidatedBy(() async {
            await h.manager.observeHybrid(maxNodes: 20, maxEdge: 640);
          }, elementSuffix: 'e2');
          await assertCacheInvalidatedBy(() async {
            await h.manager.inspectWindowForAppLaunch(
              appId: 'notes',
              appName: 'Notes',
              target: 'com.apple.Notes',
            );
          }, elementSuffix: 'e1');

          // startSession and endSession invalidate cache too
          final oldSessionId = h.manager.activeSession!.sessionId;
          final oldSnapId = h.manager.activeSession!.latestSnapshotId!;
          h.setNowMs(0);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: <String, Object?>{'elementId': '@$oldSnapId:e2'},
          );
          await h.manager.endSession(
            sessionId: oldSessionId,
            outcome: 'completed',
          );
          await h.manager.startSession(
            goal: 'Fresh session after endSession',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);
          final beforeAfterRestart = h.channel.inspectUiTreeCount;
          h.setNowMs(100);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
            hasR3Approval: false,
          );
          expect(h.channel.inspectUiTreeCount, equals(beforeAfterRestart + 3));

          // Error in executeInputAction (approval_required on e3) must still clear cache via finally
          final snapId = h.manager.activeSession!.latestSnapshotId!;
          h.setNowMs(0);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: <String, Object?>{'elementId': '@$snapId:e2'},
          );
          h.setNowMs(100);
          await expectLater(
            h.manager.executeInputAction(
              toolName: 'input.click',
              arguments: <String, Object?>{'elementId': '@$snapId:e3'},
              hasR3Approval: false,
            ),
            throwsA(isA<XunaHostChannelException>()),
          );
          final beforeRetry = h.channel.inspectUiTreeCount;
          h.setNowMs(200);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: <String, Object?>{'elementId': '@$snapId:e2'},
            hasR3Approval: false,
          );
          expect(h.channel.inspectUiTreeCount, equals(beforeRetry + 3));
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'HostToolDispatcher.preflight classifies input.drag (password denied, consequential R3, safe R2) and warms cache',
      () async {
        final h = await _createF11Harness();
        try {
          await h.manager.startSession(
            goal: 'Drag preflight test',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);

          // 1. Password field hit -> denied (password_field_forbidden)
          h.setNowMs(0);
          final pwdResp = await h.dispatcher.preflight(
            requestId: 101,
            params: const PreflightParams(
              name: 'input.drag',
              arguments: <String, Object?>{
                'fromXNorm': 0.2,
                'fromYNorm': 0.35,
                'toXNorm': 0.2,
                'toYNorm': 0.75,
              },
            ),
          );
          final pwdPf = pwdResp.result['preflight']! as Map<String, Object?>;
          expect(pwdPf['status'], equals('denied'));
          expect(pwdPf['errorCode'], equals('password_field_forbidden'));

          // 2. Consequential drop target (ui_3 "Xóa tài khoản") -> R3
          h.setNowMs(100);
          final r3Resp = await h.dispatcher.preflight(
            requestId: 102,
            params: const PreflightParams(
              name: 'input.drag',
              arguments: <String, Object?>{
                'fromXNorm': 0.2,
                'fromYNorm': 0.15,
                'toXNorm': 0.2,
                'toYNorm': 0.55,
              },
            ),
          );
          final r3Pf = r3Resp.result['preflight']! as Map<String, Object?>;
          expect(r3Pf['status'], equals('ok'));
          expect(r3Pf['effectiveRisk'], equals('R3'));

          // 3. Safe target (ui_1 -> ui_2) -> R2 & warms <800ms cache
          h.setNowMs(200);
          final r2Resp = await h.dispatcher.preflight(
            requestId: 103,
            params: const PreflightParams(
              name: 'input.drag',
              arguments: <String, Object?>{
                'fromXNorm': 0.2,
                'fromYNorm': 0.15,
                'toXNorm': 0.2,
                'toYNorm': 0.35,
              },
            ),
          );
          final r2Pf = r2Resp.result['preflight']! as Map<String, Object?>;
          expect(r2Pf['status'], equals('ok'));
          expect(r2Pf['effectiveRisk'], equals('R2'));
          final inspectsAfterPreflight = h.channel.inspectUiTreeCount;

          // Executing drag at t=400ms (<800ms) reuses cached beforeWindow (+2 vs +3)
          h.setNowMs(400);
          await h.manager.executeInputAction(
            toolName: 'input.drag',
            arguments: const <String, Object?>{
              'fromXNorm': 0.2,
              'fromYNorm': 0.15,
              'toXNorm': 0.2,
              'toYNorm': 0.35,
            },
            hasR3Approval: false,
          );
          expect(
            h.channel.inspectUiTreeCount,
            equals(inspectsAfterPreflight + 2),
          );
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'F11-P4: browser domain allowlist re-checked on <800ms cache hit; disallowed domain throws domain_outside_allowlist with 0 control invocations and allowlisted URL change invalidates cache',
      () async {
        final h = await _createF11Harness();
        try {
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: 'Safari',
                processName: 'com.apple.Safari',
                windowTitle: 'Safari',
                focusedRole: 'AXButton',
                exactFocusedRole: 'button',
                visibleText: '',
              );
          h.channel.browserCurrentUrlResult = const BrowserTabSnapshot(
            url: 'https://example.com/safe',
            browser: 'safari',
          );

          await h.manager.startSession(
            goal: 'Browser cache security',
            apps: const <String>['safari'],
            domains: const <String>['example.com'],
            maxSteps: 20,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);

          // Warm preflight cache at t=0 on allowlisted https://example.com/safe
          h.setNowMs(0);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
          );
          final inspectsAfterPreflight = h.channel.inspectUiTreeCount;

          // Case 1: Redirect to disallowed domain within <800ms while windowTitle stays 'Safari'
          h.channel.browserCurrentUrlResult = const BrowserTabSnapshot(
            url: 'https://evil.example.org/phish',
            browser: 'safari',
          );
          h.setNowMs(200);
          await expectLater(
            h.manager.executeInputAction(
              toolName: 'input.click',
              arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
              hasR3Approval: false,
            ),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'domain_outside_allowlist',
              ),
            ),
          );
          expect(h.channel.invokeControlCount, equals(0));
          expect(h.channel.inspectUiTreeCount, equals(inspectsAfterPreflight));

          // Case 2: Re-warm cache on https://example.com/safe, then navigate to https://example.com/next
          // within <800ms while windowTitle stays 'Safari' -> must invalidate cache and re-inspect (+3)
          h.channel.browserCurrentUrlResult = const BrowserTabSnapshot(
            url: 'https://example.com/safe',
            browser: 'safari',
          );
          h.setNowMs(300);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
          );
          final inspectsAfterSecondPreflight = h.channel.inspectUiTreeCount;

          h.channel.browserCurrentUrlResult = const BrowserTabSnapshot(
            url: 'https://example.com/next',
            browser: 'safari',
          );
          h.setNowMs(500);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
            hasR3Approval: false,
          );
          // Cache invalidated due to URL change -> fresh before (+1) + immediate (+1) + settle (+1) = +3
          expect(
            h.channel.inspectUiTreeCount,
            equals(inspectsAfterSecondPreflight + 3),
          );
          expect(h.channel.invokeControlCount, equals(1));

          // Case 3: Same allowlisted URL within <800ms -> cache hits (+2)
          h.setNowMs(700);
          await h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e1'},
          );
          final inspectsAfterThirdPreflight = h.channel.inspectUiTreeCount;
          h.setNowMs(900);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e1'},
            hasR3Approval: false,
          );
          expect(
            h.channel.inspectUiTreeCount,
            equals(inspectsAfterThirdPreflight + 2),
          );
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'F11-P5 & F11-P6: input.drag enforces password/consequential/safe classification for fromElementId/toElementId and startXNorm/endXNorm across preflight and execute',
      () async {
        final h = await _createF11Harness();
        try {
          await h.manager.startSession(
            goal: 'Drag element ref & alias parity',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 20,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);

          // 1. F11-P5: fromElementId or toElementId targeting password node -> denied password_field_forbidden
          h.setNowMs(0);
          final pwdFromPfResp = await h.dispatcher.preflight(
            requestId: 201,
            params: const PreflightParams(
              name: 'input.drag',
              arguments: <String, Object?>{
                'fromElementId': '@s00000001:e4',
                'toElementId': '@s00000001:e2',
              },
            ),
          );
          final pwdFromPf =
              pwdFromPfResp.result['preflight']! as Map<String, Object?>;
          expect(pwdFromPf['status'], equals('denied'));
          expect(pwdFromPf['errorCode'], equals('password_field_forbidden'));

          final pwdToPfResp = await h.dispatcher.preflight(
            requestId: 202,
            params: const PreflightParams(
              name: 'input.drag',
              arguments: <String, Object?>{
                'fromElementId': '@s00000001:e1',
                'toElementId': '@s00000001:e4',
              },
            ),
          );
          final pwdToPf =
              pwdToPfResp.result['preflight']! as Map<String, Object?>;
          expect(pwdToPf['status'], equals('denied'));
          expect(pwdToPf['errorCode'], equals('password_field_forbidden'));

          // 2. F11-P5: safe -> consequential element drag -> R3 in preflight and requires approval on execute
          final r3ElemPfResp = await h.dispatcher.preflight(
            requestId: 203,
            params: const PreflightParams(
              name: 'input.drag',
              arguments: <String, Object?>{
                'fromElementId': '@s00000001:e1',
                'toElementId': '@s00000001:e3',
              },
            ),
          );
          final r3ElemPf =
              r3ElemPfResp.result['preflight']! as Map<String, Object?>;
          expect(r3ElemPf['status'], equals('ok'));
          expect(r3ElemPf['effectiveRisk'], equals('R3'));

          h.setNowMs(100);
          await expectLater(
            h.manager.executeInputAction(
              toolName: 'input.drag',
              arguments: const <String, Object?>{
                'fromElementId': '@s00000001:e1',
                'toElementId': '@s00000001:e3',
              },
              hasR3Approval: false,
            ),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'approval_required',
              ),
            ),
          );

          // 3. F11-P5: safe -> safe element drag -> R2 in preflight & executes drag_points via node bounds
          h.setNowMs(200);
          final r2ElemPfResp = await h.dispatcher.preflight(
            requestId: 204,
            params: const PreflightParams(
              name: 'input.drag',
              arguments: <String, Object?>{
                'fromElementId': '@s00000001:e1',
                'toElementId': '@s00000001:e2',
              },
            ),
          );
          final r2ElemPf =
              r2ElemPfResp.result['preflight']! as Map<String, Object?>;
          expect(r2ElemPf['status'], equals('ok'));
          expect(r2ElemPf['effectiveRisk'], equals('R2'));
          final inspectsAfterElemPreflight = h.channel.inspectUiTreeCount;

          h.setNowMs(400);
          final elemDragRes = await h.manager.executeInputAction(
            toolName: 'input.drag',
            arguments: const <String, Object?>{
              'fromElementId': '@s00000001:e1',
              'toElementId': '@s00000001:e2',
            },
            hasR3Approval: false,
          );
          expect(elemDragRes['effect'], isNotNull);
          expect(
            h.channel.invokedMethods.any(
              (m) => m == 'invokeWindowUiControl:drag_points:coord',
            ),
            isTrue,
          );
          expect(
            h.channel.inspectUiTreeCount,
            equals(inspectsAfterElemPreflight + 2),
          );

          // 4. F11-P6: startXNorm/startYNorm/endXNorm/endYNorm aliases -> R2 preflight & execute cleanly
          h.setNowMs(500);
          final aliasPfResp = await h.dispatcher.preflight(
            requestId: 205,
            params: const PreflightParams(
              name: 'input.drag',
              arguments: <String, Object?>{
                'startXNorm': 0.2,
                'startYNorm': 0.15,
                'endXNorm': 0.2,
                'endYNorm': 0.35,
              },
            ),
          );
          final aliasPf =
              aliasPfResp.result['preflight']! as Map<String, Object?>;
          expect(aliasPf['status'], equals('ok'));
          expect(aliasPf['effectiveRisk'], equals('R2'));

          h.setNowMs(700);
          final aliasExecRes = await h.manager.executeInputAction(
            toolName: 'input.drag',
            arguments: const <String, Object?>{
              'startXNorm': 0.2,
              'startYNorm': 0.15,
              'endXNorm': 0.2,
              'endYNorm': 0.35,
            },
            hasR3Approval: false,
          );
          expect(aliasExecRes['effect'], isNotNull);

          // 5. Fail-closed when element nodes lack bounds and no coordinates are given
          h.channel.treeNodes = <Map<String, Object?>>[
            <String, Object?>{
              'refId': 'ui_1',
              'role': 'AXButton',
              'label': 'NoBoundsA',
              'isPassword': false,
            },
            <String, Object?>{
              'refId': 'ui_2',
              'role': 'AXButton',
              'label': 'NoBoundsB',
              'isPassword': false,
            },
          ];
          await h.manager.inspectWindow(maxNodes: 20);
          final noBoundsSnap = h.manager.activeSession!.latestSnapshotId!;
          await expectLater(
            h.manager.executeInputAction(
              toolName: 'input.drag',
              arguments: <String, Object?>{
                'fromElementId': '@$noBoundsSnap:e1',
                'toElementId': '@$noBoundsSnap:e2',
              },
              hasR3Approval: false,
            ),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'drag_unsupported',
              ),
            ),
          );
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      '_preflightCacheEpoch prevents concurrent cache invalidation (findElements) from writing a stale preflight cache entry',
      () async {
        final h = await _createF11Harness();
        try {
          await h.manager.startSession(
            goal: 'Cache epoch interleaving test',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);

          h.setNowMs(0);
          h.channel.simulatedDelay = const Duration(milliseconds: 25);
          final preflightFuture = h.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
          );
          // While preflight awaits inspectWindowUiTree, run findElements which
          // invalidates cache & bumps _preflightCacheEpoch without changing snapshotId.
          await Future<void>.delayed(const Duration(milliseconds: 5));
          h.channel.simulatedDelay = Duration.zero;
          await h.manager.findElements(query: 'Mở');
          await preflightFuture;

          final snapId = h.manager.activeSession!.latestSnapshotId!;
          final inspectsBeforeExec = h.channel.inspectUiTreeCount;
          h.setNowMs(100);
          await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: <String, Object?>{'elementId': '@$snapId:e2'},
            hasR3Approval: false,
          );
          // Stale preflight entry must NOT have been cached -> fresh before (+1) + immediate (+1) + settle (+1) = +3
          expect(h.channel.inspectUiTreeCount, equals(inspectsBeforeExec + 3));
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      '_pollUiSettle polls at [120, 300] checkpoints capped at 600ms (2 polls max when unstable, 1 poll when stable)',
      () async {
        final h = await _createF11Harness();
        try {
          await h.manager.startSession(
            goal: 'Settle poll test',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          await h.manager.inspectWindow(maxNodes: 20);

          // Case A: Stable immediately -> 1 poll at 120ms, settled == true
          h.recordedDelaysMs.clear();
          h.channel.mutateNodesOnEachInspect = false;
          h.setNowMs(0);
          final stableRes = await h.manager.executeInputAction(
            toolName: 'input.click',
            arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
            hasR3Approval: false,
          );
          expect(h.recordedDelaysMs, equals(const <int>[120]));
          expect(stableRes['settled'], isTrue);
          expect(stableRes['settleMs'], equals(120));

          // Case B: Continually changing -> 2 polls ([120, 180] => t=120, t=300), settled == false, settleMs <= 600
          h.recordedDelaysMs.clear();
          h.channel.mutateNodesOnEachInspect = true;
          h.setNowMs(0);
          final unstableRes = await h.manager.executeInputAction(
            toolName: 'input.key',
            arguments: const <String, Object?>{'combo': 'Cmd+F'},
            hasR3Approval: false,
          );
          expect(h.recordedDelaysMs, equals(const <int>[120, 180]));
          expect(unstableRes['settled'], isFalse);
          expect(unstableRes['settleMs'], equals(300));
          expect(unstableRes['settleMs'] as int, lessThanOrEqualTo(600));
        } finally {
          await h.dispose();
        }
      },
    );
  });

  group('M0 Follow-up #1 — startSessionWithContext Non-Native Refusal', () {
    test(
      'FallbackUiaAxComputerUseProvider enforces domain_outside_allowlist on targetAlreadyFocused without blocking session start',
      () async {
        late FallbackUiaAxComputerUseProvider fb;
        final h = await _createF11Harness(
          buildProvider: (_) {
            fb = FallbackUiaAxComputerUseProvider(
              initialWindow: const ActiveWindowObservation(
                appId: 'safari',
                processName: 'Safari',
                windowTitle: 'Evil Page',
                browserUrl: 'https://evil.com/phish',
                nodes: <Map<String, Object?>>[
                  <String, Object?>{
                    'id': 'ui_1',
                    'role': 'button',
                    'name': 'Login',
                    'enabled': true,
                  },
                ],
              ),
            );
            return fb;
          },
        );
        try {
          final disallowed = await h.manager.startSessionWithContext(
            goal: 'Browse example.com only',
            apps: const <String>['safari'],
            domains: const <String>['example.com'],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          expect(disallowed.targetAlreadyFocused, isTrue);
          expect(disallowed.snapshotId, isNull);
          expect(disallowed.nodes, isNull);
          expect(h.manager.activeSession?.snapshotRefMaps, isEmpty);

          // Allowlisted domain mints snapshot & registers nodes cleanly
          fb.currentWindow = const ActiveWindowObservation(
            appId: 'safari',
            processName: 'Safari',
            windowTitle: 'Example Domain',
            browserUrl: 'https://example.com/home',
            nodes: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'ui_1',
                'role': 'button',
                'name': 'Docs',
                'enabled': true,
              },
            ],
          );
          final allowed = await h.manager.startSessionWithContext(
            goal: 'Browse example.com',
            apps: const <String>['safari'],
            domains: const <String>['example.com'],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );
          expect(allowed.targetAlreadyFocused, isTrue);
          expect(allowed.snapshotId, equals('s00000001'));
          expect(allowed.nodes, isNotNull);
          expect(h.manager.activeSession?.snapshotRefMaps, isNotEmpty);
        } finally {
          await h.dispose();
        }
      },
    );
  });

  group('M5 — Media Payload Dispatch & In-Flight Inspection Coalescing', () {
    test(
      'HostToolDispatcher dispatches >16 KiB JPEG via ui.observe_hybrid without silent drop and degrades oversized payloads cleanly',
      () async {
        final h = await _createF11Harness();
        try {
          await h.manager.startSession(
            goal: 'Observe media payload',
            apps: const <String>['notes'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: h.policy,
          );

          // 1. Realistic > 16 KiB base64 JPEG succeeds end-to-end through XtpFrame.encode()
          final validJpegB64 = 'A' * 65536;
          h.channel.overrideCaptureBase64 = validJpegB64;
          final okResp = await h.dispatcher.dispatch(
            requestId: 101,
            params: const ToolsCallParams(
              name: 'ui.observe_hybrid',
              arguments: <String, Object?>{
                'scope': 'active_window',
                'maxNodes': 60,
                'maxEdge': 960,
              },
              invocationId: 'inv-m5-media-ok',
              deadlineMs: 5000,
            ),
          );
          final metaOk = okResp.result['_meta']! as Map<String, Object?>;
          expect(metaOk['xuna/status'], equals('ok'));
          final scOk =
              okResp.result['structuredContent']! as Map<String, Object?>;
          expect(scOk.containsKey('image'), isFalse);
          final shot = scOk['screenshot']! as Map<String, Object?>;
          expect(shot['dataBase64'], equals(validJpegB64));
          final encoded = okResp.encode();
          expect(encoded.length, greaterThan(65536));
          expect(encoded.length, lessThanOrEqualTo(maxXtpFrameBytes));

          // 2. Oversized payload (> maxMediaStructuredContentBytes) degrades to failed/payload_too_large and records audit
          h.channel.overrideCaptureBase64 =
              'B' * (maxMediaStructuredContentBytes + 1024);
          final failResp = await h.dispatcher.dispatch(
            requestId: 102,
            params: const ToolsCallParams(
              name: 'ui.observe_hybrid',
              arguments: <String, Object?>{
                'scope': 'active_window',
                'maxNodes': 60,
                'maxEdge': 960,
              },
              invocationId: 'inv-m5-media-fail',
              deadlineMs: 5000,
            ),
          );
          final metaFail = failResp.result['_meta']! as Map<String, Object?>;
          expect(metaFail['xuna/status'], equals('failed'));
          expect(metaFail['xuna/errorCode'], equals('payload_too_large'));
          expect(failResp.encode(), isNotEmpty);
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'NativeHostChannelComputerUseProvider coalesces concurrent in-flight inspectActiveWindow bursts with slicing, without caching sequential calls',
      () async {
        final h = await _createF11Harness();
        try {
          h.channel.treeNodes = List<Map<String, Object?>>.generate(
            10,
            (i) => <String, Object?>{
              'refId': 'ui_${i + 1}',
              'role': 'AXButton',
              'label': 'Button ${i + 1}',
              'isPassword': false,
            },
          );
          final provider = h.manager.provider;
          h.channel.simulatedDelay = const Duration(milliseconds: 25);

          final baseInspects = h.channel.inspectUiTreeCount;
          // 10-way concurrent burst starting with maxNodes: 10 -> all 10 share 1 live scan
          final burst = await Future.wait(<Future<ActiveWindowObservation>>[
            provider.inspectActiveWindow(maxNodes: 10),
            provider.inspectActiveWindow(maxNodes: 3),
            provider.inspectActiveWindow(maxNodes: 8),
            provider.inspectActiveWindow(maxNodes: 10),
            provider.inspectActiveWindow(maxNodes: 5),
            provider.inspectActiveWindow(maxNodes: 10),
            provider.inspectActiveWindow(maxNodes: 2),
            provider.inspectActiveWindow(maxNodes: 10),
            provider.inspectActiveWindow(maxNodes: 6),
            provider.inspectActiveWindow(maxNodes: 4),
          ]);
          expect(h.channel.inspectUiTreeCount, equals(baseInspects + 1));
          expect(burst[0].nodes.length, equals(10));
          expect(burst[1].nodes.length, equals(3));
          expect(burst[2].nodes.length, equals(8));
          expect(burst[6].nodes.length, equals(2));

          // Sequential calls must NOT use any cross-time cache
          h.channel.simulatedDelay = Duration.zero;
          await provider.inspectActiveWindow(maxNodes: 10);
          await provider.inspectActiveWindow(maxNodes: 10);
          expect(h.channel.inspectUiTreeCount, equals(baseInspects + 3));
        } finally {
          await h.dispose();
        }
      },
    );
  });
}
