/// Native OS application bridge and Browser tool descriptors (`UDC-18` §3.1 & Wave B).
library;

import 'core_types.dart';

/// Normative Native OS App tool descriptors (`UDC-18` §3.1).
List<ToolDescriptor> buildNativeAppToolCatalog({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    buildNotesCreateTool(defaultPermission: defaultPermission),
    buildNotesAppendTool(defaultPermission: defaultPermission),
    buildNotesSearchTool(defaultPermission: defaultPermission),
    buildRemindersCreateTool(defaultPermission: defaultPermission),
    buildCalendarListEventsTool(defaultPermission: defaultPermission),
    buildCalendarCreateEventTool(defaultPermission: defaultPermission),
    buildFinderRevealTool(defaultPermission: defaultPermission),
    buildShortcutsRunTool(defaultPermission: defaultPermission),
    buildMailCreateDraftTool(defaultPermission: defaultPermission),
  ];
}

ToolDescriptor buildNotesCreateTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'notes.create',
      description: 'Create a new note in the native notes app.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'title': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 500,
            'description': 'Title of the note.',
          },
          'body': <String, Object?>{
            'type': 'string',
            'maxLength': 50000,
            'description': 'Body content of the note.',
          },
          'folder': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
            'description': 'Optional folder or category to store the note.',
          },
        },
        'required': <String>['title', 'body'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'string',
            'description': 'Created note identifier.',
          },
          'title': <String, Object?>{
            'type': 'string',
            'description': 'Note title.',
          },
          'folder': <String, Object?>{
            'type': 'string',
            'description': 'Folder where the note is stored.',
          },
        },
        'required': <String>['id', 'title'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildNotesAppendTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'notes.append',
      description: 'Append text to an existing note identified by id or title.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
            'description': 'Note identifier.',
          },
          'title': <String, Object?>{
            'type': 'string',
            'maxLength': 500,
            'description': 'Note title to search and append to.',
          },
          'text': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 50000,
            'description': 'Text to append to the note.',
          },
        },
        'required': <String>['text'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'string',
            'description': 'Note identifier.',
          },
          'title': <String, Object?>{
            'type': 'string',
            'description': 'Note title.',
          },
          'appended': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether the text was successfully appended.',
          },
        },
        'required': <String>['appended'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildNotesSearchTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'notes.search',
      description: 'Search existing notes by keyword query.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 200,
            'description': 'Search keyword query.',
          },
          'maxResults': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 20,
            'default': 5,
            'description': 'Maximum number of results to return.',
          },
        },
        'required': <String>['query'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'notes': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'id': <String, Object?>{'type': 'string'},
                'title': <String, Object?>{'type': 'string'},
                'snippet': <String, Object?>{'type': 'string'},
                'folder': <String, Object?>{'type': 'string'},
                'modifiedAt': <String, Object?>{'type': 'string'},
              },
              'required': <String>['id', 'title'],
              'additionalProperties': false,
            },
            'description': 'Matched notes.',
          },
          'total': <String, Object?>{
            'type': 'integer',
            'description': 'Total number of matched notes.',
          },
        },
        'required': <String>['notes', 'total'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
        idempotent: true,
      ),
    );

ToolDescriptor buildRemindersCreateTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'reminders.create',
      description: 'Create a reminder item with optional due date, list, and priority.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'title': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 500,
            'description': 'Title or description of the reminder.',
          },
          'list': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
            'description': 'Target reminder list.',
          },
          'dueDate': <String, Object?>{
            'type': 'string',
            'maxLength': 50,
            'description': 'Due date in ISO-8601 format.',
          },
          'notes': <String, Object?>{
            'type': 'string',
            'maxLength': 5000,
            'description': 'Additional notes for the reminder.',
          },
          'priority': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 9,
            'description': 'Priority level from 0 (none) to 9 (highest).',
          },
        },
        'required': <String>['title'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'string',
            'description': 'Created reminder identifier.',
          },
          'title': <String, Object?>{
            'type': 'string',
            'description': 'Reminder title.',
          },
          'list': <String, Object?>{
            'type': 'string',
            'description': 'List name.',
          },
          'dueDate': <String, Object?>{
            'type': 'string',
            'description': 'Due date.',
          },
        },
        'required': <String>['id', 'title'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildCalendarListEventsTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'calendar.list_events',
      description: 'List calendar events within a specified ISO-8601 time range.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'timeMin': <String, Object?>{
            'type': 'string',
            'description': 'Start of time range (inclusive) in ISO-8601 format.',
          },
          'timeMax': <String, Object?>{
            'type': 'string',
            'description': 'End of time range (inclusive) in ISO-8601 format.',
          },
          'calendarName': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
            'description': 'Filter by calendar name.',
          },
          'maxResults': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 50,
            'default': 10,
            'description': 'Maximum number of events to return.',
          },
        },
        'required': <String>['timeMin', 'timeMax'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'events': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'id': <String, Object?>{'type': 'string'},
                'title': <String, Object?>{'type': 'string'},
                'startTime': <String, Object?>{'type': 'string'},
                'endTime': <String, Object?>{'type': 'string'},
                'location': <String, Object?>{'type': 'string'},
                'notes': <String, Object?>{'type': 'string'},
                'calendar': <String, Object?>{'type': 'string'},
              },
              'required': <String>['id', 'title', 'startTime', 'endTime'],
              'additionalProperties': false,
            },
            'description': 'Calendar events.',
          },
          'total': <String, Object?>{
            'type': 'integer',
            'description': 'Total number of events.',
          },
        },
        'required': <String>['events', 'total'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
        idempotent: true,
      ),
    );

