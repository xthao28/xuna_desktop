import 'dart:convert';

import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Builds the two fixed declarative capability adapter tool handlers
/// (`capability.list` and `capability.run`, `ADR-0021` §1 / P4.1).
List<HostToolHandler> defaultCapabilityToolHandlers() =>
    const <HostToolHandler>[
      CapabilityListTool(),
      CapabilityRunTool(),
    ];

/// `capability.list`: enumerates only approved local manifest adapters whose
/// target binary is currently detected and hash-verified on this host.
class CapabilityListTool extends HostToolHandler {
  const CapabilityListTool();

  @override
  String get name => 'capability.list';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final engine = context.capabilityEngine;
    if (engine == null) {
      return const ToolHandlerOutput(
        text: '0 capability adapter(s) detected',
        structuredContent: <String, Object?>{
          'adapters': <Object?>[],
          'totalDetected': 0,
        },
      );
    }
    final detected = await engine.listDetectedAdapters(
      capabilityFilter: context.arguments['capability'] as String?,
      formatFilter: context.arguments['format'] as String?,
    );
    return ToolHandlerOutput(
      text: '${detected.length} capability adapter(s) detected',
      structuredContent: <String, Object?>{
        'adapters': [for (final item in detected) item.toListWireJson()],
        'totalDetected': detected.length,
      },
    );
  }
}

/// `capability.run`: invokes one detected declarative capability adapter
/// directly without a shell and verifies declared `verifyFiles` outputs.
class CapabilityRunTool extends HostToolHandler {
  const CapabilityRunTool();

  @override
  String get name => 'capability.run';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final engine = context.capabilityEngine;
    if (engine == null) {
      return const ToolHandlerOutput(
        text: 'capability_not_found',
        structuredContent: <String, Object?>{
          'errorCode': 'capability_not_found',
        },
        status: XtpStatus.unsupported,
        errorCode: 'capability_not_found',
      );
    }
    final policy = context.policy;
    if (policy == null) {
      return const ToolHandlerOutput(
        text: 'policy_invalid',
        structuredContent: <String, Object?>{'errorCode': 'policy_invalid'},
        status: XtpStatus.denied,
        errorCode: 'policy_invalid',
      );
    }
    final adapterId = context.arguments['adapterId']! as String;
    final inputsJson = context.arguments['inputsJson']! as String;
    final draftId = context.arguments['draftId'] as String?;

    final Map<String, Object?> inputs;
    try {
      final decoded = jsonDecode(inputsJson);
      if (decoded is! Map) {
        return const ToolHandlerOutput(
          text: 'schema_mismatch',
          structuredContent: <String, Object?>{'errorCode': 'schema_mismatch'},
          status: XtpStatus.invalidArgs,
          errorCode: 'schema_mismatch',
        );
      }
      inputs = decoded.map((k, v) => MapEntry<String, Object?>(k.toString(), v));
    } on FormatException {
      return const ToolHandlerOutput(
        text: 'schema_mismatch',
        structuredContent: <String, Object?>{'errorCode': 'schema_mismatch'},
        status: XtpStatus.invalidArgs,
        errorCode: 'schema_mismatch',
      );
    }

    final outcome = await engine.runAdapter(
      adapterId: adapterId,
      rawInputs: inputs,
      shellControl: policy.shellControl,
      draftId: draftId,
      nowUtc: context.nowUtc,
    );
    if (outcome.succeeded) {
      return ToolHandlerOutput(
        text: 'capability.run completed exit=${outcome.exitCode ?? 0}',
        structuredContent: outcome.toStructuredContent(),
      );
    }
    final status = switch (outcome.status) {
      'timed_out' => XtpStatus.timeout,
      'cancelled' => XtpStatus.cancelled,
      _ => XtpStatus.failed,
    };
    return ToolHandlerOutput(
      text: 'capability.run failed ${outcome.errorCode ?? "failed"}',
      structuredContent: outcome.toStructuredContent(),
      status: status,
      errorCode: outcome.errorCode ?? 'capability_failed',
      remediation: outcome.remediation,
    );
  }
}
