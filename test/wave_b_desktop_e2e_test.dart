import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/browser_bridge/fake_browser_engine_provider.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/native_bridge/fake_native_app_bridge.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

const String _testHostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';

HostPolicy _buildWaveBTestPolicy() => HostPolicy(
      schemaVersion: 1,
      trustPreset: TrustPreset.standard,
      families: const <ToolFamily, FamilyPolicyDecision>{
        ToolFamily.app: FamilyPolicyDecision.allow,
        ToolFamily.files: FamilyPolicyDecision.allow,
        ToolFamily.workflow: FamilyPolicyDecision.allow,
        ToolFamily.url: FamilyPolicyDecision.allow,
        ToolFamily.host: FamilyPolicyDecision.allow,
        ToolFamily.cu: FamilyPolicyDecision.allow,
        ToolFamily.screen: FamilyPolicyDecision.allow,
        ToolFamily.ui: FamilyPolicyDecision.allow,
        ToolFamily.input: FamilyPolicyDecision.allow,
      },
      apps: const <AllowedAppConfig>[],
      urlDomains: const <String>[
        'example.com',
        'shop.vietnam.vn',
        'portal.company.com',
      ],
      workflows: const <WorkflowConfig>[],
      players: const <String>[],
    );

class WaveBDesktopE2ETestHarness {
  WaveBDesktopE2ETestHarness._({
    required this.tempDir,
    required this.dispatcher,
    required this.nativeBridge,
    required this.browserEngine,
    required this.policyStore,
    required this.enrollmentStore,
    required this.stopController,
    required this.logger,
    required this.phonePrivate,
    required this.phonePublic,
  });

  final Directory tempDir;
  final HostToolDispatcher dispatcher;
  final FakeNativeAppBridge nativeBridge;
  final FakeBrowserEngineProvider browserEngine;
  final HostPolicyStore policyStore;
  final EnrollmentStateStore enrollmentStore;
  final EmergencyStopController stopController;
  final ContentFreeLogger logger;
  final Uint8List phonePrivate;
  final Uint8List phonePublic;
  int _rpcId = 1;