ToolDescriptor buildCalendarCreateEventTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'calendar.create_event',
      description: 'Create a new event in the native calendar.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'title': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 500,
            'description': 'Title of the event.',
          },
          'startTime': <String, Object?>{
            'type': 'string',
            'description': 'Start time in ISO-8601 format.',
          },
          'endTime': <String, Object?>{
            'type': 'string',
            'description': 'End time in ISO-8601 format.',
          },
          'location': <String, Object?>{
            'type': 'string',
            'maxLength': 500,
            'description': 'Location of the event.',
          },
          'notes': <String, Object?>{
            'type': 'string',
            'maxLength': 5000,
            'description': 'Description or notes for the event.',
          },
          'calendarName': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
            'description': 'Target calendar name.',
          },
        },
        'required': <String>['title', 'startTime', 'endTime'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'string',
            'description': 'Created event identifier.',
          },
          'title': <String, Object?>{
            'type': 'string',
            'description': 'Event title.',
          },
          'startTime': <String, Object?>{
            'type': 'string',
            'description': 'Start time.',
          },
          'endTime': <String, Object?>{
            'type': 'string',
            'description': 'End time.',
          },
          'calendar': <String, Object?>{
            'type': 'string',
            'description': 'Calendar name.',
          },
        },
        'required': <String>['id', 'title', 'startTime', 'endTime'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildFinderRevealTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'finder.reveal',
      description: 'Reveal a file or folder in Finder or File Explorer.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 1024,
            'description': 'Absolute or relative file/directory path to reveal.',
          },
        },
        'required': <String>['path'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'description': 'Path that was revealed.',
          },
          'revealed': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether the path was successfully revealed.',
          },
        },
        'required': <String>['path', 'revealed'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.files,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
        idempotent: true,
      ),
    );

