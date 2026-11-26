import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'policy/fs_path_guard.dart' show hardDeniedPathReason, isSecretFileName;
import 'policy/security_redaction.dart'
    show
        hasBinaryOrInvalidSurrogates,
        isHardDeniedAppOrProcess,
        redactFilesystemPaths,
        redactSensitiveSelectionText;
import 'schemas.dart';

/// Maximum WebSocket text frame size in UTF-8 bytes (`512 KiB`).
const int maxXtpFrameBytes = 524288;

/// Maximum `structuredContent` size in UTF-8 bytes for ordinary tools (`16 KiB`).
const int maxStructuredContentBytes = 16384;

/// Maximum `structuredContent` size in UTF-8 bytes for media/screenshot tools (`448 KiB`),
/// leaving framing headroom inside [maxXtpFrameBytes].
const int maxMediaStructuredContentBytes = 458752;

bool _hasMediaStructuredContent(Map<Object?, Object?> sc) {
  final screenshot = sc['screenshot'];
  if (screenshot is Map && screenshot['dataBase64'] is String) {
    return true;
  }
  if (sc['dataBase64'] is String) {
    return true;
  }
  final image = sc['image'];
  if (image is Map && image['dataBase64'] is String) {
    return true;
  }
  return false;
}

/// JSON-RPC 2.0 protocol error codes (`XUNA_XTP_V1_CONTRACT.md` §5.2).
class JsonRpcErrorCode {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
}

/// WebSocket close codes (`XUNA_XTP_V1_CONTRACT.md` §5.3).
class XtpCloseCode {
  static const int goingAway = 1001;
  static const int unsupportedProtocol = 1002;
  static const int policyViolation = 1008;
  static const int frameTooLarge = 1009;
  static const int duplicateSession = 4001;
}

/// Exception thrown when an inbound or outbound XTP v1 frame violates the
/// JSON-RPC 2.0 or XTP wire contract.
class XtpProtocolException implements Exception {
  const XtpProtocolException({
    required this.jsonRpcCode,
    required this.message,
    this.requestId,
    this.closeCode,
    this.closeReason,
  });

  final int jsonRpcCode;
  final String message;
  final Object? requestId;
  final int? closeCode;
  final String? closeReason;

  XtpErrorResponse? toErrorResponse() {
    final id = requestId;
    if (id is! int && id is! String) return null;
    return XtpErrorResponse(id: id!, code: jsonRpcCode, message: message);
  }

  @override
  String toString() =>
      'XtpProtocolException(code: $jsonRpcCode, message: $message)';
}

/// Known XTP v1 JSON-RPC methods (`XUNA_XTP_V1_CONTRACT.md` §4).
const Set<String> knownXtpRequestMethods = <String>{
  'xuna/hello',
  'xuna/proof',
  'tools/list',
  'tools/call',
  'xuna/preflight',
  'ping',
  'xuna/get_policy',
  'xuna/set_policy',
  'xuna/watchRegister',
  'xuna/watchCancel',
};

const Set<String> knownXtpNotificationMethods = <String>{
  'xuna/challenge',
  'xuna/enrollPending',
  'xuna/enrolled',
  'xuna/ready',
  'notifications/cancelled',
  'notifications/progress',
  'notifications/tools/list_changed',
  'xuna/stop',
  'xuna/lanPeer',
  'xuna/presence',
  'xuna/resources',
  'xuna/focusRequest',
  'xuna/watchEvent',
};

/// Base class for all JSON-RPC 2.0 frames in XTP v1.
sealed class XtpFrame {
  const XtpFrame();

  Map<String, Object?> toJson();

  String encode() {
    final text = jsonEncode(toJson());
    final byteLen = utf8.encode(text).length;
    if (byteLen > maxXtpFrameBytes) {
      throw const XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidRequest,
        message: 'Frame exceeds 512 KiB limit',
        closeCode: XtpCloseCode.frameTooLarge,
        closeReason: 'frame_too_large',
      );
    }
    return text;
  }

  /// Parses and validates a raw UTF-8 JSON-RPC 2.0 frame string.
  static XtpFrame parse(String rawText) {
    final Uint8List utf8Bytes;
    try {
      utf8Bytes = Uint8List.fromList(utf8.encode(rawText));
    } catch (_) {
      throw const XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.parseError,
        message: 'Parse error',
        closeCode: XtpCloseCode.unsupportedProtocol,
        closeReason: 'unsupported_protocol',
      );
    }
    if (utf8Bytes.length > maxXtpFrameBytes) {
      throw const XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidRequest,
        message: 'Frame exceeds 512 KiB limit',
        closeCode: XtpCloseCode.frameTooLarge,
        closeReason: 'frame_too_large',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(rawText);
    } on FormatException {
      throw const XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.parseError,
        message: 'Parse error',
        closeCode: XtpCloseCode.unsupportedProtocol,
        closeReason: 'unsupported_protocol',
      );
    }

    if (decoded is! Map) {
      throw const XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidRequest,
        message: 'Invalid Request',
      );
    }
    final map = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        throw const XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request',
        );
      }
      map[entry.key as String] = entry.value;
    }

    final rawId = map['id'];
    if (map['jsonrpc'] != '2.0') {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidRequest,
        message: 'Invalid Request',
        requestId: rawId,
      );
    }

    if (map.containsKey('method')) {
      final method = map['method'];
      if (method is! String || method.isEmpty) {
        throw XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request',
          requestId: rawId,
        );
      }
      final hasId = map.containsKey('id');
      final allowedTopKeys = hasId
          ? const <String>{'jsonrpc', 'id', 'method', 'params'}
          : const <String>{'jsonrpc', 'method', 'params'};
      if (!_hasOnlyKeys(map, allowedTopKeys) || !map.containsKey('params')) {
        throw XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request',
          requestId: rawId,
        );
      }
      final paramsObj = map['params'];
      if (paramsObj is! Map) {
        throw XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidParams,
          message: 'Invalid params',
          requestId: rawId,
        );
      }
      final params = _castStringObjectMap(paramsObj, requestId: rawId);

      if (hasId) {
        if (rawId is! int && rawId is! String) {
          throw const XtpProtocolException(
            jsonRpcCode: JsonRpcErrorCode.invalidRequest,
            message: 'Invalid Request',
          );
        }
        if (!knownXtpRequestMethods.contains(method)) {
          throw XtpProtocolException(
            jsonRpcCode: JsonRpcErrorCode.methodNotFound,
            message: 'Method not found',
            requestId: rawId,
          );
        }
        final parsedParams = _parseRequestParams(method, params, rawId!);
        return XtpRequest(
          id: rawId,
          method: method,
          params: params,
          typedParams: parsedParams,
        );
      } else {
        if (!knownXtpNotificationMethods.contains(method)) {
          throw const XtpProtocolException(
            jsonRpcCode: JsonRpcErrorCode.methodNotFound,
            message: 'Method not found',
          );
        }
        final parsedParams = _parseNotificationParams(method, params);
        return XtpNotification(
          method: method,
          params: params,
          typedParams: parsedParams,
        );
      }
    }

    if (map.containsKey('result')) {
      if (!_hasOnlyKeys(map, const <String>{'jsonrpc', 'id', 'result'}) ||
          (rawId is! int && rawId is! String)) {
        throw const XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request',
        );
      }
      final resultObj = map['result'];
      if (resultObj is! Map) {
        throw XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request',
          requestId: rawId,
        );
      }
      final result = _castStringObjectMap(resultObj, requestId: rawId);
      _validateResultPayload(result, rawId!);
      return XtpResponse(id: rawId, result: result);
    }

    if (map.containsKey('error')) {
      if (!_hasOnlyKeys(map, const <String>{'jsonrpc', 'id', 'error'}) ||
          (rawId is! int && rawId is! String)) {
        throw const XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request',
        );
      }
      final errorObj = map['error'];
      if (errorObj is! Map) {
        throw XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request',
          requestId: rawId,
        );
      }
      final errorMap = _castStringObjectMap(errorObj, requestId: rawId);
      if (!_hasOnlyKeys(errorMap, const <String>{'code', 'message'}) ||
          errorMap['code'] is! int ||
          errorMap['message'] is! String) {
        throw XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request',
          requestId: rawId,
        );
      }
      return XtpErrorResponse(
        id: rawId!,
        code: errorMap['code'] as int,
        message: errorMap['message'] as String,
      );
    }

    throw XtpProtocolException(
      jsonRpcCode: JsonRpcErrorCode.invalidRequest,
      message: 'Invalid Request',
      requestId: rawId,
    );
  }
}

/// JSON-RPC 2.0 request frame (`id` present).
class XtpRequest extends XtpFrame {
  const XtpRequest({
    required this.id,
    required this.method,
    required this.params,
    required this.typedParams,
  });

  /// Builds an `xuna/watchRegister` request frame (`§4.2.14`).
  factory XtpRequest.watchRegister(Object id, WatchRegisterParams params) =>
      params.toRequest(id);

  /// Builds an `xuna/watchCancel` request frame (`§4.2.15`).
  factory XtpRequest.watchCancel(Object id, WatchCancelParams params) =>
      params.toRequest(id);

  final Object id;
  final String method;
  final Map<String, Object?> params;
  final XtpRequestParams typedParams;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      };
}

/// JSON-RPC 2.0 notification frame (`id` omitted).
class XtpNotification extends XtpFrame {
  const XtpNotification({
    required this.method,
    required this.params,
    required this.typedParams,
  });

  /// Builds an `xuna/watchEvent` notification frame (`§4.2.16`).
  factory XtpNotification.watchEvent(WatchEventParams params) =>
      params.toNotification();

  final String method;
  final Map<String, Object?> params;
  final XtpNotificationParams typedParams;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      };
}

/// JSON-RPC 2.0 success response frame.
class XtpResponse extends XtpFrame {
  XtpResponse({required this.id, required this.result}) {
    _validateResultPayload(result, id);
  }

