import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'schemas.dart';

/// Maximum WebSocket text frame size in UTF-8 bytes (`64 KiB`).
const int maxXtpFrameBytes = 65536;

/// Maximum `structuredContent` size in UTF-8 bytes (`16 KiB`).
const int maxStructuredContentBytes = 16384;

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
  'ping',
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
        message: 'Frame exceeds 64 KiB limit',
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
        message: 'Frame exceeds 64 KiB limit',
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
  }) {
    final scBytes = utf8.encode(jsonEncode(structuredContent)).length;
    if (scBytes > maxStructuredContentBytes) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'structuredContent exceeds 16 KiB limit',
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
        'structuredContent': structuredContent,
        'isError': status.isError,
        '_meta': meta,
      },
    );
  }

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

/// `ping` request params.
class PingParams extends XtpRequestParams {
  const PingParams();
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
      case 'ping':
        _requireExactParamsKeys(params, const <String>{});
        return const PingParams();
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
    final scBytes = utf8.encode(jsonEncode(sc)).length;
    if (scBytes > maxStructuredContentBytes) {
      throw XtpProtocolException(
        jsonRpcCode: JsonRpcErrorCode.invalidParams,
        message: 'structuredContent exceeds 16 KiB limit',
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
