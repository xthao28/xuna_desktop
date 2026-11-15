import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'native_app_bridge.dart';

typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// macOS implementation of [NativeAppBridge] using `osascript` with process arguments
/// (`argv`) or the native `/usr/bin/shortcuts` CLI (`UDC-18` §3.1).
///
/// ZERO string concatenation or interpolation is performed inside script templates;
/// all user arguments are passed strictly through the process arguments array (`argv`).
class MacosNativeAppBridge implements NativeAppBridge {
  MacosNativeAppBridge({ProcessRunner? processRunner})
    : _processRunner = processRunner ?? Process.run;

  final ProcessRunner _processRunner;

  static const _createNoteScript = '''
on run argv
    set noteTitle to item 1 of argv
    set noteBody to item 2 of argv
    set folderName to item 3 of argv
    tell application "Notes"
        if folderName is not "" and (exists folder folderName) then
            set targetFolder to folder folderName
            set newNote to make new note at targetFolder with properties {name:noteTitle, body:noteBody}
        else
            set newNote to make new note with properties {name:noteTitle, body:noteBody}
        end if
        return id of newNote
    end tell
end run
''';

  static const _appendNoteScript = '''
on run argv
    set targetId to item 1 of argv
    set targetTitle to item 2 of argv
    set appendText to item 3 of argv
    tell application "Notes"
        set foundNote to missing value
        if targetId is not "" then
            try
                set foundNote to note id targetId
            end try
        end if
        if foundNote is missing value and targetTitle is not "" then
            set matchingNotes to (every note whose name is targetTitle)
            if (count of matchingNotes) > 0 then
                set foundNote to item 1 of matchingNotes
            end if
        end if
        if foundNote is not missing value then
            set body of foundNote to (body of foundNote & "<br>" & appendText)
            return id of foundNote
        else
            error "target_not_found"
        end if
    end tell
end run
''';

  static const _searchNotesScript = '''
on run argv
    set queryText to item 1 of argv
    set maxCount to (item 2 of argv) as integer
    tell application "Notes"
        set matchingNotes to (every note whose name contains queryText or body contains queryText)
        set outList to {}
        set matchLen to count of matchingNotes
        if matchLen > maxCount then set matchLen to maxCount
        repeat with i from 1 to matchLen
            set aNote to item i of matchingNotes
            set end of outList to (id of aNote & "|||" & name of aNote)
        end repeat
        set AppleScript's text item delimiters to "%%%"
        return outList as text
    end tell
end run
''';

  static const _createReminderScript = '''
on run argv
    set remTitle to item 1 of argv
    set listName to item 2 of argv
    set dueStr to item 3 of argv
    set noteText to item 4 of argv
    set prioVal to (item 5 of argv) as integer
    tell application "Reminders"
        set targetList to default list
        if listName is not "" and (exists list listName) then
            set targetList to list listName
        end if
        tell targetList
            set newRem to make new reminder with properties {name:remTitle}
            if noteText is not "" then set body of newRem to noteText
            if prioVal > 0 then set priority of newRem to prioVal
            return id of newRem
        end tell
    end tell
end run
''';

  static const _calendarListScript = '''
function run(argv) {
  var timeMinStr = argv[0];
  var timeMaxStr = argv[1];
  var calFilter = argv[2];
  var maxResults = parseInt(argv[3], 10);
  var app = Application('Calendar');
  var minDate = new Date(timeMinStr);
  var maxDate = new Date(timeMaxStr);
  var events = [];
  var cals = calFilter ? app.calendars.whose({name: calFilter})() : app.calendars();
  for (var i = 0; i < cals.length; i++) {
    var calEvents = cals[i].events.whose({
      startDate: {_greaterThanEquals: minDate},
      endDate: {_lessThanEquals: maxDate}
    })();
    for (var j = 0; j < calEvents.length && events.length < maxResults; j++) {
      var ev = calEvents[j];
      events.push({
        id: ev.id(),
        title: ev.summary(),
        startTime: ev.startDate().toISOString(),
        endTime: ev.endDate().toISOString(),
        location: ev.location() || '',
        notes: ev.description() || '',
        calendar: cals[i].name()
      });
    }
  }
  return JSON.stringify({events: events, total: events.length});
}
''';

