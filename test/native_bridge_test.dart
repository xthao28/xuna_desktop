import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/native_bridge/fake_native_app_bridge.dart';
import 'package:xuna_desktop/features/native_bridge/macos_native_app_bridge.dart';
import 'package:xuna_desktop/features/native_bridge/windows_native_app_bridge.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

HostPolicy _buildTestPolicy() => HostPolicy(
      schemaVersion: 1,
      trustPreset: TrustPreset.standard,
      families: const <ToolFamily, FamilyPolicyDecision>{
        ToolFamily.app: FamilyPolicyDecision.allow,
        ToolFamily.files: FamilyPolicyDecision.allow,
        ToolFamily.workflow: FamilyPolicyDecision.allow,
        ToolFamily.host: FamilyPolicyDecision.allow,
      },
      apps: const <AllowedAppConfig>[],
      urlDomains: const <String>[],
      workflows: const <WorkflowConfig>[],
      players: const <String>[],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MacosNativeAppBridge — Argument Parameterization & Safety', () {
    test('passes arguments strictly via argv without script interpolation', () async {
      final executedCalls = <Map<String, Object?>>[];

      Future<ProcessResult> mockRunner(String exe, List<String> args) async {
        executedCalls.add(<String, Object?>{'exe': exe, 'args': args});
        if (exe == 'osascript' && args.contains('-l')) {
          // JXA
          return ProcessResult(1234, 0, '{"events":[],"total":0}', '');
        }
        return ProcessResult(1234, 0, 'id-123\n', '');
      }

      final bridge = MacosNativeAppBridge(processRunner: mockRunner);

      // Test notesCreate: ensures title and body are separate argv items, not in -e string
      final noteRes = await bridge.notesCreate(
        title: 'Safe Note " with quotes',
        body: 'Safe Body & do shell script',
        folder: 'Work',
      );
      expect(noteRes['id'], 'id-123');
      expect(noteRes['title'], 'Safe Note " with quotes');

      final lastCall = executedCalls.last;
      expect(lastCall['exe'], 'osascript');
      final args = lastCall['args']! as List<String>;
      expect(args[0], '-e');
      // The script template must NOT contain the user title
      expect(args[1], isNot(contains('Safe Note " with quotes')));
      // Arguments must be passed as subsequent argv items
      expect(args[2], 'Safe Note " with quotes');
      expect(args[3], 'Safe Body & do shell script');
      expect(args[4], 'Work');

      // Test shortcutsRun
      executedCalls.clear();
      await bridge.shortcutsRun(shortcutName: 'MyShortcut', input: 'my-input');
      expect(executedCalls.first['exe'], '/usr/bin/shortcuts');
      expect(executedCalls.first['args'], <String>['run', '--', 'MyShortcut', '-i', 'my-input']);

      // shortcutsRun rejects flag injection
      await expectLater(
        () => bridge.shortcutsRun(shortcutName: '-v'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'schema_mismatch',
          ),
        ),
      );
    });
  });

  group('WindowsNativeAppBridge — Fail-Closed Rules (Rule H1)', () {
    final bridge = WindowsNativeAppBridge();

    test('fails closed with platform_unsupported on macOS-native tools', () async {
      await expectLater(
        () => bridge.notesCreate(title: 'T', body: 'B'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'platform_unsupported',
          ),
        ),
      );

      await expectLater(
        () => bridge.notesAppend(text: 'Text'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'platform_unsupported',
          ),
        ),
      );

      await expectLater(
        () => bridge.notesSearch(query: 'Search'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'platform_unsupported',
          ),
        ),
      );

      await expectLater(
        () => bridge.remindersCreate(title: 'Rem'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'platform_unsupported',
          ),
        ),
      );

      await expectLater(
        () => bridge.calendarListEvents(
          timeMin: '2026-11-15T00:00:00Z',
          timeMax: '2026-11-15T23:59:59Z',
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'platform_unsupported',
          ),
        ),
      );

      await expectLater(
        () => bridge.calendarCreateEvent(
          title: 'Meeting',
          startTime: '2026-11-15T10:00:00Z',
          endTime: '2026-11-15T11:00:00Z',
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'platform_unsupported',
          ),
        ),
      );

      await expectLater(
        () => bridge.shortcutsRun(shortcutName: 'Shortcut'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'platform_unsupported',
          ),
        ),
      );

      await expectLater(
        () => bridge.mailCreateDraft(
          to: <String>['test@xuna.ai'],
          subject: 'Subj',
          body: 'Body',
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'platform_unsupported',
          ),
        ),
      );
    });

    test('finderReveal fails closed on nonexistent path', () async {
      await expectLater(
        () => bridge.finderReveal(path: 'C:\\nonexistent_dir\\file.txt'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'file_not_found',
          ),
        ),
      );
    });
  });

  group('FakeNativeAppBridge — Deterministic Test Harness', () {
    test('implements full CRUD lifecycle for notes, reminders, events, drafts', () async {
      final fake = FakeNativeAppBridge();

      // Notes
      final createdNote = await fake.notesCreate(
        title: 'Project Roadmap',
        body: 'Phase 1 completed.\nPhase 2 pending.',
        folder: 'Work',
      );
      expect(createdNote['id'], 'note-1');

      final searchRes = await fake.notesSearch(query: 'Roadmap');
      expect(searchRes['total'], 1);
      final notesList = searchRes['notes'] as List<Map<String, Object?>>;
      expect(notesList.first['title'], 'Project Roadmap');

      final appendRes = await fake.notesAppend(
        id: 'note-1',
        text: 'Phase 3 planned.',
      );
      expect(appendRes['appended'], isTrue);

      // Notes append missing target throws target_not_found
      await expectLater(
        () => fake.notesAppend(id: 'nonexistent-id', text: 'More'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'target_not_found',
          ),
        ),
      );

      // Notes append without id and without title throws missing_target (Rule H3)
      await expectLater(
        () => fake.notesAppend(text: 'More'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'missing_target',
          ),
        ),
      );

      // Shortcuts run with flag injection throws schema_mismatch
      await expectLater(
        () => fake.shortcutsRun(shortcutName: '-v'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'schema_mismatch',
          ),
        ),
      );

      // Reminders
      final rem = await fake.remindersCreate(
        title: 'Buy Milk',
        dueDate: '2026-11-16T10:00:00Z',
        priority: 1,
      );
      expect(rem['id'], 'rem-1');

      // Calendar
      final evt = await fake.calendarCreateEvent(
        title: 'Sprint Planning',
        startTime: '2026-11-15T09:00:00Z',
        endTime: '2026-11-15T10:00:00Z',
      );
      expect(evt['id'], 'evt-1');

      final calList = await fake.calendarListEvents(
        timeMin: '2026-11-15T00:00:00Z',
        timeMax: '2026-11-15T23:59:59Z',
      );
      expect(calList['total'], 1);

      // Finder reveal
      final rev = await fake.finderReveal(path: '/Users/test/doc.txt');
      expect(rev['revealed'], isTrue);

      // Mail draft
      final draft = await fake.mailCreateDraft(
        to: <String>['lead@xuna.ai'],
        subject: 'Weekly Report',
        body: 'All tasks completed.',
      );
      expect(draft['isDraft'], isTrue);
    });
  });

  group('HostToolDispatcher — Native Tools Integration & Execution Lanes', () {
    late Directory tempDir;
    late AgentPaths paths;
    late HostPolicyStore policyStore;
    late FakeNativeAppBridge fakeBridge;
    late HostToolDispatcher dispatcher;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('native_bridge_test_');
      paths = AgentPaths(rootDir: tempDir);
      await paths.ensureDirectories();

      final logger = ContentFreeLogger();
      await paths.policyFile.writeAsString(jsonEncode(_buildTestPolicy().toJson()));
      policyStore = HostPolicyStore(
        policyFile: paths.policyFile,
        logger: logger,
      );
      await policyStore.reload();

      fakeBridge = FakeNativeAppBridge();
      dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: FakeXunaHostChannel(),
        auditStore: AuditLogStore(auditDir: paths.auditDir),
        stopController: EmergencyStopController(logger: logger),
        logger: logger,
        nativeAppBridge: fakeBridge,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    ApprovalToken approval(Map<String, Object?> args) => ApprovalToken(
          approvalId: '11111111-1111-4111-8111-111111111111',
          scope: 'once',
          argsSha256: argsSha256(args),
          expiresAt: DateTime.utc(2030, 1, 1),
        );

    test('registers all 9 native tools in buildManifest', () async {
      final manifest = await dispatcher.buildManifest();
      final names = manifest.map((t) => t.name).toSet();

      expect(
        names,
        containsAll(<String>[
          'notes.create',
          'notes.append',
          'notes.search',
          'reminders.create',
          'calendar.list_events',
          'calendar.create_event',
          'finder.reveal',
          'shortcuts.run',
          'mail.create_draft',
        ]),
      );
    });

    test('routes read-only tools to ParallelReadLane and mutating tools to SerialActionLane', () async {
      expect(dispatcher.parallelReadLaneCount, 0);
      expect(dispatcher.serialActionLaneCount, 0);

      // 1. notes.create (mutating -> serial)
      const createArgs = <String, Object?>{
        'title': 'Test Note',
        'body': 'Content',
      };
      final createRes = await dispatcher.dispatch(
        requestId: 1,
        params: ToolsCallParams(
          name: 'notes.create',
          arguments: createArgs,
          invocationId: 'inv-1',
          deadlineMs: 5000,
          approval: approval(createArgs),
        ),
      );
      final createMeta = (createRes.result['_meta'] as Map).cast<String, Object?>();
      expect(createMeta['xuna/status'], 'ok');
      expect(dispatcher.serialActionLaneCount, 1);
      expect(dispatcher.parallelReadLaneCount, 0);

      // 2. notes.search (read-only -> parallel)
      final searchRes = await dispatcher.dispatch(
        requestId: 2,
        params: const ToolsCallParams(
          name: 'notes.search',
          arguments: <String, Object?>{'query': 'Test'},
          invocationId: 'inv-2',
          deadlineMs: 5000,
        ),
      );
      final searchMeta = (searchRes.result['_meta'] as Map).cast<String, Object?>();
      expect(searchMeta['xuna/status'], 'ok');
      expect(dispatcher.parallelReadLaneCount, 1);
      expect(dispatcher.serialActionLaneCount, 1);

      // 3. calendar.list_events (read-only -> parallel)
      final calListRes = await dispatcher.dispatch(
        requestId: 3,
        params: const ToolsCallParams(
          name: 'calendar.list_events',
          arguments: <String, Object?>{
            'timeMin': '2026-11-15T00:00:00Z',
            'timeMax': '2026-11-15T23:59:59Z',
          },
          invocationId: 'inv-3',
          deadlineMs: 5000,
        ),
      );
      final calListMeta = (calListRes.result['_meta'] as Map).cast<String, Object?>();
      expect(calListMeta['xuna/status'], 'ok');
      expect(dispatcher.parallelReadLaneCount, 2);

      // 4. finder.reveal (read-only -> parallel)
      final finderRes = await dispatcher.dispatch(
        requestId: 4,
        params: const ToolsCallParams(
          name: 'finder.reveal',
          arguments: <String, Object?>{'path': '/Users/test/file.txt'},
          invocationId: 'inv-4',
          deadlineMs: 5000,
        ),
      );
      final finderMeta = (finderRes.result['_meta'] as Map).cast<String, Object?>();
      expect(finderMeta['xuna/status'], 'ok');
      expect(dispatcher.parallelReadLaneCount, 3);

      // 5. mail.create_draft (mutating -> serial)
      const mailArgs = <String, Object?>{
        'to': <String>['recipient@test.com'],
        'subject': 'Draft Subj',
        'body': 'Draft Body',
      };
      final mailRes = await dispatcher.dispatch(
        requestId: 5,
        params: ToolsCallParams(
          name: 'mail.create_draft',
          arguments: mailArgs,
          invocationId: 'inv-5',
          deadlineMs: 5000,
          approval: approval(mailArgs),
        ),
      );
      final mailMeta = (mailRes.result['_meta'] as Map).cast<String, Object?>();
      expect(mailMeta['xuna/status'], 'ok');
      expect(dispatcher.serialActionLaneCount, 2);
    });

    test('mail.create_draft is strictly draft-only; rejects send flag', () async {
      // Attempt to sneak in a 'send: true' property
      const badMailArgs = <String, Object?>{
        'to': <String>['boss@company.com'],
        'subject': 'URGENT',
        'body': 'Pay invoice',
        'send': true,
      };
      final rejectRes = await dispatcher.dispatch(
        requestId: 6,
        params: ToolsCallParams(
          name: 'mail.create_draft',
          arguments: badMailArgs,
          invocationId: 'inv-6',
          deadlineMs: 5000,
          approval: approval(badMailArgs),
        ),
      );
      final rejectMeta = (rejectRes.result['_meta'] as Map).cast<String, Object?>();
      expect(rejectMeta['xuna/status'], 'invalid_args');
      expect(rejectMeta['xuna/errorCode'], 'schema_mismatch');
    });

    test('preserves error codes end-to-end (Rule H4)', () async {
      const appendArgs = <String, Object?>{
        'id': 'missing-note',
        'text': 'Append to nowhere',
      };
      final failRes = await dispatcher.dispatch(
        requestId: 7,
        params: ToolsCallParams(
          name: 'notes.append',
          arguments: appendArgs,
          invocationId: 'inv-7',
          deadlineMs: 5000,
          approval: approval(appendArgs),
        ),
      );
      final failMeta = (failRes.result['_meta'] as Map).cast<String, Object?>();
      expect(failMeta['xuna/status'], 'failed');
      expect(failMeta['xuna/errorCode'], 'target_not_found');
    });

    test('notes.append missing target returns missing_target (Rule H3)', () async {
      const missingTargetArgs = <String, Object?>{
        'text': 'Append to unknown target',
      };
      final res = await dispatcher.dispatch(
        requestId: 8,
        params: ToolsCallParams(
          name: 'notes.append',
          arguments: missingTargetArgs,
          invocationId: 'inv-8',
          deadlineMs: 5000,
          approval: approval(missingTargetArgs),
        ),
      );
      final meta = (res.result['_meta'] as Map).cast<String, Object?>();
      expect(meta['xuna/status'], 'invalid_args');
      expect(meta['xuna/errorCode'], 'missing_target');
    });

    test('shortcuts.run flag injection returns schema_mismatch', () async {
      const flagArgs = <String, Object?>{
        'shortcutName': '-v',
      };
      final res = await dispatcher.dispatch(
        requestId: 9,
        params: ToolsCallParams(
          name: 'shortcuts.run',
          arguments: flagArgs,
          invocationId: 'inv-9',
          deadlineMs: 5000,
          approval: approval(flagArgs),
        ),
      );
      final meta = (res.result['_meta'] as Map).cast<String, Object?>();
      expect(meta['xuna/status'], 'invalid_args');
      expect(meta['xuna/errorCode'], 'schema_mismatch');
    });
  });
}
