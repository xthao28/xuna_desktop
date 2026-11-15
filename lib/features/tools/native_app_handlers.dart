import 'package:xuna_desktop/features/native_bridge/native_app_bridge.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';

/// Builds the default list of 9 native application tool handlers (`UDC-18` §3.1).
List<HostToolHandler> defaultNativeAppToolHandlers(NativeAppBridge bridge) =>
    <HostToolHandler>[
      NotesCreateTool(bridge),
      NotesAppendTool(bridge),
      NotesSearchTool(bridge),
      RemindersCreateTool(bridge),
      CalendarListEventsTool(bridge),
      CalendarCreateEventTool(bridge),
      FinderRevealTool(bridge),
      ShortcutsRunTool(bridge),
      MailCreateDraftTool(bridge),
    ];

class NotesCreateTool extends HostToolHandler {
  const NotesCreateTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'notes.create';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final title = context.arguments['title']! as String;
    final body = context.arguments['body']! as String;
    final folder = context.arguments['folder'] as String?;

    final result = await bridge.notesCreate(
      title: title,
      body: body,
      folder: folder,
    );
    return ToolHandlerOutput(
      text: 'Đã tạo ghi chú "$title".',
      structuredContent: result,
      toastBody: 'đã tạo ghi chú',
    );
  }
}

class NotesAppendTool extends HostToolHandler {
  const NotesAppendTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'notes.append';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final id = context.arguments['id'] as String?;
    final title = context.arguments['title'] as String?;
    final text = context.arguments['text']! as String;

    final result = await bridge.notesAppend(id: id, title: title, text: text);
    return ToolHandlerOutput(
      text: 'Đã thêm nội dung vào ghi chú ${title ?? id ?? ""}.',
      structuredContent: result,
      toastBody: 'đã cập nhật ghi chú',
    );
  }
}

class NotesSearchTool extends HostToolHandler {
  const NotesSearchTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'notes.search';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final query = context.arguments['query']! as String;
    final maxResults = (context.arguments['maxResults'] as int?) ?? 5;

    final result = await bridge.notesSearch(
      query: query,
      maxResults: maxResults,
    );
    final total = result['total'] as int? ?? 0;
    return ToolHandlerOutput(
      text: 'Tìm thấy $total ghi chú khớp với "$query".',
      structuredContent: result,
    );
  }
}

class RemindersCreateTool extends HostToolHandler {
  const RemindersCreateTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'reminders.create';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final title = context.arguments['title']! as String;
    final list = context.arguments['list'] as String?;
    final dueDate = context.arguments['dueDate'] as String?;
    final notes = context.arguments['notes'] as String?;
    final priority = context.arguments['priority'] as int?;

    final result = await bridge.remindersCreate(
      title: title,
      list: list,
      dueDate: dueDate,
      notes: notes,
      priority: priority,
    );
    return ToolHandlerOutput(
      text: 'Đã tạo lời nhắc "$title".',
      structuredContent: result,
      toastBody: 'đã tạo lời nhắc',
    );
  }
}

class CalendarListEventsTool extends HostToolHandler {
  const CalendarListEventsTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'calendar.list_events';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final timeMin = context.arguments['timeMin']! as String;
    final timeMax = context.arguments['timeMax']! as String;
    final calendarName = context.arguments['calendarName'] as String?;
    final maxResults = (context.arguments['maxResults'] as int?) ?? 10;

    final result = await bridge.calendarListEvents(
      timeMin: timeMin,
      timeMax: timeMax,
      calendarName: calendarName,
      maxResults: maxResults,
    );
    final total = result['total'] as int? ?? 0;
    return ToolHandlerOutput(
      text: 'Tìm thấy $total sự kiện lịch trong khoảng thời gian.',
      structuredContent: result,
    );
  }
}

class CalendarCreateEventTool extends HostToolHandler {
  const CalendarCreateEventTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'calendar.create_event';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final title = context.arguments['title']! as String;
    final startTime = context.arguments['startTime']! as String;
    final endTime = context.arguments['endTime']! as String;
    final location = context.arguments['location'] as String?;
    final notes = context.arguments['notes'] as String?;
    final calendarName = context.arguments['calendarName'] as String?;

    final result = await bridge.calendarCreateEvent(
      title: title,
      startTime: startTime,
      endTime: endTime,
      location: location,
      notes: notes,
      calendarName: calendarName,
    );
    return ToolHandlerOutput(
      text: 'Đã tạo sự kiện lịch "$title".',
      structuredContent: result,
      toastBody: 'đã tạo sự kiện lịch',
    );
  }
}

class FinderRevealTool extends HostToolHandler {
  const FinderRevealTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'finder.reveal';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final path = context.arguments['path']! as String;
    final result = await bridge.finderReveal(path: path);
    return ToolHandlerOutput(
      text: 'Đã hiển thị mục trong trình duyệt tệp: $path',
      structuredContent: result,
      toastBody: 'đã hiển thị tệp',
    );
  }
}

class ShortcutsRunTool extends HostToolHandler {
  const ShortcutsRunTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'shortcuts.run';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final shortcutName = context.arguments['shortcutName']! as String;
    final input = context.arguments['input'];

    final result = await bridge.shortcutsRun(
      shortcutName: shortcutName,
      input: input,
    );
    return ToolHandlerOutput(
      text: 'Đã thực thi phím tắt "$shortcutName".',
      structuredContent: result,
      toastBody: 'đã chạy phím tắt',
    );
  }
}

class MailCreateDraftTool extends HostToolHandler {
  const MailCreateDraftTool(this.bridge);

  final NativeAppBridge bridge;

  @override
  String get name => 'mail.create_draft';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final to = (context.arguments['to']! as List).cast<String>();
    final cc = (context.arguments['cc'] as List?)?.cast<String>();
    final bcc = (context.arguments['bcc'] as List?)?.cast<String>();
    final subject = context.arguments['subject']! as String;
    final body = context.arguments['body']! as String;

    final result = await bridge.mailCreateDraft(
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      body: body,
    );
    return ToolHandlerOutput(
      text: 'Đã tạo thư nháp đến ${to.join(", ")} ("$subject").',
      structuredContent: result,
      toastBody: 'đã tạo thư nháp',
    );
  }
}