  static const _calendarCreateScript = '''
function run(argv) {
  var title = argv[0];
  var startStr = argv[1];
  var endStr = argv[2];
  var location = argv[3];
  var notes = argv[4];
  var calName = argv[5];
  var app = Application('Calendar');
  var targetCal = calName ? app.calendars.whose({name: calName})[0] : app.defaultCalendar();
  if (!targetCal) {
    targetCal = app.defaultCalendar();
  }
  var props = {
    summary: title,
    startDate: new Date(startStr),
    endDate: new Date(endStr)
  };
  if (location) props.location = location;
  if (notes) props.description = notes;
  var newEvent = app.Event(props);
  targetCal.events.push(newEvent);
  return JSON.stringify({
    id: newEvent.id(),
    title: title,
    startTime: startStr,
    endTime: endStr,
    calendar: targetCal.name()
  });
}
''';

  static const _revealFinderScript = '''
on run argv
    set targetPath to item 1 of argv
    tell application "Finder"
        reveal (POSIX file targetPath as alias)
        activate
    end tell
end run
''';

  static const _createMailDraftScript = '''
on run argv
    set toAddresses to item 1 of argv
    set ccAddresses to item 2 of argv
    set bccAddresses to item 3 of argv
    set msgSubject to item 4 of argv
    set msgBody to item 5 of argv
    tell application "Mail"
        set newMsg to make new outgoing message with properties {subject:msgSubject, content:msgBody, visible:false}
        tell newMsg
            set AppleScript's text item delimiters to ","
            repeat with toAddr in (text items of toAddresses)
                if toAddr is not "" then
                    make new to recipient with properties {address:toAddr}
                end if
            end repeat
            repeat with ccAddr in (text items of ccAddresses)
                if ccAddr is not "" then
                    make new cc recipient with properties {address:ccAddr}
                end if
            end repeat
            repeat with bccAddr in (text items of bccAddresses)
                if bccAddr is not "" then
                    make new bcc recipient with properties {address:bccAddr}
                end if
            end repeat
            save
        end tell
        return id of newMsg
    end tell
end run
''';