  /// Builds a `tools/call` response frame (`XUNA_XTP_V1_CONTRACT.md` §4.2.2).
  factory XtpResponse.toolCallResult({
    required Object id,
    required String text,
    required Map<String, Object?> structuredContent,
    required XtpStatus status,
    required int durationMs,
    String? errorCode,
    XtpRemediation? remediation,
    bool allowMediaPayload = false,
  }) {
    final effectiveStructuredContent = remediation == null
        ? structuredContent
        : <String, Object?>{
            ...structuredContent,
            'remediation': remediation.toJson(),
          };
    final isMedia = allowMediaPayload ||
        _hasMediaStructuredContent(effectiveStructuredContent);
    final limit =
        isMedia ? maxMediaStructuredContentBytes : maxStructuredContentBytes;
    final scBytes = utf8.encode(jsonEncode(effectiveStructuredContent)).length;
    if (scBytes > limit) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'structuredContent exceeds ${limit ~/ 1024} KiB limit',
        requestId: id,
      );
    }
    final meta = <String, Object?>{
      'xuna/status': status.wire,
      if (errorCode != null) 'xuna/errorCode': errorCode,
      'xuna/durationMs': durationMs,
    };
    return XtpResponse(
      id: id,
      result: <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': text},
        ],
        'structuredContent': effectiveStructuredContent,
        'isError': status.isError,
        '_meta': meta,
      },
    );
  }

  /// Builds an `xuna/preflight` response frame (`XUNA_XTP_V1_CONTRACT.md`
  /// §4.2.8). [status] `ok` carries [effectiveRisk] and optional [elementName]
  /// / [preview]; any other status carries [errorCode] only.
  factory XtpResponse.preflightResult({
    required Object id,
    required XtpStatus status,
    RiskTier? effectiveRisk,
    String? reasonCode,
    String? errorCode,
    String? elementRole,
    String? elementName,
    XtpPreflightPreview? preview,
    String? effectSha256,
  }) {
    if ((preview != null || effectSha256 != null) && status != XtpStatus.ok) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'A refused preflight must not carry preview or effectSha256',
        requestId: id,
      );
    }
    if (effectSha256 != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(effectSha256)) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'Invalid preflight effectSha256 hex',
        requestId: id,
      );
    }
    final preflight = <String, Object?>{
      'status': status.wire,
      if (effectiveRisk != null) 'effectiveRisk': effectiveRisk.wire,
      if (reasonCode != null) 'reasonCode': reasonCode,
      if (errorCode != null) 'errorCode': errorCode,
      if (elementName != null)
        'element': <String, Object?>{
          'role': elementRole ?? 'unknown',
          'name': elementName,
        },
      if (preview != null) 'preview': preview.toJson(),
      if (effectSha256 != null) 'effectSha256': effectSha256,
    };
    return XtpResponse(
      id: id,
      result: <String, Object?>{'preflight': preflight},
    );
  }

  /// Builds an `xuna/watchRegister` response frame (`XUNA_XTP_V1_CONTRACT.md` §4.2.14).
  factory XtpResponse.watchRegisterResult({
    required Object id,
    required bool accepted,
    required String watchId,
    List<WatchSignal>? activeSignals,
    bool? eventDriven,
    bool? fallbackUsed,
    WatchRejectErrorCode? errorCode,
  }) {
    if (accepted) {
      if (activeSignals == null ||
          eventDriven == null ||
          fallbackUsed == null ||
          errorCode != null) {
        throw XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.invalidParams,
          message:
              'Accepted watchRegister result requires activeSignals, eventDriven, fallbackUsed and forbids errorCode',
          requestId: id,
        );
      }
      return XtpResponse(
        id: id,
        result: <String, Object?>{
          'schemaVersion': 1,
          'accepted': true,
          'watchId': watchId,
          'activeSignals': activeSignals.map((s) => s.wire).toList(),
          'eventDriven': eventDriven,
          'fallbackUsed': fallbackUsed,
        },
      );
    }
    if (errorCode == null ||
        activeSignals != null ||
        eventDriven != null ||
        fallbackUsed != null) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message:
            'Rejected watchRegister result requires errorCode and forbids activeSignals/eventDriven/fallbackUsed',
        requestId: id,
      );
    }
    return XtpResponse(
      id: id,
      result: <String, Object?>{
        'schemaVersion': 1,
        'accepted': false,
        'watchId': watchId,
        'errorCode': errorCode.wire,
      },
    );
  }

  /// Builds an accepted `xuna/watchRegister` response frame (`§4.2.14`).
  factory XtpResponse.watchRegisterAccepted({
    required Object id,
    required String watchId,
    required List<WatchSignal> activeSignals,
    required bool eventDriven,
    required bool fallbackUsed,
  }) =>
      XtpResponse.watchRegisterResult(
        id: id,
        accepted: true,
        watchId: watchId,
        activeSignals: activeSignals,
        eventDriven: eventDriven,
        fallbackUsed: fallbackUsed,
      );

  /// Builds a rejected `xuna/watchRegister` response frame (`§4.2.14`).
  factory XtpResponse.watchRegisterRejected({
    required Object id,
    required String watchId,
    required WatchRejectErrorCode errorCode,
  }) =>
      XtpResponse.watchRegisterResult(
        id: id,
        accepted: false,
        watchId: watchId,
        errorCode: errorCode,
      );

  /// Builds an `xuna/watchCancel` response frame (`XUNA_XTP_V1_CONTRACT.md` §4.2.15).
  factory XtpResponse.watchCancelResult({
    required Object id,
    required int cancelledCount,
  }) =>
      XtpResponse(
        id: id,
        result: <String, Object?>{
          'schemaVersion': 1,
          'cancelledCount': cancelledCount,
        },
      );

  final Object id;
  final Map<String, Object?> result;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };
}

/// JSON-RPC 2.0 protocol error response frame.
class XtpErrorResponse extends XtpFrame {
  const XtpErrorResponse({
    required this.id,
    required this.code,
    required this.message,
  });

  final Object id;
  final int code;
  final String message;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{
          'code': code,
          'message': message,
        },
      };
}

/// Base class for typed request parameters.
sealed class XtpRequestParams {
  const XtpRequestParams();
}

/// Mode A — Enrollment `xuna/hello` request params.
class HelloEnrollParams extends XtpRequestParams {
  const HelloEnrollParams({
    required this.protocols,
    required this.codeBytes,
    required this.publicKeyBytes,
    required this.platform,
    required this.osVersion,
    required this.agentVersion,
    required this.hostname,
  });

  final List<String> protocols;
  final Uint8List codeBytes;
  final Uint8List publicKeyBytes;
  final HostPlatform platform;
  final String osVersion;
  final String agentVersion;
  final String hostname;
}

/// Mode B — Reconnect `xuna/hello` request params.
class HelloReconnectParams extends XtpRequestParams {
  const HelloReconnectParams({
    required this.protocols,
    required this.hostId,
    required this.platform,
    required this.osVersion,
    required this.agentVersion,
  });

  final List<String> protocols;
  final String hostId;
  final HostPlatform platform;
  final String osVersion;
  final String agentVersion;
}

/// `xuna/proof` request params.
class ProofParams extends XtpRequestParams {
  const ProofParams({
    required this.purpose,
    required this.signatureBytes,
  });

  final HostProofPurpose purpose;
  final Uint8List signatureBytes;
}

/// `tools/list` request params.
class ToolsListParams extends XtpRequestParams {
  const ToolsListParams();
}

/// `tools/call` request params (`XUNA_XTP_V1_CONTRACT.md` §4.2.2).
class ToolsCallParams extends XtpRequestParams {
  const ToolsCallParams({
    required this.name,
    required this.arguments,
    required this.invocationId,
    required this.deadlineMs,
    this.approval,
  });

  final String name;
  final Map<String, Object?> arguments;
  final String invocationId;
  final int deadlineMs;
  final ApprovalToken? approval;
}

/// `xuna/preflight` request params (`XUNA_XTP_V1_CONTRACT.md` §4.2.8): the
/// backend asks the host which risk it would enforce for this call, without
/// executing anything.
class PreflightParams extends XtpRequestParams {
  const PreflightParams({required this.name, required this.arguments});

  final String name;
  final Map<String, Object?> arguments;
}

/// `ping` request params.
class PingParams extends XtpRequestParams {
  const PingParams();
}

/// `xuna/get_policy` request params (UDC-18).
class GetPolicyParams extends XtpRequestParams {
  const GetPolicyParams();
}

/// `xuna/set_policy` request params (UDC-18).
class SetPolicyParams extends XtpRequestParams {
  const SetPolicyParams({
    this.schemaVersion = 1,
    required this.trustPreset,
    this.allowApps = const <String>[],
    this.denyApps = const <String>[],
    this.allowDomains = const <String>[],
    this.denyDomains = const <String>[],
  });

  final int schemaVersion;
  final String trustPreset;
  final List<String> allowApps;
  final List<String> denyApps;
  final List<String> allowDomains;
  final List<String> denyDomains;
}

/// Observation mode for `xuna/watchRegister` (`XUNA_XTP_V1_CONTRACT.md` §4.2.14).
enum WatchMode {
  uiQuiescence('ui_quiescence'),
  uiChange('ui_change'),
  processIdle('process_idle'),
  fsQuiescence('fs_quiescence'),
  cdpIdle('cdp_idle'),
  composite('composite'),
  timer('timer'),
  protocolAsync('protocol_async'),

  /// Wakes a job when a detached `exec.run` task ends (`ADR-0018`).
  execAsync('exec_async');

  const WatchMode(this.wire);
  final String wire;

  static WatchMode fromWire(String value) => switch (value) {
        'ui_quiescence' => WatchMode.uiQuiescence,
        'ui_change' => WatchMode.uiChange,
        'process_idle' => WatchMode.processIdle,
        'fs_quiescence' => WatchMode.fsQuiescence,
        'cdp_idle' => WatchMode.cdpIdle,
        'composite' => WatchMode.composite,
        'timer' => WatchMode.timer,
        'protocol_async' => WatchMode.protocolAsync,
        'exec_async' => WatchMode.execAsync,
        _ => throw FormatException('Unknown WatchMode: $value'),
      };
}

/// Primitive signal kind used in `WatchRegisterParams.signals`,
/// `activeSignals`, and `observedSignals` (`§4.2.14`, `§4.2.16`).
enum WatchSignal {
  uiQuiescence('ui_quiescence'),
  uiChange('ui_change'),
  processIdle('process_idle'),
  fsQuiescence('fs_quiescence'),
  cdpIdle('cdp_idle'),
  timer('timer'),
  protocolAsync('protocol_async'),
  execAsync('exec_async');

  const WatchSignal(this.wire);
  final String wire;

  /// Subset of [WatchSignal] permitted inside `composite` watches.
  static const Set<WatchSignal> allowedCompositeSignals = <WatchSignal>{
    WatchSignal.uiQuiescence,
    WatchSignal.processIdle,
    WatchSignal.fsQuiescence,
    WatchSignal.cdpIdle,
  };

  static WatchSignal fromWire(String value) => switch (value) {
        'ui_quiescence' => WatchSignal.uiQuiescence,
        'ui_change' => WatchSignal.uiChange,
        'process_idle' => WatchSignal.processIdle,
        'fs_quiescence' => WatchSignal.fsQuiescence,
        'cdp_idle' => WatchSignal.cdpIdle,
        'timer' => WatchSignal.timer,
        'protocol_async' => WatchSignal.protocolAsync,
        'exec_async' => WatchSignal.execAsync,
        _ => throw FormatException('Unknown WatchSignal: $value'),
      };
}

/// Alias for callers referencing [WatchSignal] as `WatchSignalKind`.
typedef WatchSignalKind = WatchSignal;

/// Rejection error codes for `xuna/watchRegister` results (`§4.2.14`).
enum WatchRejectErrorCode {
  watchUnsupported('watch_unsupported'),
  targetNotFound('target_not_found'),
  workspaceNotFound('workspace_not_found'),
  watchLimitReached('watch_limit_reached'),
  needsPermission('needs_permission'),
  policyBlocked('policy_blocked'),
  stopped('stopped'),
  invalidArgs('invalid_args');

  const WatchRejectErrorCode(this.wire);
  final String wire;

  static WatchRejectErrorCode fromWire(String value) => switch (value) {
        'watch_unsupported' => WatchRejectErrorCode.watchUnsupported,
        'target_not_found' => WatchRejectErrorCode.targetNotFound,
        'workspace_not_found' => WatchRejectErrorCode.workspaceNotFound,
        'watch_limit_reached' => WatchRejectErrorCode.watchLimitReached,
        'needs_permission' => WatchRejectErrorCode.needsPermission,
        'policy_blocked' => WatchRejectErrorCode.policyBlocked,
        'stopped' => WatchRejectErrorCode.stopped,
        'invalid_args' => WatchRejectErrorCode.invalidArgs,
        _ => throw FormatException('Unknown WatchRejectErrorCode: $value'),
      };
}

/// Cancellation reason for `xuna/watchCancel` (`§4.2.15`).
enum WatchCancelReason {
  ownerCancel('owner_cancel'),
  estop('estop'),
  jobEnded('job_ended'),
  replaced('replaced'),
  expired('expired');

  const WatchCancelReason(this.wire);
  final String wire;

  static WatchCancelReason fromWire(String value) => switch (value) {
        'owner_cancel' => WatchCancelReason.ownerCancel,
        'estop' => WatchCancelReason.estop,
        'job_ended' => WatchCancelReason.jobEnded,
        'replaced' => WatchCancelReason.replaced,
        'expired' => WatchCancelReason.expired,
        _ => throw FormatException('Unknown WatchCancelReason: $value'),
      };
}

/// Terminal or progress event kind for `xuna/watchEvent` (`§4.2.16`).
enum WatchEventKind {
  settled('settled'),
  changed('changed'),
  timeout('timeout'),
  targetLost('target_lost'),
  error('error');

