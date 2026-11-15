import 'dart:async';

/// Abstract interface for executing native OS application bridge operations (`UDC-18` §3.1).
abstract interface class NativeAppBridge {
  /// Creates a note in the native notes application.
  Future<Map<String, Object?>> notesCreate({
    required String title,
    required String body,
    String? folder,
  });

  /// Appends text to an existing note identified by [id] or [title].
  Future<Map<String, Object?>> notesAppend({
    String? id,
    String? title,
    required String text,
  });

  /// Searches notes matching [query].
  Future<Map<String, Object?>> notesSearch({
    required String query,
    int maxResults = 5,
  });

  /// Creates a reminder in the native reminders application.
  Future<Map<String, Object?>> remindersCreate({
    required String title,
    String? list,
    String? dueDate,
    String? notes,
    int? priority,
  });

  /// Lists calendar events within the given ISO-8601 time window.
  Future<Map<String, Object?>> calendarListEvents({
    required String timeMin,
    required String timeMax,
    String? calendarName,
    int maxResults = 10,
  });

  /// Creates an event in the native calendar.
  Future<Map<String, Object?>> calendarCreateEvent({
    required String title,
    required String startTime,
    required String endTime,
    String? location,
    String? notes,
    String? calendarName,
  });

  /// Reveals [path] in the native file manager (Finder / File Explorer).
  Future<Map<String, Object?>> finderReveal({
    required String path,
  });

  /// Runs an installed OS shortcut by [shortcutName] with optional [input].
  Future<Map<String, Object?>> shortcutsRun({
    required String shortcutName,
    Object? input,
  });

  /// Creates a draft email in the default mail client.
  ///
  /// STRICTLY DRAFT-ONLY. Never sends externally without separate R3 approval.
  Future<Map<String, Object?>> mailCreateDraft({
    required List<String> to,
    List<String>? cc,
    List<String>? bcc,
    required String subject,
    required String body,
  });
}
