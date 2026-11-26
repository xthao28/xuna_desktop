/// Wave 3 direct file I/O (`fs.*`) and command execution (`exec.*`) tool
/// descriptors (`ADR-0018`, `XUNA_XTP_V1_CONTRACT.md` §8).
library;

import 'core_types.dart';

Map<String, Object?> _obj(
  Map<String, Object?> properties, {
  List<String> required = const <String>[],
}) =>
    <String, Object?>{
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    };

Map<String, Object?> _str(int min, int max) =>
    <String, Object?>{'type': 'string', 'minLength': min, 'maxLength': max};

Map<String, Object?> _int(int min, int max) =>
    <String, Object?>{'type': 'integer', 'minimum': min, 'maximum': max};

const Map<String, Object?> _bool = <String, Object?>{'type': 'boolean'};
const Map<String, Object?> _count = <String, Object?>{
  'type': 'integer',
  'minimum': 0,
};
const Map<String, Object?> _sha256 = <String, Object?>{
  'type': 'string',
  'pattern': r'^[0-9a-f]{64}$',
};
const Map<String, Object?> _taskId = <String, Object?>{
  'type': 'string',
  'pattern': r'^exec_[a-zA-Z0-9_-]{1,64}$',
};
const Map<String, Object?> _execStatus = <String, Object?>{
  'type': 'string',
  'enum': <String>['completed', 'running', 'failed', 'timed_out', 'cancelled'],
};
const Map<String, Object?> _output = <String, Object?>{
  'type': 'string',
  'maxLength': 16384,
};

/// `exec.run` `expectFiles` entries (upgrade plan P1.1 / U3).
final Map<String, Object?> _expectFiles = <String, Object?>{
  'type': 'array',
  'minItems': 1,
  'maxItems': 16,
  'items': _obj(<String, Object?>{
    'path': _str(1, 512),
    'minBytes': _count,
    'magic': const <String, Object?>{
      'type': 'string',
      'pattern': r'^([0-9a-fA-F]{2}){1,16}$',
    },
    'sha256': const <String, Object?>{
      'type': 'string',
      'pattern': r'^[0-9a-fA-F]{64}$',
    },
  }, required: <String>[
    'path'
  ]),
};

/// Facts about each expected file once an `exec` task exited 0; also the
/// artifact shape the effect manifest of the draft workspace (F1) reuses.
final Map<String, Object?> _artifacts = <String, Object?>{
  'type': 'array',
  'maxItems': 16,
  'items': _obj(<String, Object?>{
    'path': _str(1, 512),
    'exists': _bool,
    'sizeBytes': _count,
    'sha256': _sha256,
    'magicOk': _bool,
    'problem': const <String, Object?>{
      'type': 'string',
      'enum': <String>[
        'missing',
        'not_a_file',
        'too_small',
        'magic_mismatch',
        'sha256_mismatch',
        'too_large_to_hash',
        'unreadable',
        'forbidden',
      ],
    },
  }, required: <String>[
    'path',
    'exists'
  ]),
};
const Map<String, Object?> _expectedOutputError = <String, Object?>{
  'type': 'string',
  'enum': <String>['expected_output_missing', 'expected_output_mismatch'],
};

/// Builds the five `fs.*` descriptors (family `files`).
List<ToolDescriptor> buildFsTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  ToolPolicyMeta meta(RiskTier risk, {required bool observes}) =>
      ToolPolicyMeta(
        family: ToolFamily.files,
        risk: risk,
        observes: observes,
        reversible: observes,
        permission: defaultPermission,
      );
  final path = _str(1, 512);
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'fs.list_files',
      description:
          'List files under a local absolute path (bounded depth/entries; secret stores are never listed).',
      inputSchema: _obj(<String, Object?>{
        'path': path,
        'glob': _str(1, 128),
        'maxDepth': _int(1, 6),
        'maxEntries': _int(1, 200),
      }, required: <String>[
        'path'
      ]),
      outputSchema: _obj(<String, Object?>{
        'entries': <String, Object?>{
          'type': 'array',
          'items': _obj(<String, Object?>{
            'path': _str(1, 1024),
            'kind': const <String, Object?>{
              'type': 'string',
              'enum': <String>['file', 'dir'],
            },
            'sizeBytes': _count,
          }, required: <String>[
            'path',
            'kind'
          ]),
        },
        'truncated': _bool,
        'totalReturned': _count,
      }, required: <String>[
        'entries',
        'truncated',
        'totalReturned'
      ]),
      policy: meta(RiskTier.r1, observes: true),
    ),
    ToolDescriptor(
      name: 'fs.read_file',
      description:
          'Read up to 400 lines of a local text file (secret files refused, output redacted, <= 16 KiB).',
      inputSchema: _obj(<String, Object?>{
        'path': path,
        'startLine': _int(1, 1 << 30),
        'endLine': _int(1, 1 << 30),
      }, required: <String>[
        'path'
      ]),
      outputSchema: _obj(<String, Object?>{
        'content': _output,
        'startLine': _count,
        'endLine': _count,
        'totalLines': _count,
        'truncated': _bool,
      }, required: <String>[
        'content',
        'startLine',
        'endLine',
        'totalLines',
        'truncated',
      ]),
      policy: meta(RiskTier.r1, observes: true),
    ),
    ToolDescriptor(
      name: 'fs.grep',
      description:
          'Search local text files for a literal or regex pattern (bounded matches, redacted lines).',
      inputSchema: _obj(<String, Object?>{
        'path': path,
        'pattern': _str(1, 256),
        'isRegex': _bool,
        'glob': _str(1, 128),
        'maxMatches': _int(1, 100),
      }, required: <String>[
        'path',
        'pattern'
      ]),
      outputSchema: _obj(<String, Object?>{
        'matches': <String, Object?>{
          'type': 'array',
          'items': _obj(<String, Object?>{
            'path': _str(1, 1024),
            'line': _count,
            'text': _str(0, 400),
          }, required: <String>[
            'path',
            'line',
            'text'
          ]),
        },
        'truncated': _bool,
        'totalReturned': _count,
      }, required: <String>[
        'matches',
        'truncated',
        'totalReturned'
      ]),
      policy: meta(RiskTier.r1, observes: true),
    ),
    ToolDescriptor(
      name: 'fs.write_file',
      description:
          'Atomically write a local text file (R2 inside workspace roots, R3 outside or for dotfiles).',
      inputSchema: _obj(<String, Object?>{
        'path': path,
        'content': _str(0, 262144),
        'createParents': _bool,
        'overwrite': _bool,
      }, required: <String>[
        'path',
        'content'
      ]),
      outputSchema: _obj(<String, Object?>{
        'bytesWritten': _count,
        'created': _bool,
        'sha256': _sha256,
      }, required: <String>[
        'bytesWritten',
        'created',
        'sha256'
      ]),
      policy: meta(RiskTier.r2, observes: false),
    ),
    ToolDescriptor(
      name: 'fs.patch_file',
      description:
          'Replace an exact text occurrence in a local file (fails when missing or ambiguous; atomic).',
      inputSchema: _obj(<String, Object?>{
        'path': path,
        'target': _str(1, 65536),
        'replacement': _str(0, 65536),
        'replaceAll': _bool,
      }, required: <String>[
        'path',
        'target',
        'replacement'
      ]),
      outputSchema: _obj(<String, Object?>{
        'replacements': _count,
        'bytesWritten': _count,
        'sha256': _sha256,
      }, required: <String>[
        'replacements',
        'bytesWritten',
        'sha256'
      ]),
      policy: meta(RiskTier.r2, observes: false),
    ),
  ];
}