  const WatchEventKind(this.wire);
  final String wire;

  static WatchEventKind fromWire(String value) => switch (value) {
        'settled' => WatchEventKind.settled,
        'changed' => WatchEventKind.changed,
        'timeout' => WatchEventKind.timeout,
        'target_lost' => WatchEventKind.targetLost,
        'error' => WatchEventKind.error,
        _ => throw FormatException('Unknown WatchEventKind: $value'),
      };
}

/// Returns `true` when [value] is a canonical non-zero UUID string.
bool isValidNonZeroUuid(String value) =>
    isValidUuid(value) && value != '00000000-0000-0000-0000-000000000000';

final RegExp _asciiControlCharPattern = RegExp(r'[\x00-\x1f\x7f]');

/// Target descriptor for `xuna/watchRegister` (`§4.2.14`, `additionalProperties: false`).
class WatchTarget {
  const WatchTarget({
    this.pid,
    this.windowId,
    this.appId,
    this.workspaceAlias,
    this.tabId,
    this.mcpServerId,
    this.protocolTaskId,
    this.execTaskId,
  });

  factory WatchTarget.fromJson(Map<String, Object?> json) {
    _requireExactParamsKeys(
      json,
      const <String>{},
      optionalKeys: const <String>{
        'pid',
        'windowId',
        'appId',
        'workspaceAlias',
        'tabId',
        'mcpServerId',
        'protocolTaskId',
        'execTaskId',
      },
    );
    int? pid;
    if (json.containsKey('pid') && json['pid'] != null) {
      pid = _requireIntParam(json, 'pid');
    }
    int? windowId;
    if (json.containsKey('windowId') && json['windowId'] != null) {
      windowId = _requireIntParam(json, 'windowId');
    }
    String? appId;
    if (json.containsKey('appId') && json['appId'] != null) {
      appId = _requireStringParam(json, 'appId');
    }
    String? workspaceAlias;
    if (json.containsKey('workspaceAlias') && json['workspaceAlias'] != null) {
      workspaceAlias = _requireStringParam(json, 'workspaceAlias');
    }
    String? tabId;
    if (json.containsKey('tabId') && json['tabId'] != null) {
      tabId = _requireStringParam(json, 'tabId');
    }
    String? mcpServerId;
    if (json.containsKey('mcpServerId') && json['mcpServerId'] != null) {
      mcpServerId = _requireStringParam(json, 'mcpServerId');
    }
    String? protocolTaskId;
    if (json.containsKey('protocolTaskId') && json['protocolTaskId'] != null) {
      protocolTaskId = _requireStringParam(json, 'protocolTaskId');
    }
    String? execTaskId;
    if (json.containsKey('execTaskId') && json['execTaskId'] != null) {
      execTaskId = _requireStringParam(json, 'execTaskId');
    }
    final target = WatchTarget(
      pid: pid,
      windowId: windowId,
      appId: appId,
      workspaceAlias: workspaceAlias,
      tabId: tabId,
      mcpServerId: mcpServerId,
      protocolTaskId: protocolTaskId,
      execTaskId: execTaskId,
    );
    target.validate();
    return target;
  }

  final int? pid;
  final int? windowId;
  final String? appId;
  final String? workspaceAlias;
  final String? tabId;
  final String? mcpServerId;
  final String? protocolTaskId;

  /// `exec.run` task id for `exec_async` watches (`^exec_[a-zA-Z0-9_-]{1,64}$`).
  final String? execTaskId;

  void validate() {
    final p = pid;
    if (p != null && (p < 1 || p > 2147483647)) {
      throw const FormatException('target.pid must be in 1..2147483647');
    }
    final w = windowId;
    if (w != null && (w < 0 || w > 2147483647)) {
      throw const FormatException('target.windowId must be in 0..2147483647');
    }
    final app = appId;
    if (app != null &&
        (app.contains('\n') || app.contains('\r') || !isValidShortId(app))) {
      throw const FormatException('Invalid target.appId');
    }
    final alias = workspaceAlias;
    if (alias != null &&
        (alias.contains('/') ||
            alias.contains(r'\') ||
            alias == '.' ||
            alias == '..' ||
            alias.contains('..') ||
            alias.contains('\n') ||
            alias.contains('\r') ||
            !_workspaceAliasPattern.hasMatch(alias))) {
      throw const FormatException('Invalid target.workspaceAlias');
    }
    final tab = tabId;
    if (tab != null &&
        (tab.isEmpty ||
            tab.length > 128 ||
            _asciiControlCharPattern.hasMatch(tab))) {
      throw const FormatException('Invalid target.tabId');
    }
    final mcp = mcpServerId;
    if (mcp != null &&
        (mcp.contains('\n') || mcp.contains('\r') || !isValidShortId(mcp))) {
      throw const FormatException('Invalid target.mcpServerId');
    }
    final task = protocolTaskId;
    if (task != null &&
        (task.isEmpty ||
            task.length > 128 ||
            _asciiControlCharPattern.hasMatch(task))) {
      throw const FormatException('Invalid target.protocolTaskId');
    }
    final exec = execTaskId;
    if (exec != null && !RegExp(r'^exec_[a-zA-Z0-9_-]{1,64}$').hasMatch(exec)) {
      throw const FormatException('Invalid target.execTaskId');
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return <String, Object?>{
      if (pid != null) 'pid': pid,
      if (windowId != null) 'windowId': windowId,
      if (appId != null) 'appId': appId,
      if (workspaceAlias != null) 'workspaceAlias': workspaceAlias,
      if (tabId != null) 'tabId': tabId,
      if (mcpServerId != null) 'mcpServerId': mcpServerId,
      if (protocolTaskId != null) 'protocolTaskId': protocolTaskId,
      if (execTaskId != null) 'execTaskId': execTaskId,
    };
  }
}

/// `xuna/watchRegister` request params (`XUNA_XTP_V1_CONTRACT.md` §4.2.14).
class WatchRegisterParams extends XtpRequestParams {
  const WatchRegisterParams({
    this.schemaVersion = 1,
    required this.watchId,
    required this.jobId,
    required this.mode,
    this.signals,
    required this.target,
    required this.quiescenceSeconds,
    required this.minWaitSeconds,
    required this.maxWaitSeconds,
    required this.requireInitialChange,
    required this.releaseFocus,
  });

  final int schemaVersion;
  final String watchId;
  final String jobId;
  final WatchMode mode;
  final List<WatchSignal>? signals;
  final WatchTarget target;
  final int quiescenceSeconds;
  final int minWaitSeconds;
  final int maxWaitSeconds;
  final bool requireInitialChange;
  final bool releaseFocus;

  void validate() {
    if (schemaVersion != 1) {
      throw FormatException(
        'Unsupported xuna/watchRegister schemaVersion: $schemaVersion',
      );
    }
    if (!isValidNonZeroUuid(watchId)) {
      throw const FormatException('watchId must be a canonical non-zero UUID');
    }
    if (!isValidNonZeroUuid(jobId)) {
      throw const FormatException('jobId must be a canonical non-zero UUID');
    }
    if (mode == WatchMode.composite) {
      final sigs = signals;
      if (sigs == null || sigs.length < 2 || sigs.length > 3) {
        throw const FormatException(
          'composite mode requires 2..3 distinct signals',
        );
      }
      final seen = <WatchSignal>{};
      for (final s in sigs) {
        if (!WatchSignal.allowedCompositeSignals.contains(s)) {
          throw FormatException('Signal ${s.wire} not allowed in composite');
        }
        if (!seen.add(s)) {
          throw const FormatException('composite signals must be distinct');
        }
      }
    } else if (signals != null) {
      throw const FormatException(
        'signals is forbidden unless mode is composite',
      );
    }
    target.validate();
    if (quiescenceSeconds < 2 || quiescenceSeconds > 120) {
      throw const FormatException('quiescenceSeconds must be in 2..120');
    }
    if (minWaitSeconds < 0 || minWaitSeconds > 60) {
      throw const FormatException('minWaitSeconds must be in 0..60');
    }
    if (maxWaitSeconds < 5 || maxWaitSeconds > 900) {
      throw const FormatException('maxWaitSeconds must be in 5..900');
    }
    if (minWaitSeconds > maxWaitSeconds) {
      throw const FormatException(
        'minWaitSeconds must be <= maxWaitSeconds',
      );
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'watchId': watchId,
      'jobId': jobId,
      'mode': mode.wire,
      if (signals != null) 'signals': signals!.map((s) => s.wire).toList(),
      'target': target.toJson(),
      'quiescenceSeconds': quiescenceSeconds,
      'minWaitSeconds': minWaitSeconds,
      'maxWaitSeconds': maxWaitSeconds,
      'requireInitialChange': requireInitialChange,
      'releaseFocus': releaseFocus,
    };
  }

  XtpRequest toRequest(Object id) => XtpRequest(
        id: id,
        method: 'xuna/watchRegister',
        params: toJson(),
        typedParams: this,
      );
}

/// `xuna/watchCancel` request params (`XUNA_XTP_V1_CONTRACT.md` §4.2.15).
class WatchCancelParams extends XtpRequestParams {
  const WatchCancelParams({
    this.schemaVersion = 1,
    this.watchId,
    this.jobId,
    required this.reason,
  });

  final int schemaVersion;
  final String? watchId;
  final String? jobId;
  final WatchCancelReason reason;

  void validate() {
    if (schemaVersion != 1) {
      throw FormatException(
        'Unsupported xuna/watchCancel schemaVersion: $schemaVersion',
      );
    }
    if (watchId != null && !isValidNonZeroUuid(watchId!)) {
      throw const FormatException('watchId must be a canonical non-zero UUID');
    }
    if (jobId != null && !isValidNonZeroUuid(jobId!)) {
      throw const FormatException('jobId must be a canonical non-zero UUID');
    }
    if (reason != WatchCancelReason.estop && watchId == null && jobId == null) {
      throw const FormatException(
        'watchId or jobId is required unless reason is estop',
      );
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      if (watchId != null) 'watchId': watchId,
      if (jobId != null) 'jobId': jobId,
      'reason': reason.wire,
    };
  }

  XtpRequest toRequest(Object id) => XtpRequest(
        id: id,
        method: 'xuna/watchCancel',
        params: toJson(),
        typedParams: this,
      );
}

/// Base class for typed notification parameters.
sealed class XtpNotificationParams {
  const XtpNotificationParams();
}

/// `xuna/challenge` notification params.
class ChallengeParams extends XtpNotificationParams {
  const ChallengeParams({
    required this.purpose,
    required this.nonceBytes,
    required this.expiresIn,
  });

  final HostProofPurpose purpose;
  final Uint8List nonceBytes;
  final int expiresIn;
}

/// `xuna/enrollPending` notification params.
class EnrollPendingParams extends XtpNotificationParams {
  const EnrollPendingParams({required this.expiresIn});
  final int expiresIn;
}

/// `xuna/enrolled` notification params.
class EnrolledParams extends XtpNotificationParams {
  const EnrolledParams({required this.hostId, required this.alias});
  final String hostId;
  final String alias;
}

/// `xuna/ready` notification params.
class ReadyParams extends XtpNotificationParams {
  const ReadyParams({required this.serverTime, required this.heartbeatS});
  final DateTime serverTime;
  final int heartbeatS;
}

/// `notifications/cancelled` notification params.
class CancelledParams extends XtpNotificationParams {
  const CancelledParams({required this.requestId, required this.reason});
  final Object requestId;
  final String reason;
}

/// `notifications/progress` notification params.
class ProgressParams extends XtpNotificationParams {
  const ProgressParams({
    required this.progressToken,
    required this.progress,
    this.total,
    this.message,
  });

  final String progressToken;
  final int progress;
  final int? total;
  final String? message;
}

/// `notifications/tools/list_changed` notification params.
class ToolsListChangedParams extends XtpNotificationParams {
  const ToolsListChangedParams();
}

/// `xuna/stop` notification params.
class StopParams extends XtpNotificationParams {
  const StopParams({required this.reason});
  final StopReason reason;
}

/// `xuna/lanPeer` notification params (`UDC-7` S7.4–S7.5).
class LanPeerParams extends XtpNotificationParams {
  const LanPeerParams({
    this.phonePublicKeys = const <Uint8List>[],
    this.enabled,
    this.port,
    this.certFingerprint,
  });

  final List<Uint8List> phonePublicKeys;
  final bool? enabled;
  final int? port;
  final String? certFingerprint;
}

/// Source of an `xuna/focusRequest` notification (`XUNA_XTP_V1_CONTRACT.md` §4.2.12).
enum FocusRequestSource {
  hotkey('hotkey'),
  tray('tray');

  const FocusRequestSource(this.wire);
  final String wire;

  static FocusRequestSource fromWire(String value) => switch (value) {
        'hotkey' => FocusRequestSource.hotkey,
        'tray' => FocusRequestSource.tray,
        _ => throw FormatException('Unknown FocusRequestSource: $value'),
      };
}

/// `xuna/presence` notification params (`XUNA_XTP_V1_CONTRACT.md` §4.2.10).
class PresenceParams extends XtpNotificationParams {
  const PresenceParams({
    this.schemaVersion = 1,
    required this.idleSeconds,
    required this.screenLocked,
    required this.mediaPlaying,
    this.batteryPercent,
    this.isCharging,
    this.subnetHash,
    this.foregroundAppId,
    required this.updatedAt,
  });

  final int schemaVersion;
  final int idleSeconds;
  final bool screenLocked;
  final bool mediaPlaying;
  final int? batteryPercent;
  final bool? isCharging;
  final String? subnetHash;
  final String? foregroundAppId;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'idleSeconds': idleSeconds,
        'screenLocked': screenLocked,
        'mediaPlaying': mediaPlaying,
        if (batteryPercent != null) 'batteryPercent': batteryPercent,
        if (isCharging != null) 'isCharging': isCharging,
        if (subnetHash != null) 'subnetHash': subnetHash,
        if (foregroundAppId != null) 'foregroundAppId': foregroundAppId,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  XtpNotification toNotification() => XtpNotification(
        method: 'xuna/presence',
        params: toJson(),
        typedParams: this,
      );
}

/// A normalized host toolchain entry declared in `xuna/resources` (`§4.2.11`, P1.2 / U4).
///
/// Never carries filesystem paths, working directories, or raw probe output.
class XtpToolchainEntry {
  const XtpToolchainEntry({
    required this.id,
    required this.version,
  });

  factory XtpToolchainEntry.fromJson(Map<String, Object?> json) {
    _requireExactParamsKeys(json, const <String>{'id', 'version'});
    final entry = XtpToolchainEntry(
      id: _requireStringParam(json, 'id'),
      version: _requireStringParam(json, 'version'),
    );
    entry.validate();
    return entry;
  }

  static XtpToolchainEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final map = _castStringObjectMap(raw);
      return XtpToolchainEntry.fromJson(map);
    } on XtpProtocolException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static const int maxToolchains = 64;
  static final RegExp idPattern = RegExp(r'^[a-z0-9_.-]{1,32}$');
  static final RegExp versionPattern =
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,31}$');

