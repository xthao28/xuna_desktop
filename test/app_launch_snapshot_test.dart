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

HostPolicy _buildF10Policy() => HostPolicy(
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
      id: 'vscode',
      name: 'Visual Studio Code',
      kind: AppLaunchKind.bundle,
      target: 'com.microsoft.VSCode',
      risk: RiskTier.r2,
    ),
  ],
  urlDomains: const <String>[],
  workflows: const <WorkflowConfig>[],
  players: const <String>[],
);

Future<
  ({
    Directory tempDir,
    FakeXunaHostChannel channel,
    ComputerUseSessionManager manager,
    HostToolDispatcher dispatcher,
    ApprovalToken Function(Map<String, Object?> args) signR3,
    Future<void> Function() dispose,
  })
>
_createF10Harness({
  required ComputerUseProvider Function(FakeXunaHostChannel channel)
  buildProvider,
  bool wireCuManager = true,
  Duration postLaunchInspectDelay = Duration.zero,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('xuna_f10_test_');
  final paths = AgentPaths.resolve(overrideRootDir: tempDir);
  await paths.ensureDirectories();

  final logger = ContentFreeLogger();
  final policyStore = HostPolicyStore(
    policyFile: paths.policyFile,
    logger: logger,
  );
  await policyStore.savePolicy(_buildF10Policy());

  final phonePrivate = Uint8List.fromList(
    List<int>.generate(32, (i) => (i + 71) & 0xff),
  );
  final phonePublic = deriveP256PublicKey(phonePrivate);

  final enrollment = EnrollmentStateStore(stateFile: paths.enrollmentStateFile);
  await enrollment.save(hostId: _hostId, alias: 'Mac F10 Test');
  await enrollment.updatePhonePublicKeys(<String>[base64.encode(phonePublic)]);

  final channel = FakeXunaHostChannel();
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
        id: 'vscode',
        name: 'Visual Studio Code',
        kind: AppLaunchKind.bundle,
        target: 'com.microsoft.VSCode',
        bundleId: 'com.microsoft.VSCode',
      ),
    ],
  );
  final manager = ComputerUseSessionManager(
    provider: buildProvider(channel),
    stopController: stop,
    appScanner: scanner,
  );

  final customHandlers = <HostToolHandler>[
    for (final h in defaultMvpToolHandlers)
      if (h is AppLaunchTool)
        AppLaunchTool(postLaunchInspectDelay: postLaunchInspectDelay)
      else
        h,
    if (wireCuManager) ...manager.buildHandlers(),
  ];

  final dispatcher = HostToolDispatcher(
    policyStore: policyStore,
    channel: channel,
    auditStore: AuditLogStore(auditDir: paths.auditDir),
    stopController: stop,
    logger: logger,
    enrollmentStore: enrollment,
    computerUseManager: wireCuManager ? manager : null,
    appScanner: scanner,
    handlers: customHandlers,
  );

  var rpcCounter = 1;
  ApprovalToken signR3(Map<String, Object?> args) {
    final idNum = rpcCounter++;
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    final expiresWire = expiresAt.toIso8601String();
    final approvalId =
        'f${idNum.toString().padLeft(7, '0')}-4444-4444-8888-111111111111';
    final sha = argsSha256(args);
    final sig = signP256Deterministic(
      privateScalar32: phonePrivate,
      message: approvalProofMessage(
        approvalId: approvalId,
        argsSha256: sha,
        hostId: _hostId,
        expiresAt: expiresWire,
      ),
    );
    return ApprovalToken(
      approvalId: approvalId,
      argsSha256: sha,
      expiresAt: expiresAt,
      expiresAtRaw: expiresWire,
      signature: sig,
      publicKey: phonePublic,
    );
  }

  return (
    tempDir: tempDir,
    channel: channel,
    manager: manager,
    dispatcher: dispatcher,
    signR3: signR3,
    dispose: () async {
      dispatcher.dispose();
      await tempDir.delete(recursive: true);
    },
  );
}