  @override
  Future<Map<String, Object?>> notesCreate({
    required String title,
    required String body,
    String? folder,
  }) async {
    final result = await _processRunner('osascript', <String>[
      '-e',
      _createNoteScript,
      title,
      body,
      folder ?? '',
    ]);
    if (result.exitCode != 0) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'native_notes_failed',
        message: result.stderr.toString().trim(),
      );
    }
    final noteId = result.stdout.toString().trim();
    return <String, Object?>{
      'id': noteId,
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
    final result = await _processRunner('osascript', <String>[
      '-e',
      _appendNoteScript,
      id ?? '',
      title ?? '',
      text,
    ]);
    if (result.exitCode != 0) {
      final err = result.stderr.toString().trim();
      if (err.contains('target_not_found')) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'target_not_found',
          message: 'Note target was not found in Notes.',
        );
      }
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'native_notes_failed',
        message: err,
      );
    }
    final noteId = result.stdout.toString().trim();
    return <String, Object?>{
      if (noteId.isNotEmpty) 'id': noteId,
      if (title != null) 'title': title,
      'appended': true,
    };
  }

  @override
  Future<Map<String, Object?>> notesSearch({
    required String query,
    int maxResults = 5,
  }) async {
    final result = await _processRunner('osascript', <String>[
      '-e',
      _searchNotesScript,
      query,
      maxResults.toString(),
    ]);
    if (result.exitCode != 0) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'native_notes_failed',
        message: result.stderr.toString().trim(),
      );
    }
    final raw = result.stdout.toString().trim();
    final notes = <Map<String, Object?>>[];
    if (raw.isNotEmpty) {
      final items = raw.split('%%%');
      for (final item in items) {
        final parts = item.split('|||');
        if (parts.length >= 2) {
          notes.add(<String, Object?>{
            'id': parts[0].trim(),
            'title': parts[1].trim(),
            'snippet': '',
            'folder': '',
            'modifiedAt': '',
          });
        }
      }
    }
    return <String, Object?>{'notes': notes, 'total': notes.length};
  }

  @override
  Future<Map<String, Object?>> remindersCreate({
    required String title,
    String? list,
    String? dueDate,
    String? notes,
    int? priority,
  }) async {
    final result = await _processRunner('osascript', <String>[
      '-e',
      _createReminderScript,
      title,
      list ?? '',
      dueDate ?? '',
      notes ?? '',
      (priority ?? 0).toString(),
    ]);
    if (result.exitCode != 0) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'native_reminders_failed',
        message: result.stderr.toString().trim(),
      );
    }
    final remId = result.stdout.toString().trim();
    return <String, Object?>{
      'id': remId,
      'title': title,
      if (list != null) 'list': list,
      if (dueDate != null) 'dueDate': dueDate,
    };
  }

  @override
  Future<Map<String, Object?>> calendarListEvents({
    required String timeMin,
    required String timeMax,
    String? calendarName,
    int maxResults = 10,
  }) async {
    final result = await _processRunner('osascript', <String>[
      '-l',
      'JavaScript',
      '-e',
      _calendarListScript,
      timeMin,
      timeMax,
      calendarName ?? '',
      maxResults.toString(),
    ]);
    if (result.exitCode != 0) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'native_calendar_failed',
        message: result.stderr.toString().trim(),
      );
    }
    try {
      final decoded =
          jsonDecode(result.stdout.toString().trim()) as Map<String, Object?>;
      return decoded;
    } catch (_) {
      return const <String, Object?>{
        'events': <Map<String, Object?>>[],
        'total': 0,
      };
    }
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
    final result = await _processRunner('osascript', <String>[
      '-l',
      'JavaScript',
      '-e',
      _calendarCreateScript,
      title,
      startTime,
      endTime,
      location ?? '',
      notes ?? '',
      calendarName ?? '',
    ]);
    if (result.exitCode != 0) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'native_calendar_failed',
        message: result.stderr.toString().trim(),
      );
    }
    final decoded =
        jsonDecode(result.stdout.toString().trim()) as Map<String, Object?>;
    return decoded;
  }

  @override
  Future<Map<String, Object?>> finderReveal({required String path}) async {
    final result = await _processRunner('osascript', <String>[
      '-e',
      _revealFinderScript,
      path,
    ]);
    if (result.exitCode != 0) {
      final err = result.stderr.toString().trim();
      throw XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'file_not_found',
        message: err.isNotEmpty ? err : 'Path not found: $path',
      );
    }
    return <String, Object?>{'path': path, 'revealed': true};
  }

  @override
  Future<Map<String, Object?>> shortcutsRun({
    required String shortcutName,
    Object? input,
  }) async {
    if (shortcutName.startsWith('-')) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'schema_mismatch',
        message: 'Shortcut name cannot start with a hyphen or flag.',
      );
    }
    final args = <String>['run', '--', shortcutName];
    if (input != null) {
      args.addAll(<String>['-i', input.toString()]);
    }
    final result = await _processRunner('/usr/bin/shortcuts', args);
    if (result.exitCode != 0) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'shortcut_execution_failed',
        message: result.stderr.toString().trim(),
      );
    }
    return <String, Object?>{
      'name': shortcutName,
      'status': 'completed',
      'output': result.stdout.toString().trim(),
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
    final result = await _processRunner('osascript', <String>[
      '-e',
      _createMailDraftScript,
      to.join(','),
      (cc ?? const <String>[]).join(','),
      (bcc ?? const <String>[]).join(','),
      subject,
      body,
    ]);
    if (result.exitCode != 0) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'native_mail_failed',
        message: result.stderr.toString().trim(),
      );
    }
    final draftId = result.stdout.toString().trim();
    return <String, Object?>{
      if (draftId.isNotEmpty) 'id': draftId,
      'subject': subject,
      'to': to,
      'isDraft': true,
    };
  }
}