  final String id;
  final String version;

  void validate() {
    if (id.isEmpty ||
        id.length > 32 ||
        id.trim() != id ||
        id == '.' ||
        id == '..' ||
        id.contains('..') ||
        id.contains('/') ||
        id.contains(r'\') ||
        _asciiControlCharPattern.hasMatch(id) ||
        hasBinaryOrInvalidSurrogates(id) ||
        !idPattern.hasMatch(id)) {
      throw const FormatException('Invalid toolchain id');
    }
    if (version.isEmpty ||
        version.length > 32 ||
        version.trim() != version ||
        version.contains('..') ||
        version.contains('/') ||
        version.contains(r'\') ||
        RegExp(r'\s').hasMatch(version) ||
        _asciiControlCharPattern.hasMatch(version) ||
        hasBinaryOrInvalidSurrogates(version) ||
        !versionPattern.hasMatch(version)) {
      throw const FormatException('Invalid toolchain version');
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return <String, Object?>{
      'id': id,
      'version': version,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is XtpToolchainEntry && id == other.id && version == other.version;

  @override
  int get hashCode => Object.hash(id, version);
}

/// Kind of host-declared remediation in `structuredContent.remediation` (`§5.1`, P1.2 / U4).
enum XtpRemediationKind {
  install('install'),
  config('config'),
  manual('manual');

  const XtpRemediationKind(this.wire);
  final String wire;

  static XtpRemediationKind fromWire(String value) => switch (value) {
        'install' => XtpRemediationKind.install,
        'config' => XtpRemediationKind.config,
        'manual' => XtpRemediationKind.manual,
        _ => throw FormatException('Unknown XtpRemediationKind: $value'),
      };
}

/// Host-declared remediation attached to `structuredContent.remediation` on
/// missing dependency/toolchain/config errors (`§5.1`, P1.2 / U4).
///
/// [command] is strictly display-only and must never contain host filesystem
/// paths or secrets.
class XtpRemediation {
  const XtpRemediation({
    required this.summary,
    this.command,
    required this.kind,
  });

  factory XtpRemediation.fromJson(Map<String, Object?> json) {
    _requireExactParamsKeys(
      json,
      const <String>{'summary', 'kind'},
      optionalKeys: const <String>{'command'},
    );
    final summary = _requireStringParam(json, 'summary');
    String? command;
    if (json.containsKey('command') && json['command'] != null) {
      command = _requireStringParam(json, 'command');
    }
    final kind = XtpRemediationKind.fromWire(_requireStringParam(json, 'kind'));
    final remediation = XtpRemediation(
      summary: summary,
      command: command,
      kind: kind,
    );
    remediation.validate();
    return remediation;
  }

  static XtpRemediation? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final map = _castStringObjectMap(raw);
      return XtpRemediation.fromJson(map);
    } on XtpProtocolException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static const int maxLength = 240;
  static final RegExp _windowsForwardDrivePathRe = RegExp(
    r'''(?:^|[\s"'`(\[{=:,])[A-Za-z]:[/\\]''',
  );

  final String summary;
  final String? command;
  final XtpRemediationKind kind;

  static void _validateTextField(String value, String fieldName) {
    if (value.isEmpty ||
        value.length > maxLength ||
        value.trim() != value ||
        _asciiControlCharPattern.hasMatch(value) ||
        hasBinaryOrInvalidSurrogates(value)) {
      throw FormatException(
        'remediation.$fieldName must be 1..$maxLength trimmed single-line chars without control chars',
      );
    }
    if (redactFilesystemPaths(value) != value ||
        _windowsForwardDrivePathRe.hasMatch(value)) {
      throw FormatException(
        'remediation.$fieldName must not contain host filesystem paths',
      );
    }
    if (redactSensitiveSelectionText(value, maxChars: maxLength).redactedCount >
        0) {
      throw FormatException(
        'remediation.$fieldName must not contain secrets or tokens',
      );
    }
  }

  void validate() {
    _validateTextField(summary, 'summary');
    final cmd = command;
    if (cmd != null) {
      _validateTextField(cmd, 'command');
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return <String, Object?>{
      'summary': summary,
      if (command != null) 'command': command,
      'kind': kind.wire,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is XtpRemediation &&
          summary == other.summary &&
          command == other.command &&
          kind == other.kind;

  @override
  int get hashCode => Object.hash(summary, command, kind);
}

/// `xuna/resources` notification params (`XUNA_XTP_V1_CONTRACT.md` §4.2.11).
class ResourcesParams extends XtpNotificationParams {
  const ResourcesParams({
    this.schemaVersion = 1,
    required this.installedApps,
    required this.workspaces,
    this.capabilitiesVersion,
    this.toolchains = const <XtpToolchainEntry>[],
  });

  final int schemaVersion;
  final List<String> installedApps;
  final List<String> workspaces;
  final String? capabilitiesVersion;
  final List<XtpToolchainEntry> toolchains;

  void validate() {
    if (schemaVersion != 1) {
      throw FormatException(
        'Unsupported xuna/resources schemaVersion: $schemaVersion',
      );
    }
    if (toolchains.length > XtpToolchainEntry.maxToolchains) {
      throw const FormatException('toolchains exceeds max 64 items');
    }
    final seenIds = <String>{};
    for (final entry in toolchains) {
      entry.validate();
      if (!seenIds.add(entry.id)) {
        throw FormatException('Duplicate toolchain id "${entry.id}"');
      }
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'installedApps': installedApps,
      'workspaces': workspaces,
      if (capabilitiesVersion != null)
        'capabilitiesVersion': capabilitiesVersion,
      if (toolchains.isNotEmpty)
        'toolchains':
            toolchains.map((entry) => entry.toJson()).toList(growable: false),
    };
  }

  XtpNotification toNotification() => XtpNotification(
        method: 'xuna/resources',
        params: toJson(),
        typedParams: this,
      );
}

/// `xuna/focusRequest` notification params (`XUNA_XTP_V1_CONTRACT.md` §4.2.12).
class FocusRequestParams extends XtpNotificationParams {
  const FocusRequestParams({
    this.schemaVersion = 1,
    required this.source,
    this.followMe,
  });

  final int schemaVersion;
  final FocusRequestSource source;
  final bool? followMe;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'source': source.wire,
        if (followMe != null) 'followMe': followMe,
      };

  XtpNotification toNotification() => XtpNotification(
        method: 'xuna/focusRequest',
        params: toJson(),
        typedParams: this,
      );
}

/// `xuna/watchEvent` notification params (`XUNA_XTP_V1_CONTRACT.md` §4.2.16).
class WatchEventParams extends XtpNotificationParams {
  const WatchEventParams({
    this.schemaVersion = 1,
    required this.watchId,
    required this.jobId,
    required this.kind,
    required this.observedSignals,
    required this.elapsedSeconds,
    required this.changeCount,
    required this.digestChanged,
    required this.occurredAt,
    this.errorCode,
  });

  final int schemaVersion;
  final String watchId;
  final String jobId;
  final WatchEventKind kind;
  final List<WatchSignal> observedSignals;
  final int elapsedSeconds;
  final int changeCount;
  final bool digestChanged;
  final DateTime occurredAt;
  final String? errorCode;

  void validate() {
    if (schemaVersion != 1) {
      throw FormatException(
        'Unsupported xuna/watchEvent schemaVersion: $schemaVersion',
      );
    }
    if (!isValidNonZeroUuid(watchId)) {
      throw const FormatException('watchId must be a canonical non-zero UUID');
    }
    if (!isValidNonZeroUuid(jobId)) {
      throw const FormatException('jobId must be a canonical non-zero UUID');
    }
    if (observedSignals.length > 3) {
      throw const FormatException('observedSignals must have at most 3 items');
    }
    final seen = <WatchSignal>{};
    for (final s in observedSignals) {
      if (!seen.add(s)) {
        throw const FormatException('observedSignals items must be distinct');
      }
    }
    if ((kind == WatchEventKind.settled || kind == WatchEventKind.changed) &&
        observedSignals.isEmpty) {
      throw const FormatException(
        'observedSignals must be non-empty for settled or changed events',
      );
    }
    if (elapsedSeconds < 0) {
      throw const FormatException('elapsedSeconds must be >= 0');
    }
    if (changeCount < 0) {
      throw const FormatException('changeCount must be >= 0');
    }
    if (kind == WatchEventKind.error) {
      final code = errorCode;
      if (code == null ||
          code.contains('\n') ||
          code.contains('\r') ||
          !isValidShortId(code)) {
        throw const FormatException(
          'errorCode is required and must be a valid short ID when kind is error',
        );
      }
    } else if (errorCode != null) {
      throw const FormatException(
        'errorCode is forbidden unless kind is error',
      );
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'watchId': watchId,
      'jobId': jobId,
      'kind': kind.wire,
      'observedSignals': observedSignals.map((s) => s.wire).toList(),
      'elapsedSeconds': elapsedSeconds,
      'changeCount': changeCount,
      'digestChanged': digestChanged,
      'occurredAt': occurredAt.toUtc().toIso8601String(),
      if (errorCode != null) 'errorCode': errorCode,
    };
  }

  XtpNotification toNotification() => XtpNotification(
        method: 'xuna/watchEvent',
        params: toJson(),
        typedParams: this,
      );
}

XtpRequestParams _parseRequestParams(
  String method,
  Map<String, Object?> params,
  Object requestId,
) {
  try {
    switch (method) {
      case 'xuna/hello':
        return _parseHelloParams(params);
      case 'xuna/proof':
        _requireExactParamsKeys(
          params,
          const <String>{'purpose', 'signature'},
        );
        final purposeInt = _requireIntParam(params, 'purpose');
        final purpose = HostProofPurpose.fromCode(purposeInt);
        final sigB64 = _requireStringParam(params, 'signature');
        final sigBytes = Uint8List.fromList(base64.decode(sigB64));
        validateP256Signature(sigBytes);
        return ProofParams(purpose: purpose, signatureBytes: sigBytes);
      case 'tools/list':
        _requireExactParamsKeys(params, const <String>{});
        return const ToolsListParams();
      case 'tools/call':
        return _parseToolsCallParams(params);
      case 'xuna/preflight':
        _requireExactParamsKeys(params, const <String>{'name', 'arguments'});
        final preflightName = _requireStringParam(params, 'name');
        ToolDescriptor.validateToolName(preflightName);
        return PreflightParams(
          name: preflightName,
          arguments: _requireMapParam(params, 'arguments'),
        );
      case 'ping':
        _requireExactParamsKeys(params, const <String>{});
        return const PingParams();
      case 'xuna/get_policy':
        _requireExactParamsKeys(params, const <String>{});
        return const GetPolicyParams();
      case 'xuna/set_policy':
        return _parseSetPolicyParams(params);
      case 'xuna/watchRegister':
        return _parseWatchRegisterParams(params);
      case 'xuna/watchCancel':
        return _parseWatchCancelParams(params);
      default:
        throw XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.methodNotFound,
          message: 'Method not found',
          requestId: requestId,
        );
    }
  } on XtpProtocolException {
    rethrow;
  } on FormatException catch (error) {
    throw XtpProtocolException(
      jsonRpcCode: JsonRpcErrorCode.invalidParams,
      message: error.message,
      requestId: requestId,
    );
  }
}

XtpRequestParams _parseHelloParams(Map<String, Object?> params) {
  final protocolsRaw = params['protocols'];
  if (protocolsRaw is! List || protocolsRaw.isEmpty) {
    throw const FormatException('xuna/hello requires non-empty protocols');
  }
  final protocols = <String>[];
  for (final item in protocolsRaw) {
    if (item is! String) {
      throw const FormatException('protocols must be strings');
    }
    protocols.add(item);
  }
  if (!protocols.contains('xtp/1')) {
    throw const XtpProtocolException(
      jsonRpcCode: JsonRpcErrorCode.invalidParams,
      message: 'Unsupported protocol',
      closeCode: XtpCloseCode.unsupportedProtocol,
      closeReason: 'unsupported_protocol',
    );
  }

  final hasEnroll = params.containsKey('enroll');
  final hasHostId = params.containsKey('hostId');
  if (hasEnroll == hasHostId) {
    throw const FormatException(
      'xuna/hello must contain exactly one of enroll or hostId',
    );
  }

  if (hasEnroll) {
    _requireExactParamsKeys(params, const <String>{'protocols', 'enroll'});
    final enroll = _requireMapParam(params, 'enroll');
    _requireExactParamsKeys(
      enroll,
      const <String>{
        'code',
        'publicKey',
        'platform',
        'osVersion',
        'agentVersion',
        'hostname',
      },
    );
    final codeBytes = base64UrlDecodeLoose(_requireStringParam(enroll, 'code'));
    if (codeBytes.length != hostEnrollmentCodeSize) {
      throw const FormatException('enroll.code must decode to 16 bytes');
    }
    final pubKeyBytes = Uint8List.fromList(
      base64.decode(_requireStringParam(enroll, 'publicKey')),
    );
    validateP256PublicKey(pubKeyBytes);
    final platform = HostPlatform.fromWire(
      _requireStringParam(enroll, 'platform'),
    );
    if (platform != HostPlatform.windows &&
        platform != HostPlatform.macos &&
        platform != HostPlatform.linux) {
      throw FormatException(
        'Enrollment platform must be windows, macos, or linux (got ${platform.wire})',
      );
    }
    final osVersion = _requireNonEmptyString(enroll, 'osVersion', maxLen: 64);
    final agentVersion = _requireNonEmptyString(
      enroll,
      'agentVersion',
      maxLen: 32,
    );
    final hostname = _requireNonEmptyString(enroll, 'hostname', maxLen: 32);
    return HelloEnrollParams(
      protocols: protocols,
      codeBytes: codeBytes,
      publicKeyBytes: pubKeyBytes,
      platform: platform,
      osVersion: osVersion,
      agentVersion: agentVersion,
      hostname: hostname,
    );
  } else {
    _requireExactParamsKeys(
      params,
      const <String>{
        'protocols',
        'hostId',
        'platform',
        'osVersion',
        'agentVersion',
      },
    );
    final hostId = _requireStringParam(params, 'hostId');
    if (!isValidUuid(hostId)) {
      throw const FormatException('Invalid hostId UUID');
    }
    final platform = HostPlatform.fromWire(
      _requireStringParam(params, 'platform'),
    );
    final osVersion = _requireNonEmptyString(params, 'osVersion', maxLen: 64);
    final agentVersion = _requireNonEmptyString(
      params,
      'agentVersion',
      maxLen: 32,
    );
    return HelloReconnectParams(
      protocols: protocols,
      hostId: hostId,
      platform: platform,
      osVersion: osVersion,
      agentVersion: agentVersion,
    );
  }
}

ToolsCallParams _parseToolsCallParams(Map<String, Object?> params) {
  _requireExactParamsKeys(
    params,
    const <String>{'name', 'arguments', '_meta'},
  );
  final name = _requireStringParam(params, 'name');
  ToolDescriptor.validateToolName(name);
  final arguments = _requireMapParam(params, 'arguments');
  final meta = _requireMapParam(params, '_meta');
  _requireExactParamsKeys(
    meta,
    const <String>{'xuna/invocationId', 'xuna/deadlineMs'},
    optionalKeys: const <String>{'xuna/approval'},
  );
  final invocationId = _requireStringParam(meta, 'xuna/invocationId');
  if (!isValidUuid(invocationId)) {
    throw const FormatException('xuna/invocationId must be a UUID');
  }
  final deadlineMs = _requireIntParam(meta, 'xuna/deadlineMs');
  if (deadlineMs <= 0 || deadlineMs > 30000) {
    throw const FormatException('xuna/deadlineMs must be in 1..30000');
  }
  ApprovalToken? approval;
  if (meta.containsKey('xuna/approval') && meta['xuna/approval'] != null) {
    approval = ApprovalToken.fromJson(_requireMapParam(meta, 'xuna/approval'));
  }
  return ToolsCallParams(
    name: name,
    arguments: arguments,
    invocationId: invocationId,
    deadlineMs: deadlineMs,
    approval: approval,
  );
}

SetPolicyParams _parseSetPolicyParams(Map<String, Object?> params) {
  _requireExactParamsKeys(
    params,
    const <String>{'trustPreset'},
    optionalKeys: const <String>{
      'schemaVersion',
      'allowApps',
      'denyApps',
      'allowDomains',
      'denyDomains',
    },
  );
  final trustPreset = _requireStringParam(params, 'trustPreset');
  final schemaVersion = params.containsKey('schemaVersion')
      ? _requireIntParam(params, 'schemaVersion')
      : 1;

  List<String> parseStringList(Object? val, String name) {
    if (val == null) return const <String>[];
    if (val is! List) throw FormatException('$name must be a list');
    final result = <String>[];
    for (final item in val) {
      if (item is! String) {
        throw FormatException('$name items must be strings');
      }
      result.add(item);
    }
    return result;
  }

  return SetPolicyParams(
    schemaVersion: schemaVersion,
    trustPreset: trustPreset,
    allowApps: parseStringList(params['allowApps'], 'allowApps'),
    denyApps: parseStringList(params['denyApps'], 'denyApps'),
    allowDomains: parseStringList(params['allowDomains'], 'allowDomains'),
    denyDomains: parseStringList(params['denyDomains'], 'denyDomains'),
  );
}

XtpNotificationParams _parseNotificationParams(
  String method,
  Map<String, Object?> params,
) {
  try {
    switch (method) {
      case 'xuna/challenge':
        _requireExactParamsKeys(
          params,
          const <String>{'purpose', 'nonce', 'expiresIn'},
        );
        final purpose = HostProofPurpose.fromCode(
          _requireIntParam(params, 'purpose'),
        );
        final nonceBytes = Uint8List.fromList(
          base64.decode(_requireStringParam(params, 'nonce')),
        );
        if (nonceBytes.length != hostProofNonceSize) {
          throw const FormatException('challenge nonce must be 32 bytes');
        }
        final expiresIn = _requireIntParam(params, 'expiresIn');
        if (expiresIn <= 0) {
          throw const FormatException('expiresIn must be positive');
        }
        return ChallengeParams(
          purpose: purpose,
          nonceBytes: nonceBytes,
          expiresIn: expiresIn,
        );
      case 'xuna/enrollPending':
        _requireExactParamsKeys(params, const <String>{'expiresIn'});
        final expiresIn = _requireIntParam(params, 'expiresIn');
        if (expiresIn <= 0) {
          throw const FormatException('expiresIn must be positive');
        }
        return EnrollPendingParams(expiresIn: expiresIn);
      case 'xuna/enrolled':
        _requireExactParamsKeys(params, const <String>{'hostId', 'alias'});
        final hostId = _requireStringParam(params, 'hostId');
        if (!isValidUuid(hostId)) {
          throw const FormatException('Invalid enrolled hostId UUID');
        }
        final alias = _requireNonEmptyString(params, 'alias', maxLen: 24);
        return EnrolledParams(hostId: hostId, alias: alias);
      case 'xuna/ready':
        _requireExactParamsKeys(
          params,
          const <String>{'serverTime', 'heartbeatS'},
        );
        final serverTimeRaw = _requireStringParam(params, 'serverTime');
        final serverTime = DateTime.tryParse(serverTimeRaw);
        if (serverTime == null) {
          throw const FormatException('Invalid serverTime ISO-8601');
        }
        final heartbeatS = _requireIntParam(params, 'heartbeatS');
        if (heartbeatS <= 0) {
          throw const FormatException('heartbeatS must be positive');
        }
        return ReadyParams(
          serverTime: serverTime.toUtc(),
          heartbeatS: heartbeatS,
        );
      case 'notifications/cancelled':
        _requireExactParamsKeys(
          params,
          const <String>{'requestId', 'reason'},
        );
        final reqId = params['requestId'];
        if (reqId is! int && reqId is! String) {
          throw const FormatException('requestId must be int or string');
        }
        final reason = _requireNonEmptyString(params, 'reason', maxLen: 64);
        return CancelledParams(requestId: reqId!, reason: reason);
      case 'notifications/progress':
        _requireExactParamsKeys(
          params,
          const <String>{'progressToken', 'progress'},
          optionalKeys: const <String>{'total', 'message'},
        );
        final token = _requireNonEmptyString(
          params,
          'progressToken',
          maxLen: 64,
        );
        final progress = _requireIntParam(params, 'progress');
        if (progress < 0) {
          throw const FormatException('progress must be >= 0');
        }
        int? total;
        if (params.containsKey('total') && params['total'] != null) {
          total = _requireIntParam(params, 'total');
          if (total < progress) {
            throw const FormatException('total must be >= progress');
          }
        }
        String? message;
        if (params.containsKey('message') && params['message'] != null) {
          message = _requireStringParam(params, 'message');
          if (!isValidShortId(message)) {
            throw const FormatException(
              'progress message must be a short status code (1..64 chars)',
            );
          }
        }
        return ProgressParams(
          progressToken: token,
          progress: progress,
          total: total,
          message: message,
        );
      case 'notifications/tools/list_changed':
        _requireExactParamsKeys(params, const <String>{});
        return const ToolsListChangedParams();
      case 'xuna/stop':
        _requireExactParamsKeys(params, const <String>{'reason'});
        final reason = StopReason.fromWire(
          _requireStringParam(params, 'reason'),
        );
        return StopParams(reason: reason);
      case 'xuna/lanPeer':
        if (params.containsKey('phonePublicKeys')) {
          _requireExactParamsKeys(params, const <String>{'phonePublicKeys'});
          final rawList = params['phonePublicKeys'];
          if (rawList is! List) {
            throw const FormatException('phonePublicKeys must be a list');
          }
          final keys = <Uint8List>[];
          for (final item in rawList) {
            if (item is! String) {
              throw const FormatException(
                  'phonePublicKeys items must be base64 strings');
            }
            var clean = item.trim();
            final rem = clean.length % 4;
            if (rem == 2) {
              clean = '$clean==';
            } else if (rem == 3) {
              clean = '$clean=';
            }
            final kb = Uint8List.fromList(
              (clean.contains('-') || clean.contains('_'))
                  ? base64Url.decode(clean)
                  : base64.decode(clean),
            );
            validateP256PublicKey(kb);
            keys.add(kb);
          }
          return LanPeerParams(phonePublicKeys: List.unmodifiable(keys));
        } else {
          _requireExactParamsKeys(
            params,
            const <String>{'enabled'},
            optionalKeys: const <String>{'port', 'certFingerprint'},
          );
          final enabledVal = params['enabled'];
          if (enabledVal is! bool) {
            throw const FormatException('enabled must be a boolean');
          }
          int? port;
          if (params.containsKey('port') && params['port'] != null) {
            port = _requireIntParam(params, 'port');
            if (port < 1024 || port > 65535) {
              throw const FormatException('port must be in 1024..65535');
            }
          }
          String? fp;
          if (params.containsKey('certFingerprint') &&
              params['certFingerprint'] != null) {
            fp = _requireNonEmptyString(params, 'certFingerprint', maxLen: 88);
          }
          return LanPeerParams(
            enabled: enabledVal,
            port: port,
            certFingerprint: fp,
          );
        }
      case 'xuna/presence':
        return _parsePresenceParams(params);
      case 'xuna/resources':
        return _parseResourcesParams(params);
      case 'xuna/focusRequest':
        return _parseFocusRequestParams(params);
      case 'xuna/watchEvent':
        return _parseWatchEventParams(params);
      default:
        throw const XtpProtocolException(
          jsonRpcCode: JsonRpcErrorCode.methodNotFound,
          message: 'Method not found',
        );
    }
  } on XtpProtocolException {
    rethrow;
  } on FormatException catch (error) {
    throw XtpProtocolException(
      jsonRpcCode: JsonRpcErrorCode.invalidParams,
      message: error.message,
    );
  }
}

void _validateResultPayload(Map<String, Object?> result, Object requestId) {
  if (result.isEmpty) {
    // `ping` response: `{}`
    return;
  }
  if (_hasOnlyKeys(result, const <String>{'protocol'})) {
    if (result['protocol'] != 'xtp/1') {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'Unsupported protocol in hello response',
        requestId: requestId,
      );
    }
    return;
  }
  if (_hasOnlyKeys(result, const <String>{'verified'})) {
    if (result['verified'] is! bool) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'Invalid verified flag in proof response',
        requestId: requestId,
      );
    }
    return;
  }
  if (_hasOnlyKeys(result, const <String>{'tools'})) {
    final toolsRaw = result['tools'];
    if (toolsRaw is! List) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'tools must be a list',
        requestId: requestId,
      );
    }
    try {
      for (final item in toolsRaw) {
        if (item is! Map) {
          throw const FormatException('Tool item must be an object');
        }
        ToolDescriptor.fromJson(
          _castStringObjectMap(item, requestId: requestId),
        );
      }
    } on FormatException catch (error) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: error.message,
        requestId: requestId,
      );
    }
    return;
  }
  if (_hasOnlyKeys(result, const <String>{'preflight'})) {
    try {
      final raw = result['preflight'];
      if (raw is! Map) {
        throw const FormatException('preflight must be an object');
      }
      _validatePreflightResult(_castStringObjectMap(raw, requestId: requestId));
    } on FormatException catch (error) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: error.message,
        requestId: requestId,
      );
    }
    return;
  }
  if (_hasOnlyKeys(
    result,
    const <String>{'content', 'structuredContent', 'isError', '_meta'},
  )) {
    final content = result['content'];
    final sc = result['structuredContent'];
    final isError = result['isError'];
    final meta = result['_meta'];
    if (content is! List || sc is! Map || isError is! bool || meta is! Map) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'Invalid tools/call result fields',
        requestId: requestId,
      );
    }
    final limit = _hasMediaStructuredContent(sc)
        ? maxMediaStructuredContentBytes
        : maxStructuredContentBytes;
    final scBytes = utf8.encode(jsonEncode(sc)).length;
    if (scBytes > limit) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'structuredContent exceeds ${limit ~/ 1024} KiB limit',
        requestId: requestId,
      );
    }
    final metaMap = _castStringObjectMap(meta, requestId: requestId);
    try {
      _requireExactParamsKeys(
        metaMap,
        const <String>{'xuna/status', 'xuna/durationMs'},
        optionalKeys: const <String>{'xuna/errorCode'},
      );
      final status = XtpStatus.fromWire(
        _requireStringParam(metaMap, 'xuna/status'),
      );
      if (status.isError != isError) {
        throw const FormatException(
          'isError must match xuna/status error polarity',
        );
      }
      final durationMs = _requireIntParam(metaMap, 'xuna/durationMs');
      if (durationMs < 0) {
        throw const FormatException('xuna/durationMs must be >= 0');
      }
      if (metaMap.containsKey('xuna/errorCode')) {
        final code = _requireStringParam(metaMap, 'xuna/errorCode');
        if (!isValidShortId(code)) {
          throw const FormatException('Invalid xuna/errorCode');
        }
      }
      final scMap = _castStringObjectMap(sc, requestId: requestId);
      if (scMap.containsKey('remediation')) {
        if (status == XtpStatus.ok) {
          throw const FormatException(
            'remediation is forbidden when xuna/status is ok',
          );
        }
        final rawRem = scMap['remediation'];
        if (rawRem is! Map) {
          throw const FormatException(
            'structuredContent.remediation must be an object',
          );
        }
        XtpRemediation.fromJson(
          _castStringObjectMap(rawRem, requestId: requestId),
        );
      }
    } on FormatException catch (error) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: error.message,
        requestId: requestId,
      );
    }
    return;
  }
  if (_hasOnlyKeys(result, const <String>{'schemaVersion', 'status'})) {
    if (result['schemaVersion'] != 1 || result['status'] != 'ok') {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'Invalid set_policy response',
        requestId: requestId,
      );
    }
    return;
  }
  if (result.containsKey('trustPreset') &&
      result.containsKey('discoveredApps') &&
      result.containsKey('allowApps')) {
    try {
      _requireExactParamsKeys(
        result,
        const <String>{
          'schemaVersion',
          'trustPreset',
          'allowApps',
          'discoveredApps',
        },
        optionalKeys: const <String>{
          'denyApps',
          'allowDomains',
          'denyDomains',
          'shellEnabled',
        },
      );
      if (result.containsKey('shellEnabled') &&
          result['shellEnabled'] is! bool) {
        throw const FormatException('shellEnabled must be a boolean');
      }
    } on FormatException catch (error) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: error.message,
        requestId: requestId,
      );
    }
    return;
  }
  if (result.containsKey('cancelledCount')) {
    try {
      _requireExactParamsKeys(
        result,
        const <String>{'schemaVersion', 'cancelledCount'},
      );
      final schemaVersion = _requireIntParam(result, 'schemaVersion');
      if (schemaVersion != 1) {
        throw FormatException(
          'Unsupported xuna/watchCancel result schemaVersion: $schemaVersion',
        );
      }
      final cancelledCount = _requireIntParam(result, 'cancelledCount');
      if (cancelledCount < 0) {
        throw const FormatException('cancelledCount must be >= 0');
      }
    } on FormatException catch (error) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: error.message,
        requestId: requestId,
      );
    }
    return;
  }
  if (result.containsKey('accepted') || result.containsKey('watchId')) {
    try {
      final schemaVersion = _requireIntParam(result, 'schemaVersion');
      if (schemaVersion != 1) {
        throw FormatException(
          'Unsupported xuna/watchRegister result schemaVersion: $schemaVersion',
        );
      }
      final accepted = _requireBoolParam(result, 'accepted');
      final watchId = _requireStringParam(result, 'watchId');
      if (!isValidNonZeroUuid(watchId)) {
        throw const FormatException(
            'watchId must be a canonical non-zero UUID');
      }
      if (accepted) {
        _requireExactParamsKeys(
          result,
          const <String>{
            'schemaVersion',
            'accepted',
            'watchId',
            'activeSignals',
            'eventDriven',
            'fallbackUsed',
          },
        );
        final rawSignals = result['activeSignals'];
        if (rawSignals is! List ||
            rawSignals.isEmpty ||
            rawSignals.length > 3) {
          throw const FormatException(
            'activeSignals must be a list of 1..3 distinct signals',
          );
        }
        final seen = <WatchSignal>{};
        for (final item in rawSignals) {
          if (item is! String) {
            throw const FormatException('activeSignals items must be strings');
          }
          final sig = WatchSignal.fromWire(item);
          if (!seen.add(sig)) {
            throw const FormatException('activeSignals must be distinct');
          }
        }
        _requireBoolParam(result, 'eventDriven');
        _requireBoolParam(result, 'fallbackUsed');
      } else {
        _requireExactParamsKeys(
          result,
          const <String>{
            'schemaVersion',
            'accepted',
            'watchId',
            'errorCode',
          },
        );
        WatchRejectErrorCode.fromWire(_requireStringParam(result, 'errorCode'));
      }
    } on FormatException catch (error) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: error.message,
        requestId: requestId,
      );
    }
    return;
  }

  throw XtpProtocolException(
    jsonRpcCode: JsonRpcErrorCode.invalidRequest,
    message: 'Unrecognized result payload shape',
    requestId: requestId,
  );
}