/// Builds the four `exec.*` descriptors (family `exec`). When the local
/// `shellControl` switch is off they are advertised `permission: denied`.
List<ToolDescriptor> buildExecTools({required bool shellEnabled}) {
  final permission =
      shellEnabled ? XtpPermissionState.granted : XtpPermissionState.denied;
  ToolPolicyMeta meta(RiskTier risk, {required bool observes}) =>
      ToolPolicyMeta(
        family: ToolFamily.exec,
        risk: risk,
        observes: observes,
        reversible: false,
        permission: permission,
      );
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'exec.run',
      description:
          'Run a local command in its own process group (host preflight: R2 local dev, R3 destructive/network, sudo/secrets refused). expectFiles: completed only if each file exists and matches.',
      inputSchema: _obj(<String, Object?>{
        'command': _str(1, 4096),
        'cwd': _str(1, 512),
        'timeoutMs': _int(1000, 300000),
        'yieldMs': _int(500, 60000),
        'pty': _bool,
        'expectFiles': _expectFiles,
      }, required: <String>[
        'command'
      ]),
      outputSchema: _obj(<String, Object?>{
        'status': _execStatus,
        'execTaskId': _taskId,
        'exitCode': const <String, Object?>{'type': 'integer'},
        'output': _output,
        'truncated': _bool,
        'durationMs': _count,
        'errorCode': _expectedOutputError,
        'artifacts': _artifacts,
      }, required: <String>[
        'status',
        'output',
        'truncated',
        'durationMs'
      ]),
      policy: meta(RiskTier.r2, observes: true),
    ),
    ToolDescriptor(
      name: 'exec.status',
      description:
          'Read the status, exit code and redacted output tail of an exec task.',
      inputSchema: _obj(<String, Object?>{
        'taskId': _taskId,
        'tailBytes': _int(256, 16384),
      }, required: <String>[
        'taskId'
      ]),
      outputSchema: _obj(<String, Object?>{
        'taskId': _taskId,
        'status': _execStatus,
        'exitCode': const <String, Object?>{'type': 'integer'},
        'output': _output,
        'truncated': _bool,
        'elapsedMs': _count,
        'errorCode': _expectedOutputError,
        'artifacts': _artifacts,
      }, required: <String>[
        'taskId',
        'status',
        'output',
        'truncated',
        'elapsedMs',
      ]),
      policy: meta(RiskTier.r1, observes: true),
    ),
    ToolDescriptor(
      name: 'exec.write_stdin',
      description:
          'Write text to the stdin of a running exec task (R3 when the task itself was R3).',
      inputSchema: _obj(<String, Object?>{
        'taskId': _taskId,
        'input': _str(0, 2048),
        'appendNewline': _bool,
        'eof': _bool,
      }, required: <String>[
        'taskId',
        'input'
      ]),
      outputSchema: _obj(<String, Object?>{
        'taskId': _taskId,
        'status': _execStatus,
        'bytesWritten': _count,
      }, required: <String>[
        'taskId',
        'status',
        'bytesWritten'
      ]),
      policy: meta(RiskTier.r2, observes: false),
    ),
    ToolDescriptor(
      name: 'exec.cancel',
      description: 'Terminate an exec task and its whole process group.',
      inputSchema: _obj(<String, Object?>{'taskId': _taskId},
          required: <String>['taskId']),
      outputSchema: _obj(<String, Object?>{
        'taskId': _taskId,
        'status': const <String, Object?>{
          'type': 'string',
          'enum': <String>['cancelled', 'already_finished'],
        },
        'signalSent': _bool,
      }, required: <String>[
        'taskId',
        'status',
        'signalSent'
      ]),
      policy: meta(RiskTier.r1, observes: false),
    ),
  ];
}