void main() {
  group('F10 — app.launch Snapshot Registration & Zero stale_ref', () {
    test(
      'NativeHostChannelComputerUseProvider: cu.session_start (not focused) -> app.launch -> input.click succeeds with zero stale_ref',
      () async {
        final h = await _createF10Harness(
          buildProvider: (ch) =>
              NativeHostChannelComputerUseProvider(channel: ch),
        );
        try {
          // Initially another app (Finder) is focused so cu.session_start does not mint s00000001.
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: 'Finder',
                processName: 'com.apple.finder',
                windowTitle: 'Desktop',
                focusedRole: 'AXGroup',
                visibleText: '',
                isElevated: false,
              );

          final now = DateTime.now().toUtc();
          const startArgs = <String, Object?>{
            'goal': 'Open Notes and play/click control',
            'apps': <String>['notes'],
            'domains': <String>[],
            'maxSteps': 10,
            'maxMinutes': 5,
          };
          final startResp = await h.dispatcher.dispatch(
            requestId: 1,
            params: ToolsCallParams(
              name: 'cu.session_start',
              arguments: startArgs,
              invocationId: 'inv-f10-start-1',
              deadlineMs: 5000,
              approval: h.signR3(startArgs),
            ),
            nowUtc: now,
          );
          final startSc =
              startResp.result['structuredContent'] as Map<String, Object?>;
          expect(startSc['targetAlreadyFocused'], isFalse);
          expect(h.manager.activeSession?.latestSnapshotId, isNull);

          // Simulate macOS switching foreground to Notes once app.launch runs.
          h.channel.activeWindowContextResult =
              const ActiveWindowContextSnapshot(
                appName: 'Notes',
                processName: 'com.apple.Notes',
                windowTitle: 'Ghi chú — token=sk-secret998877665544',
                focusedRole: 'AXTextField',
                exactFocusedRole: 'textfield',
                visibleText: '',
                isElevated: false,
              );
          h.channel.appLaunchAlreadyRunningResult = true;

          final launchResp = await h.dispatcher.dispatch(
            requestId: 2,
            params: const ToolsCallParams(
              name: 'app.launch',
              arguments: <String, Object?>{'id': 'notes'},
              invocationId: 'inv-f10-launch-1',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final launchMeta = launchResp.result['_meta'] as Map<String, Object?>;
          expect(launchMeta['xuna/status'], equals('ok'));

          final launchSc =
              launchResp.result['structuredContent'] as Map<String, Object?>;
          expect(launchSc['alreadyRunning'], isTrue);
          expect(launchSc['snapshotId'], equals('s00000001'));
          expect(
            launchSc['windowTitle'] as String,
            isNot(contains('sk-secret')),
          );
          final nodes = (launchSc['nodes'] as List)
              .cast<Map<String, Object?>>();
          expect(nodes.length, equals(4));
          expect(nodes[0]['ref'], equals('@s00000001:e1'));
          expect(nodes[1]['ref'], equals('@s00000001:e2'));
          // Password field redacted
          expect(nodes[3]['role'], equals('password'));
          expect(nodes[3]['name'], equals('•••'));
          expect(nodes[3].containsKey('value'), isFalse);

          final compactTree = launchSc['compactUiTree'] as String;
          expect(compactTree, contains('@s00000001:e2'));
          expect(compactTree, isNot(contains('ui_')));
          expect(
            launchSc['nextStepHint'] as String,
            isNot(contains('accessibility_tree')),
          );

          // Immediately click the returned node ref — must NOT return stale_ref.
          final clickResp = await h.dispatcher.dispatch(
            requestId: 3,
            params: const ToolsCallParams(
              name: 'input.click',
              arguments: <String, Object?>{'elementId': '@s00000001:e2'},
              invocationId: 'inv-f10-click-1',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final clickMeta = clickResp.result['_meta'] as Map<String, Object?>;
          expect(clickMeta['xuna/status'], equals('ok'));
          expect(clickMeta['xuna/errorCode'], isNull);
          expect(
            h.channel.invokedMethods,
            contains('invokeWindowUiControl:invoke_ref:ui_2'),
          );
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'FallbackUiaAxComputerUseProvider: app.launch registers nodes into active session & input.click succeeds',
      () async {
        late FallbackUiaAxComputerUseProvider fallbackProvider;
        final h = await _createF10Harness(
          buildProvider: (_) {
            fallbackProvider = FallbackUiaAxComputerUseProvider(
              initialWindow: const ActiveWindowObservation(
                appId: 'notes',
                processName: 'Notes',
                windowTitle: 'Notes Window',
                nodes: <Map<String, Object?>>[
                  <String, Object?>{
                    'id': 'ui_1',
                    'role': 'button',
                    'name': 'New Note',
                    'enabled': true,
                  },
                  <String, Object?>{
                    'id': 'ui_2',
                    'role': 'textfield',
                    'name': 'Search Notes',
                    'enabled': true,
                    'editable': true,
                  },
                ],
              ),
            );
            return fallbackProvider;
          },
        );
        try {
          final now = DateTime.now().toUtc();
          const startArgs = <String, Object?>{
            'goal': 'Use Notes via Fallback provider',
            'apps': <String>['notes'],
            'domains': <String>[],
            'maxSteps': 10,
            'maxMinutes': 5,
          };
          await h.dispatcher.dispatch(
            requestId: 10,
            params: ToolsCallParams(
              name: 'cu.session_start',
              arguments: startArgs,
              invocationId: 'inv-f10-fb-start',
              deadlineMs: 5000,
              approval: h.signR3(startArgs),
            ),
            nowUtc: now,
          );
          expect(
            h.manager.activeSession?.latestSnapshotId,
            equals('s00000001'),
          );

          final launchResp = await h.dispatcher.dispatch(
            requestId: 11,
            params: const ToolsCallParams(
              name: 'app.launch',
              arguments: <String, Object?>{'id': 'notes'},
              invocationId: 'inv-f10-fb-launch',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final launchSc =
              launchResp.result['structuredContent'] as Map<String, Object?>;
          expect(launchSc['snapshotId'], equals('s00000002'));
          final nodes = (launchSc['nodes'] as List)
              .cast<Map<String, Object?>>();
          expect(nodes.first['ref'], equals('@s00000002:e1'));

          final clickResp = await h.dispatcher.dispatch(
            requestId: 12,
            params: ToolsCallParams(
              name: 'input.click',
              arguments: <String, Object?>{'elementId': nodes.first['ref']},
              invocationId: 'inv-f10-fb-click',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          expect(
            (clickResp.result['_meta'] as Map<String, Object?>)['xuna/status'],
            equals('ok'),
          );
        } finally {
          await h.dispose();
        }
      },
    );

    test(
      'No active CU session (both computerUseManager == null and hasActiveSession == false): omits snapshotId, nodes, compactUiTree (zero orphan ui_N)',
      () async {
        for (final wireCu in const <bool>[false, true]) {
          final h = await _createF10Harness(
            wireCuManager: wireCu,
            buildProvider: (ch) =>
                NativeHostChannelComputerUseProvider(channel: ch),
          );
          try {
            final now = DateTime.now().toUtc();
            const args = <String, Object?>{'id': 'notes'};
            final resp = await h.dispatcher.dispatch(
              requestId: 20,
              params: ToolsCallParams(
                name: 'app.launch',
                arguments: args,
                invocationId: 'inv-f10-no-cu-$wireCu',
                deadlineMs: 5000,
                approval: ApprovalToken(
                  approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c11',
                  argsSha256: argsSha256(args),
                  expiresAt: now.add(const Duration(minutes: 5)),
                ),
              ),
              nowUtc: now,
            );
            final meta = resp.result['_meta'] as Map<String, Object?>;
            expect(meta['xuna/status'], equals('ok'));
            final sc = resp.result['structuredContent'] as Map<String, Object?>;
            expect(sc['id'], equals('notes'));
            expect(sc.containsKey('alreadyRunning'), isTrue);
            expect(sc.containsKey('snapshotId'), isFalse);
            expect(sc.containsKey('nodes'), isFalse);
            expect(sc.containsKey('compactUiTree'), isFalse);
            expect(sc.containsKey('windowTitle'), isFalse);
            final hint = (sc['nextStepHint'] as String?) ?? '';
            expect(hint, isNot(matches(RegExp(r'\bui_[0-9]+\b'))));
            expect(hint, isNot(contains('@s')));
          } finally {
            await h.dispose();
          }
        }
      },
    );

    test(
      'Fail-closed: elevated, hard-denied, or mismatched foreground window omits snapshotId/nodes/compactUiTree without leaking cross-app UI',
      () async {
        final h = await _createF10Harness(
          buildProvider: (ch) =>
              NativeHostChannelComputerUseProvider(channel: ch),
        );
        try {
          final now = DateTime.now().toUtc();
          const startArgs = <String, Object?>{
            'goal': 'Test fail-closed app.launch',
            'apps': <String>['notes', 'vscode'],
            'domains': <String>[],
            'maxSteps': 10,
            'maxMinutes': 5,
          };
          await h.dispatcher.dispatch(
            requestId: 30,
            params: ToolsCallParams(
              name: 'cu.session_start',
              arguments: startArgs,
              invocationId: 'inv-f10-fc-start',
              deadlineMs: 5000,
              approval: h.signR3(startArgs),
            ),
            nowUtc: now,
          );

          final badContexts = <ActiveWindowContextSnapshot>[
            // 1. Elevated
            const ActiveWindowContextSnapshot(
              appName: 'Notes',
              processName: 'com.apple.Notes',
              windowTitle: 'Notes Admin',
              focusedRole: 'AXWindow',
              visibleText: '',
              isElevated: true,
            ),
            // 2. Hard-denied (1Password)
            const ActiveWindowContextSnapshot(
              appName: '1Password',
              processName: 'com.1password.1password',
              windowTitle: 'Vault',
              focusedRole: 'AXWindow',
              visibleText: '',
              isElevated: false,
            ),
            // 3. Different app (VS Code focused while launching Notes)
            const ActiveWindowContextSnapshot(
              appName: 'Visual Studio Code',
              processName: 'com.microsoft.VSCode',
              windowTitle: 'main.dart',
              focusedRole: 'AXTextArea',
              visibleText: '',
              isElevated: false,
            ),
          ];

          var reqId = 31;
          for (final ctx in badContexts) {
            h.channel.activeWindowContextResult = ctx;
            final resp = await h.dispatcher.dispatch(
              requestId: reqId++,
              params: ToolsCallParams(
                name: 'app.launch',
                arguments: const <String, Object?>{'id': 'notes'},
                invocationId: 'inv-f10-fc-$reqId',
                deadlineMs: 5000,
              ),
              nowUtc: now,
            );
            final meta = resp.result['_meta'] as Map<String, Object?>;
            expect(meta['xuna/status'], equals('ok'));
            final sc = resp.result['structuredContent'] as Map<String, Object?>;
            expect(sc.containsKey('snapshotId'), isFalse);
            expect(sc.containsKey('nodes'), isFalse);
            expect(sc.containsKey('compactUiTree'), isFalse);
          }
          expect(h.manager.activeSession?.latestSnapshotId, isNull);
        } finally {
          await h.dispose();
        }
      },
    );
  });
}