/// Kind of bounded read-only preflight preview (`XUNA_XTP_V1_CONTRACT.md` §4.2.8,
/// `ADR-0019` §2 / `W4-M2`).
enum XtpPreflightPreviewKind {
  diff('diff'),
  paths('paths');

  const XtpPreflightPreviewKind(this.wire);
  final String wire;

  static XtpPreflightPreviewKind fromWire(String raw) {
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    throw FormatException('Invalid preflight preview kind: $raw');
  }
}

/// Bounded, read-only, ephemeral preview attached to an `ok` `xuna/preflight`
/// response (`XUNA_XTP_V1_CONTRACT.md` §4.2.8, `ADR-0019` §2 / `W4-M2`).
class XtpPreflightPreview {
  XtpPreflightPreview.diff({
    required String summary,
    required String snippet,
    required this.truncated,
  })  : kind = XtpPreflightPreviewKind.diff,
        summary = _validatePreviewSummary(summary),
        snippet = _validatePreviewSnippet(snippet, truncated: truncated),
        paths = null,
        totalCount = null;

  XtpPreflightPreview.paths({
    required String summary,
    required List<String> paths,
    required int totalCount,
    required this.truncated,
  })  : kind = XtpPreflightPreviewKind.paths,
        summary = _validatePreviewSummary(summary),
        snippet = null,
        paths = List<String>.unmodifiable(_validatePreviewPaths(paths)),
        totalCount = _validatePreviewTotalCount(totalCount, paths.length);

