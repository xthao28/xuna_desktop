import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'native_app_bridge.dart';

/// In-memory deterministic fake implementation of [NativeAppBridge] for testing.
class FakeNativeAppBridge implements NativeAppBridge {
  final List<Map<String, Object?>> recordedCalls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> notes = <Map<String, Object?>>[];
  final List<Map<String, Object?>> reminders = <Map<String, Object?>>[];
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];
  final List<Map<String, Object?>> drafts = <Map<String, Object?>>[];

  Exception? nextException;
  int _noteCounter = 0;
  int _remCounter = 0;
  int _eventCounter = 0;
  int _draftCounter = 0;

  @override
  Future<Map<String, Object?>> notesCreate({
    required String title,
    required String body,
    String? folder,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'notesCreate',
      'title': title,
      'body': body,
      'folder': folder,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    _noteCounter++;
    final note = <String, Object?>{
      'id': 'note-$_noteCounter',
      'title': title,
      'body': body,
      if (folder != null) 'folder': folder,
    };
    notes.add(note);
    return <String, Object?>{
      'id': note['id'],
      'title': title,
      if (folder != null) 'folder': folder,
    };
  }

  @override
  Future<Map<String, Object?>> notesAppend({
    String? id,
    String? title,
    required String text,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'notesAppend',
      'id': id,
      'title': title,
      'text': text,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    if (id == null && title == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'missing_target',
        message: 'Must provide either id or title to append to a note.',
      );
    }
    Map<String, Object?>? found;
    for (final note in notes) {
      if (id != null && note['id'] == id) {
        found = note;
        break;
      }
      if (title != null && note['title'] == title) {
        found = note;
        break;
      }
    }
    if (found == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'target_not_found',
        message: 'Note target was not found.',
      );
    }
    found['body'] = '${found['body']}\n$text';
    return <String, Object?>{
      'id': found['id']!,
      'title': found['title']!,
      'appended': true,
    };
  }

  @override
  Future<Map<String, Object?>> notesSearch({
    required String query,
    int maxResults = 5,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'notesSearch',
      'query': query,
      'maxResults': maxResults,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    final q = query.toLowerCase();
    final matched = <Map<String, Object?>>[];
    for (final note in notes) {
      final t = (note['title'] as String? ?? '').toLowerCase();
      final b = (note['body'] as String? ?? '').toLowerCase();
      if (t.contains(q) || b.contains(q)) {
        matched.add(<String, Object?>{
          'id': note['id']!,
          'title': note['title']!,
          'snippet': (note['body'] as String? ?? '').split('\n').first,
          'folder': note['folder'] ?? '',
          'modifiedAt': '2026-11-15T12:00:00Z',
        });
        if (matched.length >= maxResults) break;
      }
    }
    return <String, Object?>{'notes': matched, 'total': matched.length};
  }

  @override
  Future<Map<String, Object?>> remindersCreate({
    required String title,
    String? list,
    String? dueDate,
    String? notes,
    int? priority,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'remindersCreate',
      'title': title,
      'list': list,
      'dueDate': dueDate,
      'notes': notes,
      'priority': priority,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    _remCounter++;
    final rem = <String, Object?>{
      'id': 'rem-$_remCounter',
      'title': title,
      if (list != null) 'list': list,
      if (dueDate != null) 'dueDate': dueDate,
    };
    reminders.add(rem);
    return rem;
  }

  @override
  Future<Map<String, Object?>> calendarListEvents({
    required String timeMin,
    required String timeMax,
    String? calendarName,
    int maxResults = 10,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'calendarListEvents',
      'timeMin': timeMin,
      'timeMax': timeMax,
      'calendarName': calendarName,
      'maxResults': maxResults,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    final minDate = DateTime.parse(timeMin);
    final maxDate = DateTime.parse(timeMax);
    final matched = <Map<String, Object?>>[];
    for (final ev in events) {
      final s = DateTime.parse(ev['startTime'] as String);
      final e = DateTime.parse(ev['endTime'] as String);
      if (!s.isAfter(maxDate) && !e.isBefore(minDate)) {
        if (calendarName == null || ev['calendar'] == calendarName) {
          matched.add(ev);
          if (matched.length >= maxResults) break;
        }
      }
    }
    return <String, Object?>{'events': matched, 'total': matched.length};
  }

  @override
  Future<Map<String, Object?>> calendarCreateEvent({
    required String title,
    required String startTime,
    required String endTime,
    String? location,
    String? notes,
    String? calendarName,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'calendarCreateEvent',
      'title': title,
      'startTime': startTime,
      'endTime': endTime,
      'location': location,
      'notes': notes,
      'calendarName': calendarName,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    _eventCounter++;
    final ev = <String, Object?>{
      'id': 'evt-$_eventCounter',
      'title': title,
      'startTime': startTime,
      'endTime': endTime,
      if (location != null) 'location': location,
      if (notes != null) 'notes': notes,
      if (calendarName != null) 'calendar': calendarName,
    };
    events.add(ev);
    return <String, Object?>{
      'id': ev['id']!,
      'title': title,
      'startTime': startTime,
      'endTime': endTime,
      'calendar': calendarName ?? 'Default',
    };
  }

  @override
  Future<Map<String, Object?>> finderReveal({required String path}) async {
    recordedCalls.add(<String, Object?>{
      'method': 'finderReveal',
      'path': path,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    if (path.contains('nonexistent') || path.contains('missing')) {
      throw XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'file_not_found',
        message: 'File not found: $path',
      );
    }
    return <String, Object?>{'path': path, 'revealed': true};
  }

  @override
  Future<Map<String, Object?>> shortcutsRun({
    required String shortcutName,
    Object? input,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'shortcutsRun',
      'shortcutName': shortcutName,
      'input': input,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    if (shortcutName.startsWith('-')) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'schema_mismatch',
        message: 'Shortcut name cannot start with a hyphen or flag.',
      );
    }
    if (shortcutName == 'missing_shortcut') {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'shortcut_execution_failed',
        message: 'Shortcut missing_shortcut was not found.',
      );
    }
    return <String, Object?>{
      'name': shortcutName,
      'status': 'completed',
      'output': 'Shortcut $shortcutName executed successfully.',
    };
  }

  @override
  Future<Map<String, Object?>> mailCreateDraft({
    required List<String> to,
    List<String>? cc,
    List<String>? bcc,
    required String subject,
    required String body,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'mailCreateDraft',
      'to': to,
      'cc': cc,
      'bcc': bcc,
      'subject': subject,
      'body': body,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    _draftCounter++;
    final draft = <String, Object?>{
      'id': 'draft-$_draftCounter',
      'subject': subject,
      'to': to,
      'isDraft': true,
    };
    drafts.add(draft);
    return draft;
  }
}