ToolDescriptor buildShortcutsRunTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'shortcuts.run',
      description: 'Run an installed macOS Shortcut with optional input.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'shortcutName': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-zA-Z0-9][a-zA-Z0-9 _.-]{0,119}$',
            'description': 'Name of the shortcut to run.',
          },
          'input': <String, Object?>{
            'description': 'Optional input string or JSON for the shortcut.',
          },
        },
        'required': <String>['shortcutName'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'name': <String, Object?>{
            'type': 'string',
            'description': 'Shortcut name.',
          },
          'status': <String, Object?>{
            'type': 'string',
            'description': 'Execution status.',
          },
          'output': <String, Object?>{
            'type': 'string',
            'description': 'Output returned by the shortcut.',
          },
        },
        'required': <String>['name', 'status'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.workflow,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildMailCreateDraftTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'mail.create_draft',
      description:
          'Create a draft email in the default mail client. STRICTLY DRAFT-ONLY; NEVER SENDS.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'to': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
            'minItems': 1,
            'description': 'Recipient email addresses.',
          },
          'cc': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
            'description': 'Carbon copy recipient email addresses.',
          },
          'bcc': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
            'description': 'Blind carbon copy recipient email addresses.',
          },
          'subject': <String, Object?>{
            'type': 'string',
            'maxLength': 500,
            'description': 'Email subject line.',
          },
          'body': <String, Object?>{
            'type': 'string',
            'maxLength': 50000,
            'description': 'Email message body.',
          },
        },
        'required': <String>['to', 'subject', 'body'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'string',
            'description': 'Draft message identifier.',
          },
          'subject': <String, Object?>{
            'type': 'string',
            'description': 'Draft subject.',
          },
          'to': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
            'description': 'Recipient addresses.',
          },
          'isDraft': <String, Object?>{
            'type': 'boolean',
            'description': 'Confirmation that the message is a local draft.',
          },
        },
        'required': <String>['subject', 'to', 'isDraft'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

/// Maximum byte limit for tool output payloads (especially DOM/ARIA snapshots in `web.snapshot`).
const int maxToolOutputBytes = 6144;

/// Normative Browser tool catalog containing all 7 `web.*` tools (`UDC-18` §Wave B).
List<ToolDescriptor> buildBrowserToolCatalog({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    buildWebNavigateTool(defaultPermission: defaultPermission),
    buildWebSnapshotTool(defaultPermission: defaultPermission),
    buildWebClickTool(defaultPermission: defaultPermission),
    buildWebFillTool(defaultPermission: defaultPermission),
    buildWebSelectTool(defaultPermission: defaultPermission),
    buildWebExtractTool(defaultPermission: defaultPermission),
    buildWebWaitForTool(defaultPermission: defaultPermission),
  ];
}

ToolDescriptor buildWebNavigateTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'web.navigate',
      description:
          'Navigate browser page to a public HTTPS URL with strict anti-SSRF validation.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'url': <String, Object?>{
            'type': 'string',
            'maxLength': 2048,
            'description': 'Public HTTPS URL to navigate to.',
          },
          'timeoutMs': <String, Object?>{
            'type': 'integer',
            'minimum': 1000,
            'maximum': 60000,
            'default': 30000,
            'description': 'Navigation timeout in milliseconds (1000..60000).',
          },
        },
        'required': <String>['url'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'url': <String, Object?>{
            'type': 'string',
            'description': 'Navigated URL.',
          },
          'title': <String, Object?>{
            'type': 'string',
            'description': 'Page title after navigation.',
          },
          'status': <String, Object?>{
            'type': 'integer',
            'description': 'HTTP response status code.',
          },
          'navigated': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether navigation succeeded.',
          },
          'loaded': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether page is loaded.',
          },
        },
        'required': <String>['url'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildWebSnapshotTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'web.snapshot',
      description:
          'Capture compact accessibility DOM/ARIA tree snapshot bounded by MAX_TOOL_OUTPUT_BYTES.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'compact': <String, Object?>{
            'type': 'boolean',
            'default': true,
            'description': 'Whether to format output as compact ARIA tree.',
          },
          'maxBytes': <String, Object?>{
            'type': 'integer',
            'minimum': 100,
            'maximum': 6144,
            'default': 6144,
            'description': 'Maximum output byte size (up to 6144).',
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'snapshotId': <String, Object?>{
            'type': 'string',
            'description': 'Unique identifier for snapshot.',
          },
          'compactAriaTree': <String, Object?>{
            'type': 'string',
            'description': 'Compact ARIA / DOM snapshot tree.',
          },
          'snapshot': <String, Object?>{
            'type': 'string',
            'description': 'Compact ARIA snapshot text.',
          },
          'url': <String, Object?>{
            'type': 'string',
            'description': 'Current page URL.',
          },
          'title': <String, Object?>{
            'type': 'string',
            'description': 'Current page title.',
          },
          'pageTitle': <String, Object?>{
            'type': 'string',
            'description': 'Current page title.',
          },
          'elementCount': <String, Object?>{
            'type': 'integer',
            'description': 'Length of elements in snapshot.',
          },
          'byteCount': <String, Object?>{
            'type': 'integer',
            'description': 'Length of snapshot payload in bytes.',
          },
          'truncated': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether output was truncated to fit byte limit.',
          },
          'elements': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'object'},
            'description': 'Structured elements in snapshot.',
          },
        },
        'required': <String>['url'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
        idempotent: true,
      ),
    );