  factory XtpPreflightPreview.fromJson(Map<String, Object?> json) {
    final kind = XtpPreflightPreviewKind.fromWire(
      _requireStringParam(json, 'kind'),
    );
    final summary = _requireStringParam(json, 'summary');
    final truncated = _requireBoolParam(json, 'truncated');
    switch (kind) {
      case XtpPreflightPreviewKind.diff:
        _requireExactParamsKeys(
          json,
          const <String>{'kind', 'summary', 'snippet', 'truncated'},
        );
        return XtpPreflightPreview.diff(
          summary: summary,
          snippet: _requireStringParam(json, 'snippet'),
          truncated: truncated,
        );
      case XtpPreflightPreviewKind.paths:
        _requireExactParamsKeys(
          json,
          const <String>{
            'kind',
            'summary',
            'paths',
            'totalCount',
            'truncated',
          },
        );
        final rawPaths = json['paths'];
        if (rawPaths is! List) {
          throw const FormatException('preview.paths must be a list');
        }
        final pathList = <String>[];
        for (final item in rawPaths) {
          if (item is! String) {
            throw const FormatException('preview.paths items must be strings');
          }
          pathList.add(item);
        }
        final rawTotal = json['totalCount'];
        if (rawTotal is! int) {
          throw const FormatException('preview.totalCount must be an integer');
        }
        return XtpPreflightPreview.paths(
          summary: summary,
          paths: pathList,
          totalCount: rawTotal,
          truncated: truncated,
        );
    }
  }