  static Future<WaveBDesktopE2ETestHarness> create({
    HostPolicy? policy,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('xuna_wave_b_e2e_');
    final paths = AgentPaths.resolve(overrideRootDir: tempDir);
    await paths.ensureDirectories();

    final logger = ContentFreeLogger();
    final policyStore = HostPolicyStore(
      policyFile: paths.policyFile,
      logger: logger,
    );
    await policyStore.savePolicy(policy ?? _buildWaveBTestPolicy());

    final phonePrivate = Uint8List.fromList(
      List<int>.generate(32, (i) => (i + 77) & 0xff),
    );
    final phonePublic = deriveP256PublicKey(phonePrivate);

    final enrollment = EnrollmentStateStore(
      stateFile: paths.enrollmentStateFile,
    );
    await enrollment.save(hostId: _testHostId, alias: 'Desktop Wave B E2E Host');
    await enrollment.updatePhonePublicKeys(<String>[
      base64.encode(phonePublic),
    ]);

    final stop = EmergencyStopController(logger: logger);
    final nativeBridge = FakeNativeAppBridge();
    final browserEngine = FakeBrowserEngineProvider();

    final dispatcher = HostToolDispatcher(
      policyStore: policyStore,
      channel: FakeXunaHostChannel(),
      auditStore: AuditLogStore(auditDir: paths.auditDir),
      stopController: stop,
      logger: logger,
      enrollmentStore: enrollment,
      nativeAppBridge: nativeBridge,
      browserEngineProvider: browserEngine,
    );

    return WaveBDesktopE2ETestHarness._(
      tempDir: tempDir,
      dispatcher: dispatcher,
      nativeBridge: nativeBridge,
      browserEngine: browserEngine,
      policyStore: policyStore,
      enrollmentStore: enrollment,
      stopController: stop,
      logger: logger,
      phonePrivate: phonePrivate,
      phonePublic: phonePublic,
    );
  }

  ApprovalToken signedR3Approval(Map<String, Object?> args) {
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    final expiresWire = expiresAt.toIso8601String();
    final approvalId = 'a${_rpcId.toString().padLeft(7, '0')}-4444-4444-8888-111111111111';
    final sha = argsSha256(args);
    final sig = signP256Deterministic(
      privateScalar32: phonePrivate,
      message: approvalProofMessage(
        approvalId: approvalId,
        argsSha256: sha,
        hostId: _testHostId,
        expiresAt: expiresWire,
      ),
    );
    return ApprovalToken(
      approvalId: approvalId,
      scope: 'once',
      argsSha256: sha,
      expiresAt: expiresAt,
      expiresAtRaw: expiresWire,
      signature: sig,
      publicKey: phonePublic,
    );
  }

  ApprovalToken standardR2Approval(Map<String, Object?> args) {
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    return ApprovalToken(
      approvalId: 'b${_rpcId.toString().padLeft(7, '0')}-4111-8111-8888-1234567890ab',
      scope: 'once',
      argsSha256: argsSha256(args),
      expiresAt: expiresAt,
    );
  }

  Future<XtpResponse> dispatchFull(
    String tool,
    Map<String, Object?> args, {
    ApprovalToken? approval,
    String? invocationId,
    int deadlineMs = 5000,
  }) async {
    final invId = invocationId ??
        'inv-${_rpcId.toString().padLeft(6, '0')}-4111-8111-1234567890ab';
    return dispatcher.dispatch(
      requestId: _rpcId++,
      params: ToolsCallParams(
        name: tool,
        arguments: args,
        invocationId: invId,
        deadlineMs: deadlineMs,
        approval: approval,
      ),
    );
  }

  Future<Map<String, Object?>> dispatch(
    String tool,
    Map<String, Object?> args, {
    ApprovalToken? approval,
    String? invocationId,
    int deadlineMs = 5000,
  }) async {
    final response = await dispatchFull(
      tool,
      args,
      approval: approval,
      invocationId: invocationId,
      deadlineMs: deadlineMs,
    );
    return (response.result['_meta'] as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> dispatchStructured(
    String tool,
    Map<String, Object?> args, {
    ApprovalToken? approval,
    String? invocationId,
    int deadlineMs = 5000,
  }) async {
    final response = await dispatchFull(
      tool,
      args,
      approval: approval,
      invocationId: invocationId,
      deadlineMs: deadlineMs,
    );
    final raw = response.result['structuredContent'];
    if (raw is Map) {
      return raw.cast<String, Object?>();
    }
    return const <String, Object?>{};
  }

  Future<void> dispose() async {
    dispatcher.dispose();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Wave B Desktop E2E Integration Suite', () {
    // =========================================================================
    // Tier 1: Host & Bridge Integration (Happy Paths)
    // =========================================================================

    group('Tier 1 - Host & Bridge Integration', () {
      test('T1-NAT.1: Complete 1-step Native Notes Workflow (create -> search -> append -> search)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // 1. Create note (R2 mutating)
          const createArgs = <String, Object?>{
            'title': 'Meeting Notes',
            'body': 'Initial thoughts on Wave B architecture.',
            'folder': 'Work',
          };
          final createRes = await harness.dispatchFull(
            'notes.create',
            createArgs,
            approval: harness.standardR2Approval(createArgs),
          );
          final createMeta = (createRes.result['_meta'] as Map).cast<String, Object?>();
          final createStructured = (createRes.result['structuredContent'] as Map).cast<String, Object?>();
          expect(createMeta['xuna/status'], equals('ok'));
          expect(createStructured['id'], equals('note-1'));
          expect(createStructured['title'], equals('Meeting Notes'));

          // 2. Search notes (R1 read)
          const searchArgs = <String, Object?>{'query': 'Meeting'};
          final searchRes = await harness.dispatchFull(
            'notes.search',
            searchArgs,
          );
          final searchMeta = (searchRes.result['_meta'] as Map).cast<String, Object?>();
          final searchStructured = (searchRes.result['structuredContent'] as Map).cast<String, Object?>();
          expect(searchMeta['xuna/status'], equals('ok'));
          expect(searchStructured['total'], equals(1));
          final notesList = (searchStructured['notes'] as List).cast<Map<String, Object?>>();
          expect(notesList.first['title'], equals('Meeting Notes'));

          // 3. Append to note (R2 mutating)
          const appendArgs = <String, Object?>{
            'id': 'note-1',
            'text': '\nFollow-up action items completed.',
          };
          final appendRes = await harness.dispatchFull(
            'notes.append',
            appendArgs,
            approval: harness.standardR2Approval(appendArgs),
          );
          final appendMeta = (appendRes.result['_meta'] as Map).cast<String, Object?>();
          final appendStructured = (appendRes.result['structuredContent'] as Map).cast<String, Object?>();
          expect(appendMeta['xuna/status'], equals('ok'));
          expect(appendStructured['appended'], isTrue);

          // 4. Verify appended content via search and underlying bridge
          final searchAfterRes = await harness.dispatchStructured(
            'notes.search',
            searchArgs,
          );
          expect(searchAfterRes['total'], equals(1));
          expect(harness.nativeBridge.notes.first['body'], contains('Follow-up action items completed.'));

          // Verify all 4 calls recorded in fake bridge
          expect(harness.nativeBridge.recordedCalls.length, equals(4));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-NAT.2: Complete Native Calendar Workflow (list -> create -> list)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // 1. Initial list events returns empty
          const listArgs = <String, Object?>{
            'timeMin': '2026-11-20T00:00:00Z',
            'timeMax': '2026-11-20T23:59:59Z',
          };
          final initialList = await harness.dispatchStructured(
            'calendar.list_events',
            listArgs,
          );
          expect(initialList['total'], equals(0));
          expect((initialList['events'] as List), isEmpty);

          // 2. Create calendar event (R2 mutating)
          const createArgs = <String, Object?>{
            'title': 'Product Sync',
            'startTime': '2026-11-20T10:00:00Z',
            'endTime': '2026-11-20T11:00:00Z',
            'location': 'HQ 4F',
            'notes': 'Wave B review',
            'calendarName': 'Work',
          };
          final createRes = await harness.dispatchFull(
            'calendar.create_event',
            createArgs,
            approval: harness.standardR2Approval(createArgs),
          );
          final createMeta = (createRes.result['_meta'] as Map).cast<String, Object?>();
          final createStructured = (createRes.result['structuredContent'] as Map).cast<String, Object?>();
          expect(createMeta['xuna/status'], equals('ok'));
          expect(createStructured['id'], equals('evt-1'));
          expect(createStructured['title'], equals('Product Sync'));

          // 3. List events again: 1 event found
          final updatedList = await harness.dispatchStructured(
            'calendar.list_events',
            listArgs,
          );
          expect(updatedList['total'], equals(1));
          final events = (updatedList['events'] as List).cast<Map<String, Object?>>();
          expect(events.first['title'], equals('Product Sync'));
          expect(events.first['location'], equals('HQ 4F'));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-NAT.3: Native Reminders Workflow (create with due date & priority)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const reminderArgs = <String, Object?>{
            'title': 'Review Pull Request',
            'list': 'Engineering',
            'dueDate': '2026-11-21T18:00:00Z',
            'priority': 1,
            'notes': 'Verify all test suites pass.',
          };
          final res = await harness.dispatchFull(
            'reminders.create',
            reminderArgs,
            approval: harness.standardR2Approval(reminderArgs),
          );
          final meta = (res.result['_meta'] as Map).cast<String, Object?>();
          final structured = (res.result['structuredContent'] as Map).cast<String, Object?>();
          expect(meta['xuna/status'], equals('ok'));
          expect(structured['id'], equals('rem-1'));
          expect(structured['title'], equals('Review Pull Request'));
          expect(structured['list'], equals('Engineering'));
          expect(harness.nativeBridge.reminders.length, equals(1));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-NAT.4: Native Finder Reveal Workflow (reveal valid path)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const revealArgs = <String, Object?>{
            'path': 'c:\\Users\\Thao\\Documents\\xuna_pet\\docs\\architecture',
          };
          final res = await harness.dispatchFull(
            'finder.reveal',
            revealArgs,
          );
          final meta = (res.result['_meta'] as Map).cast<String, Object?>();
          final structured = (res.result['structuredContent'] as Map).cast<String, Object?>();
          expect(meta['xuna/status'], equals('ok'));
          expect(structured['revealed'], isTrue);
          expect(structured['path'], equals(revealArgs['path']));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-NAT.5: Native Mail Draft Workflow (create draft at R2; draft-only invariant)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const draftArgs = <String, Object?>{
            'to': <String>['partner@example.com'],
            'cc': <String>['manager@example.com'],
            'subject': 'Draft Proposal',
            'body': 'Please review the attached notes.',
          };
          final res = await harness.dispatchFull(
            'mail.create_draft',
            draftArgs,
            approval: harness.standardR2Approval(draftArgs),
          );
          final meta = (res.result['_meta'] as Map).cast<String, Object?>();
          final structured = (res.result['structuredContent'] as Map).cast<String, Object?>();
          expect(meta['xuna/status'], equals('ok'));
          expect(structured['isDraft'], isTrue);
          expect(structured['subject'], equals('Draft Proposal'));
          expect(structured['id'], equals('draft-1'));
          expect(harness.nativeBridge.drafts.length, equals(1));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-NAT.6: Native Shortcuts Workflow (run shortcut with safe arguments)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const shortcutArgs = <String, Object?>{
            'shortcutName': 'SummarizeClipboard',
            'input': 'Text to summarize',
          };
          final res = await harness.dispatchFull(
            'shortcuts.run',
            shortcutArgs,
            approval: harness.standardR2Approval(shortcutArgs),
          );
          final meta = (res.result['_meta'] as Map).cast<String, Object?>();
          final structured = (res.result['structuredContent'] as Map).cast<String, Object?>();
          expect(meta['xuna/status'], equals('ok'));
          expect(structured['name'], equals('SummarizeClipboard'));
          expect(structured['status'], equals('completed'));
          expect(structured['output'], contains('SummarizeClipboard'));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-WEB.1: Browser Navigation & ARIA Snapshot Workflow (navigate -> compact snapshot <= 6144 B)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // 1. Navigate to public HTTPS URL
          const navArgs = <String, Object?>{
            'url': 'https://example.com/portal',
          };
          final navMeta = await harness.dispatch(
            'web.navigate',
            navArgs,
            approval: harness.standardR2Approval(navArgs),
          );
          expect(navMeta['xuna/status'], equals('ok'));

          // 2. Capture compact ARIA snapshot
          const snapArgs = <String, Object?>{
            'compact': true,
            'maxBytes': 6144,
          };
          final snapRes = await harness.dispatchFull(
            'web.snapshot',
            snapArgs,
          );
          final snapMeta = (snapRes.result['_meta'] as Map).cast<String, Object?>();
          final snapStructured = (snapRes.result['structuredContent'] as Map).cast<String, Object?>();
          expect(snapMeta['xuna/status'], equals('ok'));
          final ariaTree = snapStructured['compactAriaTree'] as String;
          expect(ariaTree, contains('Main Heading'));
          expect(utf8.encode(ariaTree).length, lessThanOrEqualTo(6144));
          expect((snapStructured['elementCount'] as int), greaterThanOrEqualTo(5));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-WEB.2: Browser Interaction Flow (fill search -> click submit -> select sort -> extract text -> wait_for)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const navArgs = <String, Object?>{'url': 'https://example.com'};
          await harness.dispatch(
            'web.navigate',
            navArgs,
            approval: harness.standardR2Approval(navArgs),
          );

          // 1. Fill search input (benign R2)
          const fillArgs = <String, Object?>{
            'ref': 'e2',
            'value': 'flutter desktop',
            'selector': '#search-box',
          };
          final fillRes = await harness.dispatchStructured(
            'web.fill',
            fillArgs,
            approval: harness.standardR2Approval(fillArgs),
          );
          expect(fillRes['filled'], isTrue);
          expect(fillRes['valueLength'], equals('flutter desktop'.length));

          // 2. Click submit button (benign R2)
          const clickArgs = <String, Object?>{
            'ref': 'e3',
            'selector': '#btn-search',
          };
          final clickRes = await harness.dispatchStructured(
            'web.click',
            clickArgs,
            approval: harness.standardR2Approval(clickArgs),
          );
          expect(clickRes['clicked'], isTrue);

          // 3. Select dropdown option (R2)
          const selectArgs = <String, Object?>{
            'ref': 'e4',
            'value': 'price_asc',
            'selector': '#sort-select',
          };
          final selectRes = await harness.dispatchStructured(
            'web.select',
            selectArgs,
            approval: harness.standardR2Approval(selectArgs),
          );
          expect(selectRes['selected'], isTrue);
          expect(selectRes['selectedValue'], equals('price_asc'));

          // 4. Extract element text (R1)
          const extractArgs = <String, Object?>{'ref': 'e1'};
          final extractRes = await harness.dispatchStructured(
            'web.extract',
            extractArgs,
          );
          expect(extractRes['value'], equals('Main Heading'));

          // 5. Wait for element state (R1)
          const waitArgs = <String, Object?>{
            'selector': '#btn-search',
            'state': 'visible',
            'timeoutMs': 5000,
          };
          final waitRes = await harness.dispatchStructured(
            'web.wait_for',
            waitArgs,
          );
          expect(waitRes['satisfied'], isTrue);
        } finally {
          await harness.dispose();
        }
      });
    });

    // =========================================================================
    // Tier 2: Boundary Values, Anti-SSRF Rejection & Security Invariants
    // =========================================================================

    group('Tier 2 - Boundaries, Anti-SSRF & Security Invariants', () {
      test('T2-SEC.1: Browser Anti-SSRF Strict Rejection Matrix (127.0.0.1, 10.0.0.1, 169.254.169.254, localhost, file://)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const prohibitedUrls = <String>[
            'https://127.0.0.1/admin',
            'https://10.0.0.1/internal',
            'https://169.254.169.254/latest/meta-data/',
            'https://localhost/dashboard',
            'file:///etc/hosts',
            'http://example.com',
            'https://admin:secret@example.com',
          ];

          for (final url in prohibitedUrls) {
            final args = <String, Object?>{'url': url};
            final meta = await harness.dispatch(
              'web.navigate',
              args,
              approval: harness.standardR2Approval(args),
            );
            expect(
              meta['xuna/status'],
              equals('invalid_args'),
              reason: 'URL $url must be rejected with invalid_args',
            );
            expect(
              meta['xuna/errorCode'],
              equals('url_invalid'),
              reason: 'URL $url must return url_invalid error code',
            );
          }

          // Invariant: zero calls reached the underlying browser engine
          expect(harness.browserEngine.recordedCalls, isEmpty);
        } finally {
          await harness.dispose();
        }
      });

      test('T2-SEC.2: Consequential Browser Actions Require R3 Elevation (payment/checkout/delete)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const navArgs = <String, Object?>{'url': 'https://example.com'};
          await harness.dispatch(
            'web.navigate',
            navArgs,
            approval: harness.standardR2Approval(navArgs),
          );

          // 1. Consequential click on #btn-checkout with targetText "Thanh toán"
          const checkoutArgs = <String, Object?>{
            'ref': 'e5',
            'selector': '#btn-checkout',
            'targetText': 'Thanh toán',
          };

          // 1a. Call without approval fails closed
          final noApprMeta = await harness.dispatch(
            'web.click',
            checkoutArgs,
            approval: null,
          );
          expect(noApprMeta['xuna/status'], equals('denied'));
          expect(noApprMeta['xuna/errorCode'], equals('approval_required'));

          // 1b. Call with standard R2 approval fails closed because R3 signature is required
          final r2Meta = await harness.dispatch(
            'web.click',
            checkoutArgs,
            approval: harness.standardR2Approval(checkoutArgs),
          );
          expect(r2Meta['xuna/status'], equals('denied'));
          expect(r2Meta['xuna/errorCode'], equals('approval_signature_invalid'));

          // 1c. Call with deterministic P-256 signed R3 approval succeeds
          final r3Meta = await harness.dispatch(
            'web.click',
            checkoutArgs,
            approval: harness.signedR3Approval(checkoutArgs),
          );
          expect(r3Meta['xuna/status'], equals('ok'));

          // 2. Consequential click on "Delete Account"
          const deleteArgs = <String, Object?>{
            'ref': 'e3',
            'selector': 'button.delete-account',
            'targetText': 'Delete Account',
          };
          final delR2Meta = await harness.dispatch(
            'web.click',
            deleteArgs,
            approval: harness.standardR2Approval(deleteArgs),
          );
          expect(delR2Meta['xuna/status'], equals('denied'));
          expect(delR2Meta['xuna/errorCode'], equals('approval_signature_invalid'));

          // 3. Consequential fill on password / CVV sensitive field
          const sensitiveFillArgs = <String, Object?>{
            'ref': 'e2',
            'value': 'SuperSecretPassword!',
            'selector': 'input#password',
            'targetText': 'Mật khẩu',
          };
          final fillR2Meta = await harness.dispatch(
            'web.fill',
            sensitiveFillArgs,
            approval: harness.standardR2Approval(sensitiveFillArgs),
          );
          expect(fillR2Meta['xuna/status'], equals('denied'));
          expect(fillR2Meta['xuna/errorCode'], equals('approval_signature_invalid'));

          final fillR3Meta = await harness.dispatch(
            'web.fill',
            sensitiveFillArgs,
            approval: harness.signedR3Approval(sensitiveFillArgs),
          );
          expect(fillR3Meta['xuna/status'], equals('ok'));

          // 4. Benign click/fill operates normally under standard R2 approval
          const benignFillArgs = <String, Object?>{
            'ref': 'e2',
            'value': 'laptop gaming',
            'selector': '#search-box',
            'targetText': 'Search',
          };
          final benignMeta = await harness.dispatch(
            'web.fill',
            benignFillArgs,
            approval: harness.standardR2Approval(benignFillArgs),
          );
          expect(benignMeta['xuna/status'], equals('ok'));
        } finally {
          await harness.dispose();
        }
      });

      test('T2-SEC.3: Native Command/Script Injection Defense & Schema Validation', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // 1. Shell metacharacters in notes.create are treated as plain text literals
          const injectionArgs = <String, Object?>{
            'title': 'Safe Note"; rm -rf /; echo "',
            'body': '`cat /etc/passwd` & calc.exe',
            'folder': 'Work',
          };
          final noteRes = await harness.dispatchStructured(
            'notes.create',
            injectionArgs,
            approval: harness.standardR2Approval(injectionArgs),
          );
          expect(noteRes['title'], equals('Safe Note"; rm -rf /; echo "'));
          expect(harness.nativeBridge.notes.first['title'], equals('Safe Note"; rm -rf /; echo "'));

          // 2. CLI flag injection in shortcuts.run is rejected with schema_mismatch
          const flagArgs = <String, Object?>{
            'shortcutName': '-runHack',
          };
          final flagMeta = await harness.dispatch(
            'shortcuts.run',
            flagArgs,
            approval: harness.standardR2Approval(flagArgs),
          );
          expect(flagMeta['xuna/status'], equals('invalid_args'));
          expect(flagMeta['xuna/errorCode'], equals('schema_mismatch'));

          // 3. Null byte injection in finder.reveal is rejected with schema_mismatch
          const nullByteArgs = <String, Object?>{
            'path': 'c:\\safe\\path\x00\\bad',
          };
          final nullByteMeta = await harness.dispatch(
            'finder.reveal',
            nullByteArgs,
          );
          expect(nullByteMeta['xuna/status'], equals('invalid_args'));
          expect(nullByteMeta['xuna/errorCode'], equals('schema_mismatch'));

          // 4. Missing target in notes.append (both id and title omitted) returns missing_target
          const missingTargetArgs = <String, Object?>{
            'text': 'Some text',
          };
          final missingTargetMeta = await harness.dispatch(
            'notes.append',
            missingTargetArgs,
            approval: harness.standardR2Approval(missingTargetArgs),
          );
          expect(missingTargetMeta['xuna/status'], equals('invalid_args'));
          expect(missingTargetMeta['xuna/errorCode'], equals('missing_target'));

          // 5. Inverted date range in calendar.list_events returns invalid_date_range
          const invertedDateArgs = <String, Object?>{
            'timeMin': '2026-11-25T00:00:00Z',
            'timeMax': '2026-11-20T00:00:00Z',
          };
          final invertedDateMeta = await harness.dispatch(
            'calendar.list_events',
            invertedDateArgs,
          );
          expect(invertedDateMeta['xuna/status'], equals('invalid_args'));
          expect(invertedDateMeta['xuna/errorCode'], equals('invalid_date_range'));
        } finally {
          await harness.dispose();
        }
      });

      test('T2-SEC.4: Mail Draft Strict Draft-Only Invariant (rejects send: true)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // 1. Attempting to pass additionalProperty send: true is rejected with schema_mismatch
          const sendAttemptArgs = <String, Object?>{
            'to': <String>['recipient@example.com'],
            'subject': 'Draft Attempt',
            'body': 'Body text',
            'send': true,
          };
          final sendMeta = await harness.dispatch(
            'mail.create_draft',
            sendAttemptArgs,
            approval: harness.standardR2Approval(sendAttemptArgs),
          );
          expect(sendMeta['xuna/status'], equals('invalid_args'));
          expect(sendMeta['xuna/errorCode'], equals('schema_mismatch'));

          // 2. CRLF injection in subject line is rejected with schema_mismatch
          const crlfArgs = <String, Object?>{
            'to': <String>['recipient@example.com'],
            'subject': 'Normal Subject\r\nBcc: evil@domain.com',
            'body': 'Body text',
          };
          final crlfMeta = await harness.dispatch(
            'mail.create_draft',
            crlfArgs,
            approval: harness.standardR2Approval(crlfArgs),
          );
          expect(crlfMeta['xuna/status'], equals('invalid_args'));
          expect(crlfMeta['xuna/errorCode'], equals('schema_mismatch'));

          // 3. Malformed email address rejected with schema_mismatch
          const badEmailArgs = <String, Object?>{
            'to': <String>['not-an-email'],
            'subject': 'Normal Subject',
            'body': 'Body text',
          };
          final badEmailMeta = await harness.dispatch(
            'mail.create_draft',
            badEmailArgs,
            approval: harness.standardR2Approval(badEmailArgs),
          );
          expect(badEmailMeta['xuna/status'], equals('invalid_args'));
          expect(badEmailMeta['xuna/errorCode'], equals('schema_mismatch'));
        } finally {
          await harness.dispose();
        }
      });

      test('T2-SEC.5: Snapshot Size Boundary Enforcement', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // 1. Snapshot on unloaded browser fails closed with no_page_loaded
          final unloadedMeta = await harness.dispatch(
            'web.snapshot',
            const <String, Object?>{'compact': true},
          );
          expect(unloadedMeta['xuna/status'], equals('failed'));
          expect(unloadedMeta['xuna/errorCode'], equals('no_page_loaded'));

          // Load page
          const navArgs = <String, Object?>{'url': 'https://example.com'};
          await harness.dispatch(
            'web.navigate',
            navArgs,
            approval: harness.standardR2Approval(navArgs),
          );

          // 2. maxBytes > 6144 is rejected with schema_mismatch
          const excessiveBytesArgs = <String, Object?>{'maxBytes': 7000};
          final excessiveMeta = await harness.dispatch(
            'web.snapshot',
            excessiveBytesArgs,
          );
          expect(excessiveMeta['xuna/status'], equals('invalid_args'));
          expect(excessiveMeta['xuna/errorCode'], equals('schema_mismatch'));

          // 3. maxBytes < 100 is rejected with schema_mismatch
          const tinyBytesArgs = <String, Object?>{'maxBytes': 50};
          final tinyMeta = await harness.dispatch(
            'web.snapshot',
            tinyBytesArgs,
          );
          expect(tinyMeta['xuna/status'], equals('invalid_args'));
          expect(tinyMeta['xuna/errorCode'], equals('schema_mismatch'));
        } finally {
          await harness.dispose();
        }
      });
    });

    // =========================================================================
    // Tier 3: Concurrency, Dual-Lane Verification & State Interactions
    // =========================================================================

    group('Tier 3 - Concurrency & Dual-Lane Verification', () {
      test('T3-LANE.1: Dual-Lane Architecture Verification (Parallel Read Lane vs Sequential Mutating Lane)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          expect(harness.dispatcher.parallelReadLaneCount, equals(0));
          expect(harness.dispatcher.serialActionLaneCount, equals(0));

          // 1. notes.search routes to ParallelReadLane
          await harness.dispatch(
            'notes.search',
            const <String, Object?>{'query': 'test'},
          );
          expect(harness.dispatcher.parallelReadLaneCount, equals(1));
          expect(harness.dispatcher.serialActionLaneCount, equals(0));

          // 2. calendar.list_events routes to ParallelReadLane
          await harness.dispatch(
            'calendar.list_events',
            const <String, Object?>{
              'timeMin': '2026-11-20T00:00:00Z',
              'timeMax': '2026-11-20T23:59:59Z',
            },
          );
          expect(harness.dispatcher.parallelReadLaneCount, equals(2));
          expect(harness.dispatcher.serialActionLaneCount, equals(0));

          // 3. finder.reveal routes to ParallelReadLane
          await harness.dispatch(
            'finder.reveal',
            const <String, Object?>{'path': 'c:\\safe\\path'},
          );
          expect(harness.dispatcher.parallelReadLaneCount, equals(3));
          expect(harness.dispatcher.serialActionLaneCount, equals(0));

          // 4. notes.create routes to SerialActionLane
          const createArgs = <String, Object?>{
            'title': 'Serial Note',
            'body': 'Body text',
          };
          await harness.dispatch(
            'notes.create',
            createArgs,
            approval: harness.standardR2Approval(createArgs),
          );
          expect(harness.dispatcher.parallelReadLaneCount, equals(3));
          expect(harness.dispatcher.serialActionLaneCount, equals(1));

          // 5. calendar.create_event routes to SerialActionLane
          const eventArgs = <String, Object?>{
            'title': 'Serial Event',
            'startTime': '2026-11-20T10:00:00Z',
            'endTime': '2026-11-20T11:00:00Z',
          };
          await harness.dispatch(
            'calendar.create_event',
            eventArgs,
            approval: harness.standardR2Approval(eventArgs),
          );
          expect(harness.dispatcher.parallelReadLaneCount, equals(3));
          expect(harness.dispatcher.serialActionLaneCount, equals(2));

          // 6. mail.create_draft routes to SerialActionLane
          const draftArgs = <String, Object?>{
            'to': <String>['test@example.com'],
            'subject': 'Serial Draft',
            'body': 'Draft body',
          };
          await harness.dispatch(
            'mail.create_draft',
            draftArgs,
            approval: harness.standardR2Approval(draftArgs),
          );
          expect(harness.dispatcher.parallelReadLaneCount, equals(3));
          expect(harness.dispatcher.serialActionLaneCount, equals(3));
        } finally {
          await harness.dispose();
        }
      });

      test('T3-LANE.2: Simultaneous Execution of Concurrent Read Lane with Mutating Lane (Future.wait)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const navArgs = <String, Object?>{'url': 'https://example.com'};
          await harness.dispatch(
            'web.navigate',
            navArgs,
            approval: harness.standardR2Approval(navArgs),
          );

          // Execute multiple read operations simultaneously using Future.wait
          final results = await Future.wait(<Future<Map<String, Object?>>>[
            harness.dispatch(
              'notes.search',
              const <String, Object?>{'query': 'alpha'},
            ),
            harness.dispatch(
              'calendar.list_events',
              const <String, Object?>{
                'timeMin': '2026-11-20T00:00:00Z',
                'timeMax': '2026-11-20T23:59:59Z',
              },
            ),
            harness.dispatch(
              'web.snapshot',
              const <String, Object?>{'compact': true},
            ),
            harness.dispatch(
              'web.extract',
              const <String, Object?>{'ref': 'e1'},
            ),
          ]);

          for (final res in results) {
            expect(res['xuna/status'], equals('ok'));
          }
        } finally {
          await harness.dispose();
        }
      });

      test('T3-STATE.1: Idempotency Across Wave B Invocations (cached result on duplicate invocationId)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          const fixedInvId = 'idemp-test-inv-000000000001';
          const createArgs = <String, Object?>{
            'title': 'Idempotent Note',
            'body': 'Content',
          };
          final appr = harness.standardR2Approval(createArgs);

          // First call executes against bridge
          final firstRes = await harness.dispatchFull(
            'notes.create',
            createArgs,
            approval: appr,
            invocationId: fixedInvId,
          );
          final firstStructured = (firstRes.result['structuredContent'] as Map).cast<String, Object?>();
          expect(firstStructured['id'], equals('note-1'));
          expect(harness.nativeBridge.recordedCalls.length, equals(1));

          // Second call with identical invocationId returns cached result without re-executing
          final secondRes = await harness.dispatchFull(
            'notes.create',
            createArgs,
            approval: appr,
            invocationId: fixedInvId,
          );
          final secondStructured = (secondRes.result['structuredContent'] as Map).cast<String, Object?>();
          expect(secondStructured['id'], equals('note-1'));
          expect(harness.nativeBridge.recordedCalls.length, equals(1));
        } finally {
          await harness.dispose();
        }
      });

      test('T3-ERR.1: Rule H4 Error Code Preservation Across Native and Browser Tools', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // 1. finder.reveal on nonexistent path preserves file_not_found
          const missingPathArgs = <String, Object?>{
            'path': 'c:\\nonexistent\\missing_dir\\file.txt',
          };
          final finderMeta = await harness.dispatch(
            'finder.reveal',
            missingPathArgs,
          );
          expect(finderMeta['xuna/status'], equals('invalid_args'));
          expect(finderMeta['xuna/errorCode'], equals('file_not_found'));

          // 2. notes.append on nonexistent id preserves target_not_found
          const missingNoteArgs = <String, Object?>{
            'id': 'nonexistent-note-id',
            'text': 'Some content',
          };
          final noteMeta = await harness.dispatch(
            'notes.append',
            missingNoteArgs,
            approval: harness.standardR2Approval(missingNoteArgs),
          );
          expect(noteMeta['xuna/status'], equals('failed'));
          expect(noteMeta['xuna/errorCode'], equals('target_not_found'));

          // 3. shortcuts.run on missing shortcut preserves shortcut_execution_failed
          const missingShortcutArgs = <String, Object?>{
            'shortcutName': 'missing_shortcut',
          };
          final shortcutMeta = await harness.dispatch(
            'shortcuts.run',
            missingShortcutArgs,
            approval: harness.standardR2Approval(missingShortcutArgs),
          );
          expect(shortcutMeta['xuna/status'], equals('failed'));
          expect(shortcutMeta['xuna/errorCode'], equals('shortcut_execution_failed'));

          // 4. web.wait_for on nonexistent selector times out preserving timeout
          const navArgs = <String, Object?>{'url': 'https://example.com'};
          await harness.dispatch(
            'web.navigate',
            navArgs,
            approval: harness.standardR2Approval(navArgs),
          );

          const missingSelectorArgs = <String, Object?>{
            'selector': '#nonexistent-modal',
            'state': 'visible',
            'timeoutMs': 2000,
          };
          final waitMeta = await harness.dispatch(
            'web.wait_for',
            missingSelectorArgs,
          );
          expect(waitMeta['xuna/status'], equals('failed'));
          expect(waitMeta['xuna/errorCode'], equals('timeout'));
        } finally {
          await harness.dispose();
        }
      });
    });

    // =========================================================================
    // Tier 4: Comprehensive Real-World Workload Scenarios (S1–S3)
    // =========================================================================

    group('Tier 4 - Real-World Application Scenarios (UDC-18 & TEST_INFRA S1-S3)', () {
      test('T4-SCN.1: Scenario S1 — Multi-step Note Creation & File Reveal', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // Step 1: Create project roadmap note
          const createArgs = <String, Object?>{
            'title': 'Q4 Milestone Planning',
            'body': 'Deploy Wave B agent and verify native bridges.',
            'folder': 'Roadmap',
          };
          final step1 = await harness.dispatchStructured(
            'notes.create',
            createArgs,
            approval: harness.standardR2Approval(createArgs),
          );
          expect(step1['id'], equals('note-1'));

          // Step 2: Search for note by keyword
          const searchArgs = <String, Object?>{'query': 'Milestone'};
          final step2 = await harness.dispatchStructured('notes.search', searchArgs);
          expect(step2['total'], equals(1));
          final notes = (step2['notes'] as List).cast<Map<String, Object?>>();
          expect(notes.first['title'], equals('Q4 Milestone Planning'));

          // Step 3: Append milestone progress update
          const appendArgs = <String, Object?>{
            'id': 'note-1',
            'text': '\n- Completed Tier 1-4 tests with zero regressions.',
          };
          final step3 = await harness.dispatchStructured(
            'notes.append',
            appendArgs,
            approval: harness.standardR2Approval(appendArgs),
          );
          expect(step3['appended'], isTrue);

          // Step 4: Re-verify updated content via search and bridge
          final step4 = await harness.dispatchStructured('notes.search', searchArgs);
          expect(step4['total'], equals(1));
          expect(harness.nativeBridge.notes.first['body'], contains('Completed Tier 1-4 tests with zero regressions.'));

          // Step 5: Reveal project workspace in Finder / Explorer
          const revealArgs = <String, Object?>{
            'path': 'c:\\Users\\Thao\\Documents\\xuna_pet\\desktop',
          };
          final step5 = await harness.dispatchStructured('finder.reveal', revealArgs);
          expect(step5['revealed'], isTrue);
          expect(step5['path'], equals(revealArgs['path']));
        } finally {
          await harness.dispose();
        }
      });

      test('T4-SCN.2: Scenario S2 — Meeting Preparation & Draft Communication (R2 Draft-Only)', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // Step 1: Check existing calendar events for the day
          const listArgs = <String, Object?>{
            'timeMin': '2026-11-16T09:00:00Z',
            'timeMax': '2026-11-16T18:00:00Z',
          };
          final step1 = await harness.dispatchStructured('calendar.list_events', listArgs);
          expect(step1['total'], equals(0));

          // Step 2: Book team architecture review meeting
          const eventArgs = <String, Object?>{
            'title': 'Wave B Release Review',
            'startTime': '2026-11-16T14:00:00Z',
            'endTime': '2026-11-16T15:00:00Z',
            'location': 'Conference Room A',
            'notes': 'Production readiness sign-off.',
            'calendarName': 'Engineering',
          };
          final step2 = await harness.dispatchStructured(
            'calendar.create_event',
            eventArgs,
            approval: harness.standardR2Approval(eventArgs),
          );
          expect(step2['id'], equals('evt-1'));

          // Step 3: Verify meeting appears on calendar
          final step3 = await harness.dispatchStructured('calendar.list_events', listArgs);
          expect(step3['total'], equals(1));
          final events = (step3['events'] as List).cast<Map<String, Object?>>();
          expect(events.first['title'], equals('Wave B Release Review'));

          // Step 4: Draft notification email to team (R2 draft-only)
          const draftArgs = <String, Object?>{
            'to': <String>['lead@xuna.ai', 'team@xuna.ai'],
            'subject': 'Wave B Review Scheduled',
            'body': 'The architecture review has been scheduled for tomorrow 14:00 UTC in Room A.',
          };
          final step4 = await harness.dispatchStructured(
            'mail.create_draft',
            draftArgs,
            approval: harness.standardR2Approval(draftArgs),
          );
          expect(step4['isDraft'], isTrue);
          expect(step4['subject'], equals('Wave B Review Scheduled'));
          expect(harness.nativeBridge.drafts.length, equals(1));

          // Step 5: Strict invariant verification: attempting send: true fails closed
          const sendArgs = <String, Object?>{
            'to': <String>['team@xuna.ai'],
            'subject': 'Send Attempt',
            'body': 'Should fail',
            'send': true,
          };
          final step5 = await harness.dispatch(
            'mail.create_draft',
            sendArgs,
            approval: harness.standardR2Approval(sendArgs),
          );
          expect(step5['xuna/status'], equals('invalid_args'));
          expect(step5['xuna/errorCode'], equals('schema_mismatch'));
        } finally {
          await harness.dispose();
        }
      });

      test('T4-SCN.3: Scenario S3 — Secure Browser Research & Protected Submission', () async {
        final harness = await WaveBDesktopE2ETestHarness.create();
        try {
          // Step 1: Adversarial SSRF probe to cloud metadata service is strictly blocked
          const ssrfArgs = <String, Object?>{
            'url': 'https://169.254.169.254/latest/meta-data/',
          };
          final step1 = await harness.dispatch(
            'web.navigate',
            ssrfArgs,
            approval: harness.standardR2Approval(ssrfArgs),
          );
          expect(step1['xuna/status'], equals('invalid_args'));
          expect(step1['xuna/errorCode'], equals('url_invalid'));

          // Step 2: Navigate to legitimate public shop
          const navArgs = <String, Object?>{'url': 'https://shop.vietnam.vn/cart'};
          final step2 = await harness.dispatchStructured(
            'web.navigate',
            navArgs,
            approval: harness.standardR2Approval(navArgs),
          );
          expect(step2['loaded'], isTrue);

          // Step 3: Capture compact ARIA accessibility tree
          final step3 = await harness.dispatchStructured(
            'web.snapshot',
            const <String, Object?>{'compact': true, 'maxBytes': 6144},
          );
          final aria = step3['compactAriaTree'] as String;
          expect(aria, contains('Checkout & Pay'));
          expect(utf8.encode(aria).length, lessThanOrEqualTo(6144));

          // Step 4: Benign interaction (fill promo code) under R2 approval
          const fillPromoArgs = <String, Object?>{
            'ref': 'e2',
            'value': 'SPRING2026',
            'selector': '#search-box',
          };
          final step4 = await harness.dispatchStructured(
            'web.fill',
            fillPromoArgs,
            approval: harness.standardR2Approval(fillPromoArgs),
          );
          expect(step4['filled'], isTrue);

          // Step 5: Consequential interaction (click checkout button)
          const checkoutArgs = <String, Object?>{
            'ref': 'e5',
            'selector': '#btn-checkout',
            'targetText': 'Thanh toán',
          };

          // 5a. Blocked under standard R2 approval
          final step5Blocked = await harness.dispatch(
            'web.click',
            checkoutArgs,
            approval: harness.standardR2Approval(checkoutArgs),
          );
          expect(step5Blocked['xuna/status'], equals('denied'));
          expect(step5Blocked['xuna/errorCode'], equals('approval_signature_invalid'));

          // 5b. Allowed when elevated with phone-signed P-256 R3 approval
          final step5Allowed = await harness.dispatchStructured(
            'web.click',
            checkoutArgs,
            approval: harness.signedR3Approval(checkoutArgs),
          );
          expect(step5Allowed['clicked'], isTrue);
        } finally {
          await harness.dispose();
        }
      });
    });
  });
}