ToolDescriptor buildWebClickTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'web.click',
      description:
          'Click an interactive web element by ref or selector. Elevates to R3 for consequential actions.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ref': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 200,
            'description': 'Snapshot-qualified element reference (e.g. @s1:e5).',
          },
          'selector': <String, Object?>{
            'type': 'string',
            'maxLength': 500,
            'description': 'Optional CSS selector fallback.',
          },
          'targetText': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
            'description': 'Optional element text for consequential risk analysis.',
          },
        },
        'required': <String>['ref'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ref': <String, Object?>{
            'type': 'string',
            'description': 'Element reference clicked.',
          },
          'clicked': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether the click succeeded.',
          },
          'action': <String, Object?>{
            'type': 'string',
            'description': 'Action performed.',
          },
          'pageTitle': <String, Object?>{
            'type': 'string',
            'description': 'Page title at time of click.',
          },
          'elevatedToR3': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether the action was elevated to R3.',
          },
          'role': <String, Object?>{
            'type': 'string',
            'description': 'Role of element clicked.',
          },
          'targetText': <String, Object?>{
            'type': 'string',
            'description': 'Observed label or text of clicked element.',
          },
        },
        'required': <String>['ref', 'clicked'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildWebFillTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'web.fill',
      description:
          'Fill text into an input field by ref or selector. Elevates to R3 for consequential/sensitive fields.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ref': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 200,
            'description': 'Snapshot-qualified element reference.',
          },
          'value': <String, Object?>{
            'type': 'string',
            'maxLength': 10000,
            'description': 'Text value to fill into the input.',
          },
          'selector': <String, Object?>{
            'type': 'string',
            'maxLength': 500,
            'description': 'Optional CSS selector fallback.',
          },
          'targetText': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
            'description': 'Optional label/placeholder for consequential risk analysis.',
          },
        },
        'required': <String>['ref', 'value'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ref': <String, Object?>{
            'type': 'string',
            'description': 'Element reference filled.',
          },
          'filled': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether the input was filled.',
          },
          'valueLength': <String, Object?>{
            'type': 'integer',
            'description': 'Length of text filled.',
          },
          'elevatedToR3': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether the fill was elevated to R3.',
          },
        },
        'required': <String>['ref', 'filled'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildWebSelectTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'web.select',
      description:
          'Select an option in a dropdown element by ref or selector.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ref': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 200,
            'description': 'Dropdown element reference.',
          },
          'value': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 500,
            'description': 'Option value or text label to select.',
          },
          'selector': <String, Object?>{
            'type': 'string',
            'maxLength': 500,
            'description': 'Optional CSS selector fallback.',
          },
        },
        'required': <String>['ref', 'value'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ref': <String, Object?>{
            'type': 'string',
            'description': 'Dropdown element reference.',
          },
          'value': <String, Object?>{
            'type': 'string',
            'description': 'Value selected.',
          },
          'selectedValue': <String, Object?>{
            'type': 'string',
            'description': 'Selected value.',
          },
          'selected': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether the option was selected.',
          },
        },
        'required': <String>['ref', 'selected'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
        idempotent: false,
      ),
    );

ToolDescriptor buildWebExtractTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'web.extract',
      description:
          'Extract text content or attribute value from an element or page.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ref': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
            'description': 'Element reference to extract from.',
          },
          'selector': <String, Object?>{
            'type': 'string',
            'maxLength': 500,
            'description': 'CSS selector to extract from.',
          },
          'attribute': <String, Object?>{
            'type': 'string',
            'maxLength': 100,
            'description':
                'HTML attribute to extract (e.g. href, src). Omit for inner text.',
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ref': <String, Object?>{
            'type': 'string',
            'description': 'Element reference.',
          },
          'attribute': <String, Object?>{
            'type': 'string',
            'description': 'Attribute extracted, if specified.',
          },
          'value': <String, Object?>{
            'type': 'string',
            'description': 'Extracted text or attribute value.',
          },
          'content': <String, Object?>{
            'type': 'string',
            'description': 'Extracted content.',
          },
          'title': <String, Object?>{
            'type': 'string',
            'description': 'Page title.',
          },
          'url': <String, Object?>{
            'type': 'string',
            'description': 'Page URL.',
          },
          'elementCount': <String, Object?>{
            'type': 'integer',
            'description': 'Element count.',
          },
          'extracted': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether extraction succeeded.',
          },
        },
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
        idempotent: true,
      ),
    );

ToolDescriptor buildWebWaitForTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) =>
    ToolDescriptor(
      name: 'web.wait_for',
      description:
          'Wait for an element to reach a target state (visible, hidden, attached, detached) with bounded timeout.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'selector': <String, Object?>{
            'type': 'string',
            'maxLength': 500,
            'description': 'CSS or XPath selector to wait for.',
          },
          'state': <String, Object?>{
            'type': 'string',
            'enum': <String>['visible', 'hidden', 'attached', 'detached'],
            'default': 'visible',
            'description': 'Desired element state.',
          },
          'timeoutMs': <String, Object?>{
            'type': 'integer',
            'minimum': 100,
            'maximum': 30000,
            'default': 5000,
            'description': 'Timeout in milliseconds (100..30000).',
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'selector': <String, Object?>{
            'type': 'string',
            'description': 'Selector waited for.',
          },
          'state': <String, Object?>{
            'type': 'string',
            'description': 'State reached.',
          },
          'waited': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether wait completed.',
          },
          'satisfied': <String, Object?>{
            'type': 'boolean',
            'description': 'Whether the condition was satisfied within timeout.',
          },
          'elapsedMs': <String, Object?>{
            'type': 'integer',
            'description': 'Time elapsed in milliseconds.',
          },
        },
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
        idempotent: true,
      ),
    );