  static const int maxSummaryChars = 160;
  static const int maxSnippetBytes = 2048;
  static const int maxSnippetLines = 40;
  static const int maxPaths = 20;
  static const int maxPathChars = 260;
  static const String truncationMarker = '…';

  final XtpPreflightPreviewKind kind;
  final String summary;
  final bool truncated;
  final String? snippet;
  final List<String>? paths;
  final int? totalCount;

  Map<String, Object?> toJson() => switch (kind) {
        XtpPreflightPreviewKind.diff => <String, Object?>{
            'kind': kind.wire,
            'summary': summary,
            'snippet': snippet!,
            'truncated': truncated,
          },
        XtpPreflightPreviewKind.paths => <String, Object?>{
            'kind': kind.wire,
            'summary': summary,
            'paths': paths!,
            'totalCount': totalCount!,
            'truncated': truncated,
          },
      };

  static final RegExp _singleLineControlRe = RegExp(r'[\u0000-\u001F\u007F]');
  static final RegExp _snippetControlRe = RegExp(
    r'[\u0000-\u0008\u000B-\u001F\u007F]',
  );
  static final RegExp _windowsDriveRe = RegExp(r'^[A-Za-z]:');

  static String _validatePreviewSummary(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        trimmed.length > maxSummaryChars ||
        _singleLineControlRe.hasMatch(trimmed) ||
        hasBinaryOrInvalidSurrogates(trimmed)) {
      throw const FormatException('Invalid preflight preview summary');
    }
    return trimmed;
  }

  static String _validatePreviewSnippet(String raw, {required bool truncated}) {
    if (raw.isEmpty ||
        _snippetControlRe.hasMatch(raw) ||
        hasBinaryOrInvalidSurrogates(raw)) {
      throw const FormatException('Invalid preflight preview snippet');
    }
    if (utf8.encode(raw).length > maxSnippetBytes) {
      throw const FormatException(
        'Preflight preview snippet exceeds 2048 UTF-8 bytes',
      );
    }
    if (raw.split('\n').length > maxSnippetLines) {
      throw const FormatException(
        'Preflight preview snippet exceeds 40 lines',
      );
    }
    if (truncated && !raw.endsWith(truncationMarker)) {
      throw const FormatException(
        'Truncated preflight preview snippet must end with …',
      );
    }
    return raw;
  }

  static List<String> _validatePreviewPaths(List<String> rawPaths) {
    if (rawPaths.length > maxPaths) {
      throw const FormatException('Preflight preview paths exceeds 20 entries');
    }
    final validated = <String>[];
    for (final raw in rawPaths) {
      if (raw.isEmpty ||
          raw.length > maxPathChars ||
          raw.trim() != raw ||
          _singleLineControlRe.hasMatch(raw) ||
          hasBinaryOrInvalidSurrogates(raw)) {
        throw const FormatException('Invalid preflight preview path entry');
      }
      if (raw.startsWith('/') ||
          raw.startsWith(r'\') ||
          raw.startsWith('~') ||
          _windowsDriveRe.hasMatch(raw)) {
        throw const FormatException(
          'Preflight preview paths must be workspace-relative',
        );
      }
      final normalized = raw.replaceAll(r'\', '/');
      final segments = normalized.split('/');
      if (segments.contains('..')) {
        throw const FormatException(
          'Preflight preview path must not contain .. traversal',
        );
      }
      if (hardDeniedPathReason(normalized) != null ||
          isSecretFileName(normalized)) {
        throw const FormatException(
          'Preflight preview path must not contain secret or Hard-Deny path',
        );
      }
      validated.add(normalized);
    }
    return validated;
  }

  static int _validatePreviewTotalCount(int totalCount, int returnedCount) {
    if (totalCount < returnedCount) {
      throw const FormatException(
        'Preflight preview totalCount must be >= paths.length',
      );
    }
    return totalCount;
  }
}

/// Validates the `preflight` object of an `xuna/preflight` result (§4.2.8).
void _validatePreflightResult(Map<String, Object?> preflight) {
  _requireExactParamsKeys(
    preflight,
    const <String>{'status'},
    optionalKeys: const <String>{
      'effectiveRisk',
      'reasonCode',
      'errorCode',
      'element',
      'preview',
      'effectSha256',
    },
  );
  final status = XtpStatus.fromWire(_requireStringParam(preflight, 'status'));
  if (status == XtpStatus.ok) {
    RiskTier.fromWire(_requireStringParam(preflight, 'effectiveRisk'));
    if (preflight.containsKey('errorCode')) {
      throw const FormatException('ok preflight must not carry errorCode');
    }
  } else {
    final code = _requireStringParam(preflight, 'errorCode');
    if (!isValidShortId(code)) {
      throw const FormatException('Invalid preflight errorCode');
    }
    if (preflight.containsKey('effectiveRisk') ||
        preflight.containsKey('element') ||
        preflight.containsKey('preview') ||
        preflight.containsKey('effectSha256')) {
      throw const FormatException(
        'A refused preflight carries no risk, element, preview or effectSha256',
      );
    }
  }
  if (preflight.containsKey('reasonCode') &&
      !isValidShortId(_requireStringParam(preflight, 'reasonCode'))) {
    throw const FormatException('Invalid preflight reasonCode');
  }
  if (preflight.containsKey('element')) {
    final element = _requireMapParam(preflight, 'element');
    _requireExactParamsKeys(element, const <String>{'role', 'name'});
    if (!isValidShortId(_requireStringParam(element, 'role'))) {
      throw const FormatException('Invalid preflight element role');
    }
    final name = _requireStringParam(element, 'name');
    if (name.length > 80 || RegExp(r'[\u0000-\u001F\u007F]').hasMatch(name)) {
      throw const FormatException('Invalid preflight element name');
    }
  }
  if (preflight.containsKey('preview')) {
    XtpPreflightPreview.fromJson(_requireMapParam(preflight, 'preview'));
  }
  if (preflight.containsKey('effectSha256')) {
    final effectHash = _requireStringParam(preflight, 'effectSha256');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(effectHash)) {
      throw const FormatException('Invalid preflight effectSha256');
    }
  }
}

bool _hasOnlyKeys(Map<String, Object?> map, Set<String> allowed) {
  if (map.length != allowed.length) return false;
  for (final key in allowed) {
    if (!map.containsKey(key)) return false;
  }
  return true;
}

void _requireExactParamsKeys(
  Map<String, Object?> map,
  Set<String> requiredKeys, {
  Set<String> optionalKeys = const <String>{},
}) {
  for (final req in requiredKeys) {
    if (!map.containsKey(req)) {
      throw FormatException('Missing required param "$req"');
    }
  }
  for (final key in map.keys) {
    if (!requiredKeys.contains(key) && !optionalKeys.contains(key)) {
      throw FormatException('Unexpected param "$key"');
    }
  }
}

Map<String, Object?> _castStringObjectMap(
  Map<Object?, Object?> raw, {
  Object? requestId,
}) {
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    if (entry.key is! String) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'Object keys must be strings',
        requestId: requestId,
      );
    }
    out[entry.key as String] = entry.value;
  }
  return out;
}

String _requireStringParam(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw FormatException('Expected string for "$key"');
  }
  return value;
}

String _requireNonEmptyString(
  Map<String, Object?> map,
  String key, {
  required int maxLen,
}) {
  final value = _requireStringParam(map, key);
  if (value.isEmpty || value.length > maxLen) {
    throw FormatException('"$key" must be 1..$maxLen characters');
  }
  return value;
}

int _requireIntParam(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw FormatException('Expected integer for "$key"');
  }
  return value;
}

bool _requireBoolParam(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) {
    throw FormatException('Expected boolean for "$key"');
  }
  return value;
}

final RegExp _subnetHashPattern = RegExp(r'^[0-9a-f]{16,64}$');
final RegExp _workspaceAliasPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');
final RegExp _capabilitiesVersionPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,32}$');
final RegExp _isoTimestampTzPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:([Zz])|([+-])(\d{2}):?(\d{2}))$',
);

bool _isLeapYear(int year) =>
    (year % 4 == 0) && ((year % 100 != 0) || (year % 400 == 0));

int _daysInMonth(int year, int month) {
  switch (month) {
    case 1:
    case 3:
    case 5:
    case 7:
    case 8:
    case 10:
    case 12:
      return 31;
    case 4:
    case 6:
    case 9:
    case 11:
      return 30;
    case 2:
      return _isLeapYear(year) ? 29 : 28;
    default:
      return 0;
  }
}

DateTime? _parseStrictIsoTimestampUtc(String raw) {
  final match = _isoTimestampTzPattern.firstMatch(raw);
  if (match == null) {
    return null;
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);

  if (year < 1 || month < 1 || month > 12) {
    return null;
  }
  if (day < 1 || day > _daysInMonth(year, month)) {
    return null;
  }
  if (hour < 0 ||
      hour > 23 ||
      minute < 0 ||
      minute > 59 ||
      second < 0 ||
      second > 59) {
    return null;
  }
  if (match.group(7) == null) {
    final tzHour = int.parse(match.group(9)!);
    final tzMinute = int.parse(match.group(10)!);
    if (tzHour < 0 || tzHour > 23 || tzMinute < 0 || tzMinute > 59) {
      return null;
    }
  }
  return DateTime.tryParse(raw)?.toUtc();
}

