import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  group('Wave B Native App Tools — Family & Descriptors', () {
    test('resolveToolFamilyForName maps native and web tool families correctly', () {
      expect(resolveToolFamilyForName('notes.create'), ToolFamily.app);
      expect(resolveToolFamilyForName('notes.append'), ToolFamily.app);
      expect(resolveToolFamilyForName('notes.search'), ToolFamily.app);
      expect(resolveToolFamilyForName('reminders.create'), ToolFamily.app);
      expect(resolveToolFamilyForName('calendar.list_events'), ToolFamily.app);
      expect(resolveToolFamilyForName('calendar.create_event'), ToolFamily.app);
      expect(resolveToolFamilyForName('mail.create_draft'), ToolFamily.app);
      expect(resolveToolFamilyForName('finder.reveal'), ToolFamily.files);
      expect(resolveToolFamilyForName('shortcuts.run'), ToolFamily.workflow);
      expect(resolveToolFamilyForName('web.navigate'), ToolFamily.url);
      expect(resolveToolFamilyForName('browser.current_url'), ToolFamily.url);
    });

    test('ToolDescriptor.validateToolName validates native tools and families', () {
      ToolDescriptor.validateToolName('notes.create', expectedFamily: ToolFamily.app);
      ToolDescriptor.validateToolName('notes.append', expectedFamily: ToolFamily.app);
      ToolDescriptor.validateToolName('notes.search', expectedFamily: ToolFamily.app);
      ToolDescriptor.validateToolName('reminders.create', expectedFamily: ToolFamily.app);
      ToolDescriptor.validateToolName('calendar.list_events', expectedFamily: ToolFamily.app);
      ToolDescriptor.validateToolName('calendar.create_event', expectedFamily: ToolFamily.app);
      ToolDescriptor.validateToolName('mail.create_draft', expectedFamily: ToolFamily.app);
      ToolDescriptor.validateToolName('finder.reveal', expectedFamily: ToolFamily.files);
      ToolDescriptor.validateToolName('shortcuts.run', expectedFamily: ToolFamily.workflow);
      ToolDescriptor.validateToolName('web.navigate', expectedFamily: ToolFamily.url);

      expect(
        () => ToolDescriptor.validateToolName('finder.reveal', expectedFamily: ToolFamily.app),
        throwsFormatException,
      );
      expect(
        () => ToolDescriptor.validateToolName('shortcuts.run', expectedFamily: ToolFamily.app),
        throwsFormatException,
      );
    });

    test('buildNativeAppToolCatalog builds all 9 tools with strict schemas', () {
      final catalog = buildNativeAppToolCatalog();
      expect(catalog.length, 9);

      final names = catalog.map((t) => t.name).toSet();
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

      for (final tool in catalog) {
        expect(tool.inputSchema['type'], 'object');
        expect(tool.inputSchema['additionalProperties'], isFalse);
        expect(tool.outputSchema['type'], 'object');
        expect(tool.outputSchema['additionalProperties'], isFalse);
      }

      final notesSearch = catalog.firstWhere((t) => t.name == 'notes.search');
      expect(notesSearch.policy.risk, RiskTier.r1);
      expect(notesSearch.policy.observes, isTrue);

      final calendarList = catalog.firstWhere((t) => t.name == 'calendar.list_events');
      expect(calendarList.policy.risk, RiskTier.r1);
      expect(calendarList.policy.observes, isTrue);

      final finderReveal = catalog.firstWhere((t) => t.name == 'finder.reveal');
      expect(finderReveal.policy.risk, RiskTier.r1);
      expect(finderReveal.policy.family, ToolFamily.files);

      final mailDraft = catalog.firstWhere((t) => t.name == 'mail.create_draft');
      expect(mailDraft.policy.risk, RiskTier.r2);
      expect(mailDraft.description, contains('STRICTLY DRAFT-ONLY'));

      final shortcutsRun = catalog.firstWhere((t) => t.name == 'shortcuts.run');
      expect(shortcutsRun.policy.risk, RiskTier.r2);
      expect(shortcutsRun.policy.family, ToolFamily.workflow);
    });
  });

  group('Wave B Native App Tools — Argument Validation', () {
    final policy = HostPolicy(
      schemaVersion: 1,
      trustPreset: TrustPreset.standard,
      families: const <ToolFamily, FamilyPolicyDecision>{},
      apps: const <AllowedAppConfig>[],
      urlDomains: const <String>[],
      workflows: const <WorkflowConfig>[],
      players: const <String>[],
    );
    final now = DateTime.utc(2026, 11, 15, 12, 0, 0);

    PolicyEvaluationResult eval(String name, Map<String, Object?> args) {
      return validateToolArguments(
        toolName: name,
        arguments: args,
        activePolicy: policy,
        now: now,
        isStopped: false,
        hostId: 'test-host',
        pinnedPhonePublicKeys: <Uint8List>[],
        isInApprovedCuSession: false,
        allowZeroConfigAppDiscovery: true,
        evaluateStep: ({
          required String toolName,
          required Map<String, Object?> arguments,
          ApprovalToken? approval,
          required bool isStopped,
          required DateTime nowUtc,
          String? hostId,
          required List<Uint8List> pinnedPhonePublicKeys,
          required bool isInApprovedCuSession,
          required bool allowZeroConfigAppDiscovery,
          bool allowPublicHttpsDomains = false,
        }) =>
            throw UnimplementedError(),
      );
    }

    test('notes.create validates required fields and limits', () {
      final ok = eval('notes.create', <String, Object?>{
        'title': 'Meeting Notes',
        'body': 'Discuss Wave B implementation.',
        'folder': 'Work',
      });
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r2);

      // Missing title
      final noTitle = eval('notes.create', <String, Object?>{
        'body': 'Discuss Wave B implementation.',
      });
      expect(noTitle.allowed, isFalse);
      expect(noTitle.errorCode, 'schema_mismatch');

      // Null byte injection in title
      final nullTitle = eval('notes.create', <String, Object?>{
        'title': 'Meeting\x00Notes',
        'body': 'Discuss Wave B implementation.',
      });
      expect(nullTitle.allowed, isFalse);
      expect(nullTitle.errorCode, 'schema_mismatch');

      // Null byte injection in body
      final nullBody = eval('notes.create', <String, Object?>{
        'title': 'Meeting Notes',
        'body': 'Discuss Wave B\x00 implementation.',
      });
      expect(nullBody.allowed, isFalse);
      expect(nullBody.errorCode, 'schema_mismatch');

      // Extra property
      final extraProp = eval('notes.create', <String, Object?>{
        'title': 'Test',
        'body': 'Body',
        'unknown': 'bad',
      });
      expect(extraProp.allowed, isFalse);
      expect(extraProp.errorCode, 'schema_mismatch');
    });

    test('notes.append validates target existence (Rule H3: no guessing target)', () {
      final okWithId = eval('notes.append', <String, Object?>{
        'id': 'note-123',
        'text': 'Additional text',
      });
      expect(okWithId.allowed, isTrue);
      expect(okWithId.effectiveRisk, RiskTier.r2);

      final okWithTitle = eval('notes.append', <String, Object?>{
        'title': 'Meeting Notes',
        'text': 'Additional text',
      });
      expect(okWithTitle.allowed, isTrue);

      // Null byte injection in text
      final nullText = eval('notes.append', <String, Object?>{
        'id': 'note-123',
        'text': 'Additional\x00text',
      });
      expect(nullText.allowed, isFalse);
      expect(nullText.errorCode, 'schema_mismatch');

      // Neither id nor title -> fails closed with missing_target (Rule H3)!
      final missingTarget = eval('notes.append', <String, Object?>{
        'text': 'Additional text',
      });
      expect(missingTarget.allowed, isFalse);
      expect(missingTarget.status, XtpStatus.invalidArgs);
      expect(missingTarget.errorCode, 'missing_target');
    });

    test('notes.search validates query and bounds maxResults', () {
      final ok = eval('notes.search', <String, Object?>{
        'query': 'project roadmap',
        'maxResults': 10,
      });
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r1);

      // Empty query
      final emptyQuery = eval('notes.search', <String, Object?>{
        'query': '   ',
      });
      expect(emptyQuery.allowed, isFalse);
      expect(emptyQuery.errorCode, 'schema_mismatch');

      // Out of bounds maxResults
      final badMax = eval('notes.search', <String, Object?>{
        'query': 'test',
        'maxResults': 50,
      });
      expect(badMax.allowed, isFalse);
    });

    test('reminders.create validates due date ISO format and priority', () {
      final ok = eval('reminders.create', <String, Object?>{
        'title': 'Buy groceries',
        'dueDate': '2026-11-16T18:00:00Z',
        'priority': 5,
        'list': 'Personal',
      });
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r2);

      // Invalid ISO date
      final badDate = eval('reminders.create', <String, Object?>{
        'title': 'Buy groceries',
        'dueDate': 'tomorrow at 5pm',
      });
      expect(badDate.allowed, isFalse);
      expect(badDate.errorCode, 'schema_mismatch');

      // Invalid priority (> 9)
      final badPriority = eval('reminders.create', <String, Object?>{
        'title': 'Buy groceries',
        'priority': 10,
      });
      expect(badPriority.allowed, isFalse);
    });

    test('calendar.list_events and calendar.create_event validate date ranges', () {
      final okList = eval('calendar.list_events', <String, Object?>{
        'timeMin': '2026-11-15T00:00:00Z',
        'timeMax': '2026-11-15T23:59:59Z',
      });
      expect(okList.allowed, isTrue);
      expect(okList.effectiveRisk, RiskTier.r1);

      // Inverted range
      final invertedList = eval('calendar.list_events', <String, Object?>{
        'timeMin': '2026-11-16T00:00:00Z',
        'timeMax': '2026-11-15T00:00:00Z',
      });
      expect(invertedList.allowed, isFalse);
      expect(invertedList.errorCode, 'invalid_date_range');

      final okCreate = eval('calendar.create_event', <String, Object?>{
        'title': 'Team Sync',
        'startTime': '2026-11-15T14:00:00Z',
        'endTime': '2026-11-15T15:00:00Z',
        'location': 'Room 101',
      });
      expect(okCreate.allowed, isTrue);
      expect(okCreate.effectiveRisk, RiskTier.r2);

      final invertedCreate = eval('calendar.create_event', <String, Object?>{
        'title': 'Team Sync',
        'startTime': '2026-11-15T16:00:00Z',
        'endTime': '2026-11-15T15:00:00Z',
      });
      expect(invertedCreate.allowed, isFalse);
      expect(invertedCreate.errorCode, 'invalid_date_range');
    });

    test('finder.reveal validates non-empty path and anti-injection (null byte)', () {
      final ok = eval('finder.reveal', <String, Object?>{
        'path': '/Users/alice/Documents/report.pdf',
      });
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r1);

      // Null byte injection attempt
      final nullByte = eval('finder.reveal', <String, Object?>{
        'path': '/Users/alice/Documents/report.pdf\x00malicious',
      });
      expect(nullByte.allowed, isFalse);
      expect(nullByte.errorCode, 'schema_mismatch');

      // Empty path
      final emptyPath = eval('finder.reveal', <String, Object?>{
        'path': '   ',
      });
      expect(emptyPath.allowed, isFalse);
    });

    test('shortcuts.run enforces strict naming regex against flag/path injection', () {
      final ok = eval('shortcuts.run', <String, Object?>{
        'shortcutName': 'Morning Routine 2',
        'input': 'start',
      });
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r2);

      // Flag injection or path traversal in shortcut name
      final pathTraversal = eval('shortcuts.run', <String, Object?>{
        'shortcutName': '../../bin/sh',
      });
      expect(pathTraversal.allowed, isFalse);
      expect(pathTraversal.errorCode, 'schema_mismatch');

      final flagInjection = eval('shortcuts.run', <String, Object?>{
        'shortcutName': '; rm -rf /',
      });
      expect(flagInjection.allowed, isFalse);

      // Flag injection attempts: -v, --version, -i
      for (final flag in <String>['-v', '--version', '-i', '-help', '--output']) {
        final flagRes = eval('shortcuts.run', <String, Object?>{
          'shortcutName': flag,
        });
        expect(flagRes.allowed, isFalse);
        expect(flagRes.status, XtpStatus.invalidArgs);
        expect(flagRes.errorCode, 'schema_mismatch');
      }
    });

    test('mail.create_draft enforces draft-only and blocks send flags and header injections', () {
      final ok = eval('mail.create_draft', <String, Object?>{
        'to': <String>['boss@company.com', 'colleague@company.com'],
        'subject': 'Weekly Status Update',
        'body': 'Here is the summary of work done this week.',
      });
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r2);

      // Model trying to pass send: true -> schema_mismatch!
      final sendAttempt = eval('mail.create_draft', <String, Object?>{
        'to': <String>['boss@company.com'],
        'subject': 'Hi',
        'body': 'Body',
        'send': true,
      });
      expect(sendAttempt.allowed, isFalse);
      expect(sendAttempt.errorCode, 'schema_mismatch');

      // Header injection attempt in subject
      final headerInjection = eval('mail.create_draft', <String, Object?>{
        'to': <String>['boss@company.com'],
        'subject': 'Status\r\nBcc: evil@hacker.com',
        'body': 'Body',
      });
      expect(headerInjection.allowed, isFalse);
      expect(headerInjection.errorCode, 'schema_mismatch');

      // Empty recipient list
      final emptyTo = eval('mail.create_draft', <String, Object?>{
        'to': <String>[],
        'subject': 'Test',
        'body': 'Body',
      });
      expect(emptyTo.allowed, isFalse);
      expect(emptyTo.errorCode, 'schema_mismatch');

      // Malformed email
      final badEmail = eval('mail.create_draft', <String, Object?>{
        'to': <String>['not-an-email'],
        'subject': 'Test',
        'body': 'Body',
      });
      expect(badEmail.allowed, isFalse);
      expect(badEmail.errorCode, 'schema_mismatch');

      // Unquoted space or comma in email address
      final unquotedSpace = eval('mail.create_draft', <String, Object?>{
        'to': <String>['bad email@domain.com'],
        'subject': 'Test',
        'body': 'Body',
      });
      expect(unquotedSpace.allowed, isFalse);
      expect(unquotedSpace.errorCode, 'schema_mismatch');

      final unquotedComma = eval('mail.create_draft', <String, Object?>{
        'to': <String>['user1@domain.com, user2@domain.com'],
        'subject': 'Test',
        'body': 'Body',
      });
      expect(unquotedComma.allowed, isFalse);
      expect(unquotedComma.errorCode, 'schema_mismatch');
    });
  });
}