PresenceParams _parsePresenceParams(Map<String, Object?> params) {
  _requireExactParamsKeys(
    params,
    const <String>{
      'schemaVersion',
      'idleSeconds',
      'screenLocked',
      'mediaPlaying',
      'updatedAt',
    },
    optionalKeys: const <String>{
      'batteryPercent',
      'isCharging',
      'subnetHash',
      'foregroundAppId',
    },
  );
  final schemaVersion = _requireIntParam(params, 'schemaVersion');
  if (schemaVersion != 1) {
    throw FormatException(
      'Unsupported xuna/presence schemaVersion: $schemaVersion',
    );
  }
  final idleSeconds = _requireIntParam(params, 'idleSeconds');
  if (idleSeconds < 0) {
    throw const FormatException('idleSeconds must be >= 0');
  }
  final screenLocked = _requireBoolParam(params, 'screenLocked');
  final mediaPlaying = _requireBoolParam(params, 'mediaPlaying');

  int? batteryPercent;
  if (params.containsKey('batteryPercent') &&
      params['batteryPercent'] != null) {
    batteryPercent = _requireIntParam(params, 'batteryPercent');
    if (batteryPercent < 0 || batteryPercent > 100) {
      throw const FormatException('batteryPercent must be in 0..100');
    }
  }

  bool? isCharging;
  if (params.containsKey('isCharging') && params['isCharging'] != null) {
    isCharging = _requireBoolParam(params, 'isCharging');
  }

  String? subnetHash;
  if (params.containsKey('subnetHash') && params['subnetHash'] != null) {
    subnetHash = _requireStringParam(params, 'subnetHash');
    if (!_subnetHashPattern.hasMatch(subnetHash)) {
      throw const FormatException('Invalid subnetHash format');
    }
  }

  String? foregroundAppId;
  if (params.containsKey('foregroundAppId') &&
      params['foregroundAppId'] != null) {
    foregroundAppId = _requireStringParam(params, 'foregroundAppId');
    if (!isValidShortId(foregroundAppId) ||
        isHardDeniedAppOrProcess(foregroundAppId)) {
      throw const FormatException('Invalid or hard-denied foregroundAppId');
    }
  }

  final updatedAtRaw = _requireStringParam(params, 'updatedAt');
  final updatedAt = _parseStrictIsoTimestampUtc(updatedAtRaw);
  if (updatedAt == null) {
    throw const FormatException('Invalid updatedAt ISO-8601 UTC timestamp');
  }

  return PresenceParams(
    schemaVersion: schemaVersion,
    idleSeconds: idleSeconds,
    screenLocked: screenLocked,
    mediaPlaying: mediaPlaying,
    batteryPercent: batteryPercent,
    isCharging: isCharging,
    subnetHash: subnetHash,
    foregroundAppId: foregroundAppId,
    updatedAt: updatedAt,
  );
}

ResourcesParams _parseResourcesParams(Map<String, Object?> params) {
  _requireExactParamsKeys(
    params,
    const <String>{'schemaVersion', 'installedApps', 'workspaces'},
    optionalKeys: const <String>{'capabilitiesVersion', 'toolchains'},
  );
  final schemaVersion = _requireIntParam(params, 'schemaVersion');
  if (schemaVersion != 1) {
    throw FormatException(
      'Unsupported xuna/resources schemaVersion: $schemaVersion',
    );
  }

  final rawApps = params['installedApps'];
  if (rawApps is! List) {
    throw const FormatException('installedApps must be a list');
  }
  if (rawApps.length > 256) {
    throw const FormatException('installedApps exceeds max 256 items');
  }
  final installedApps = <String>[];
  for (final item in rawApps) {
    if (item is! String ||
        !isValidShortId(item) ||
        isHardDeniedAppOrProcess(item)) {
      throw const FormatException('Invalid or hard-denied installedApps item');
    }
    installedApps.add(item);
  }

  final rawWorkspaces = params['workspaces'];
  if (rawWorkspaces is! List) {
    throw const FormatException('workspaces must be a list');
  }
  if (rawWorkspaces.length > 128) {
    throw const FormatException('workspaces exceeds max 128 items');
  }
  final workspaces = <String>[];
  for (final item in rawWorkspaces) {
    if (item is! String ||
        item.contains('/') ||
        item.contains(r'\') ||
        item == '.' ||
        item == '..' ||
        item.contains('..') ||
        !_workspaceAliasPattern.hasMatch(item)) {
      throw const FormatException('Invalid workspaces alias');
    }
    workspaces.add(item);
  }

  String? capabilitiesVersion;
  if (params.containsKey('capabilitiesVersion') &&
      params['capabilitiesVersion'] != null) {
    capabilitiesVersion = _requireStringParam(params, 'capabilitiesVersion');
    if (!_capabilitiesVersionPattern.hasMatch(capabilitiesVersion)) {
      throw const FormatException('Invalid capabilitiesVersion format');
    }
  }

  final toolchains = <XtpToolchainEntry>[];
  if (params.containsKey('toolchains')) {
    final rawToolchains = params['toolchains'];
    if (rawToolchains is! List) {
      throw const FormatException('toolchains must be a list');
    }
    if (rawToolchains.length > XtpToolchainEntry.maxToolchains) {
      throw const FormatException('toolchains exceeds max 64 items');
    }
    final seenIds = <String>{};
    for (final item in rawToolchains) {
      if (item is! Map) {
        throw const FormatException('toolchains item must be an object');
      }
      final entry = XtpToolchainEntry.fromJson(_castStringObjectMap(item));
      if (!seenIds.add(entry.id)) {
        throw FormatException('Duplicate toolchain id "${entry.id}"');
      }
      toolchains.add(entry);
    }
  }

  return ResourcesParams(
    schemaVersion: schemaVersion,
    installedApps: List<String>.unmodifiable(installedApps),
    workspaces: List<String>.unmodifiable(workspaces),
    capabilitiesVersion: capabilitiesVersion,
    toolchains: List<XtpToolchainEntry>.unmodifiable(toolchains),
  );
}

FocusRequestParams _parseFocusRequestParams(Map<String, Object?> params) {
  _requireExactParamsKeys(
    params,
    const <String>{'schemaVersion', 'source'},
    optionalKeys: const <String>{'followMe'},
  );
  final schemaVersion = _requireIntParam(params, 'schemaVersion');
  if (schemaVersion != 1) {
    throw FormatException(
      'Unsupported xuna/focusRequest schemaVersion: $schemaVersion',
    );
  }
  final source = FocusRequestSource.fromWire(
    _requireStringParam(params, 'source'),
  );
  bool? followMe;
  if (params.containsKey('followMe') && params['followMe'] != null) {
    followMe = _requireBoolParam(params, 'followMe');
  }
  return FocusRequestParams(
    schemaVersion: schemaVersion,
    source: source,
    followMe: followMe,
  );
}

Map<String, Object?> _requireMapParam(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! Map) {
    throw FormatException('Expected object for "$key"');
  }
  final out = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('Expected string key in "$key"');
    }
    out[entry.key as String] = entry.value;
  }
  return out;
}

WatchRegisterParams _parseWatchRegisterParams(Map<String, Object?> params) {
  _requireExactParamsKeys(
    params,
    const <String>{
      'schemaVersion',
      'watchId',
      'jobId',
      'mode',
      'target',
      'quiescenceSeconds',
      'minWaitSeconds',
      'maxWaitSeconds',
      'requireInitialChange',
      'releaseFocus',
    },
    optionalKeys: const <String>{'signals'},
  );
  final schemaVersion = _requireIntParam(params, 'schemaVersion');
  final watchId = _requireStringParam(params, 'watchId');
  final jobId = _requireStringParam(params, 'jobId');
  final mode = WatchMode.fromWire(_requireStringParam(params, 'mode'));

  List<WatchSignal>? signals;
  if (mode == WatchMode.composite) {
    if (!params.containsKey('signals')) {
      throw const FormatException('composite mode requires signals');
    }
    final rawSignals = params['signals'];
    if (rawSignals is! List) {
      throw const FormatException('signals must be a list');
    }
    final parsed = <WatchSignal>[];
    for (final item in rawSignals) {
      if (item is! String) {
        throw const FormatException('signals items must be strings');
      }
      parsed.add(WatchSignal.fromWire(item));
    }
    signals = List<WatchSignal>.unmodifiable(parsed);
  } else if (params.containsKey('signals')) {
    throw const FormatException(
        'signals is forbidden unless mode is composite');
  }

  final target = WatchTarget.fromJson(_requireMapParam(params, 'target'));
  final quiescenceSeconds = _requireIntParam(params, 'quiescenceSeconds');
  final minWaitSeconds = _requireIntParam(params, 'minWaitSeconds');
  final maxWaitSeconds = _requireIntParam(params, 'maxWaitSeconds');
  final requireInitialChange = _requireBoolParam(
    params,
    'requireInitialChange',
  );
  final releaseFocus = _requireBoolParam(params, 'releaseFocus');

  final result = WatchRegisterParams(
    schemaVersion: schemaVersion,
    watchId: watchId,
    jobId: jobId,
    mode: mode,
    signals: signals,
    target: target,
    quiescenceSeconds: quiescenceSeconds,
    minWaitSeconds: minWaitSeconds,
    maxWaitSeconds: maxWaitSeconds,
    requireInitialChange: requireInitialChange,
    releaseFocus: releaseFocus,
  );
  result.validate();
  return result;
}

WatchCancelParams _parseWatchCancelParams(Map<String, Object?> params) {
  _requireExactParamsKeys(
    params,
    const <String>{'schemaVersion', 'reason'},
    optionalKeys: const <String>{'watchId', 'jobId'},
  );
  final schemaVersion = _requireIntParam(params, 'schemaVersion');
  String? watchId;
  if (params.containsKey('watchId') && params['watchId'] != null) {
    watchId = _requireStringParam(params, 'watchId');
  }
  String? jobId;
  if (params.containsKey('jobId') && params['jobId'] != null) {
    jobId = _requireStringParam(params, 'jobId');
  }
  final reason = WatchCancelReason.fromWire(
    _requireStringParam(params, 'reason'),
  );
  final result = WatchCancelParams(
    schemaVersion: schemaVersion,
    watchId: watchId,
    jobId: jobId,
    reason: reason,
  );
  result.validate();
  return result;
}

WatchEventParams _parseWatchEventParams(Map<String, Object?> params) {
  _requireExactParamsKeys(
    params,
    const <String>{
      'schemaVersion',
      'watchId',
      'jobId',
      'kind',
      'observedSignals',
      'elapsedSeconds',
      'changeCount',
      'digestChanged',
      'occurredAt',
    },
    optionalKeys: const <String>{'errorCode'},
  );
  final schemaVersion = _requireIntParam(params, 'schemaVersion');
  final watchId = _requireStringParam(params, 'watchId');
  final jobId = _requireStringParam(params, 'jobId');
  final kind = WatchEventKind.fromWire(_requireStringParam(params, 'kind'));

  final rawSignals = params['observedSignals'];
  if (rawSignals is! List) {
    throw const FormatException('observedSignals must be a list');
  }
  final observedSignals = <WatchSignal>[];
  for (final item in rawSignals) {
    if (item is! String) {
      throw const FormatException('observedSignals items must be strings');
    }
    observedSignals.add(WatchSignal.fromWire(item));
  }

  final elapsedSeconds = _requireIntParam(params, 'elapsedSeconds');
  final changeCount = _requireIntParam(params, 'changeCount');
  final digestChanged = _requireBoolParam(params, 'digestChanged');
  final occurredAtRaw = _requireStringParam(params, 'occurredAt');
  final occurredAt = _parseStrictIsoTimestampUtc(occurredAtRaw);
  if (occurredAt == null) {
    throw const FormatException(
      'Invalid occurredAt ISO-8601 UTC timestamp',
    );
  }

  String? errorCode;
  if (kind == WatchEventKind.error) {
    if (!params.containsKey('errorCode') || params['errorCode'] == null) {
      throw const FormatException('errorCode is required when kind is error');
    }
    errorCode = _requireStringParam(params, 'errorCode');
  } else if (params.containsKey('errorCode')) {
    throw const FormatException('errorCode is forbidden unless kind is error');
  }

  final result = WatchEventParams(
    schemaVersion: schemaVersion,
    watchId: watchId,
    jobId: jobId,
    kind: kind,
    observedSignals: List<WatchSignal>.unmodifiable(observedSignals),
    elapsedSeconds: elapsedSeconds,
    changeCount: changeCount,
    digestChanged: digestChanged,
    occurredAt: occurredAt,
    errorCode: errorCode,
  );
  result.validate();
  return result;
}
