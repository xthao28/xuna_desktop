import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Lifecycle phase of the Desktop Agent's XTP v1 WebSocket session.
enum HostSessionPhase {
  disconnected,
  connecting,
  enrollWaitingConfirmation,
  ready,
}

/// Active enrollment QR + 6-digit SAS shown in the enrollment window while
/// waiting for the owner to scan and confirm on the phone (`UDC-3` §5.1).
class PendingEnrollmentDisplay {
  const PendingEnrollmentDisplay({
    required this.qrUri,
    required this.sas,
    required this.hostname,
    required this.expiresInSeconds,
  });

  final String qrUri;
  final String sas;
  final String hostname;
  final int expiresInSeconds;
}

/// Factory function that opens a [WebSocketChannel] to [uri].
typedef WebSocketConnector = WebSocketChannel Function(Uri uri);

/// XTP v1 WebSocket client (`UDC-3` §5.1, §5.2, §5.6.1):
/// - Mode A (enrollment) when no `hostId` is stored locally:
///   `xuna/hello {enroll}` → `xuna/challenge (1)` → `xuna/proof (1)` →
///   `xuna/enrollPending` (renders QR + SAS) → `xuna/enrolled` →
///   `xuna/challenge (2)` → `xuna/proof (2)` → `xuna/ready`.
/// - Mode B (reconnect) when `hostId` is stored locally:
///   `xuna/hello {hostId}` → `xuna/challenge (2)` → `xuna/proof (2)` →
///   `xuna/ready`.
/// - Handles `tools/list`, `tools/call`, `ping`, `notifications/cancelled`,
///   `xuna/stop`, and sends `notifications/tools/list_changed` when
///   `host-policy.json` changes.
/// - Exponential backoff (`1, 2, 4, 8, 16, 32, 60` s + `0..500` ms jitter)
///   when disconnected.
class XtpSessionClient {
  XtpSessionClient({
    required this.wsUri,
    required this.channel,
    required this.enrollmentStore,
    required this.policyStore,
    required this.dispatcher,
    required this.stopController,
    required this.logger,
    this.agentVersion = '0.1.0',
    WebSocketConnector? connector,
    Random? random,
    this.enableAutoReconnect = true,
  }) : _connector = connector ?? WebSocketChannel.connect,
       _random = random ?? Random.secure() {
    _policySub = policyStore.changes.listen((_) {
      if (_phase == HostSessionPhase.ready) {
        _sendNotification(
          const XtpNotification(
            method: 'notifications/tools/list_changed',
            params: <String, Object?>{},
            typedParams: ToolsListChangedParams(),
          ),
        );
      }
    });
    stopController.addCancelListener(_onLocalEmergencyStop);
  }

  void _onLocalEmergencyStop(StopReason reason) {
    if (reason != StopReason.ownerHost) return;
    if (_phase != HostSessionPhase.ready) return;
    _sendNotification(
      const XtpNotification(
        method: 'xuna/stop',
        params: <String, Object?>{'reason': 'owner_host'},
        typedParams: StopParams(reason: StopReason.ownerHost),
      ),
    );
  }

  /// Sends an outbound `xuna/lanPeer` advertisement to the backend (`UDC-7` S7.4).
  void sendLanPeerAdvertisement({
    required bool enabled,
    int port = 47821,
    String? certFingerprint,
  }) {
    if (_phase != HostSessionPhase.ready) return;
    final pubKey = _publicKey;
    final fp = certFingerprint ??
        (pubKey != null ? base64UrlNoPadEncode(publicKeyFingerprint(pubKey)) : null);
    _sendNotification(
      XtpNotification(
        method: 'xuna/lanPeer',
        params: <String, Object?>{
          'enabled': enabled,
          'port': port,
          if (fp != null) 'certFingerprint': fp,
        },
        typedParams: LanPeerParams(
          enabled: enabled,
          port: port,
          certFingerprint: fp,
        ),
      ),
    );
  }

  final Uri wsUri;
  final XunaHostChannel channel;
  final EnrollmentStateStore enrollmentStore;
  final HostPolicyStore policyStore;
  final HostToolDispatcher dispatcher;
  final EmergencyStopController stopController;
  final ContentFreeLogger logger;
  final String agentVersion;
  final WebSocketConnector _connector;
  final Random _random;
  final bool enableAutoReconnect;

  final StreamController<HostSessionPhase> _phaseChanges =
      StreamController<HostSessionPhase>.broadcast();
  final StreamController<PendingEnrollmentDisplay?> _enrollmentDisplayChanges =
      StreamController<PendingEnrollmentDisplay?>.broadcast();

  StreamSubscription<HostPolicyEvaluator>? _policySub;
  StreamSubscription<Object?>? _socketSub;
  WebSocketChannel? _socket;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;

  HostSessionPhase _phase = HostSessionPhase.disconnected;
  PendingEnrollmentDisplay? _enrollmentDisplay;
  int _reconnectAttempt = 0;
  int _nextRpcId = 1;
  bool _disposed = false;

  Uint8List? _publicKey;
  Uint8List? _activeEnrollCode;
  String? _activeHostId;

  HostSessionPhase get phase => _phase;
  PendingEnrollmentDisplay? get enrollmentDisplay => _enrollmentDisplay;
  Stream<HostSessionPhase> get phaseChanges => _phaseChanges.stream;
  Stream<PendingEnrollmentDisplay?> get enrollmentDisplayChanges =>
      _enrollmentDisplayChanges.stream;

  /// Computes the reconnect delay in milliseconds for [attempt] (`0, 1, 2...`):
  /// `min(60, 2^attempt)` seconds + `0..500` ms jitter (`UDC-3` §5.6.1).
  int computeBackoffMs(int attempt, {int? jitterMsOverride}) {
    final shift = attempt < 0 ? 0 : (attempt > 6 ? 6 : attempt);
    final baseSeconds = min(60, 1 << shift);
    final jitter = jitterMsOverride ?? _random.nextInt(501);
    return baseSeconds * 1000 + jitter;
  }

  /// Starts or restarts the WebSocket connection.
  Future<void> connect() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    await _closeCurrentSocket();

    _setPhase(HostSessionPhase.connecting);

    try {
      final pubKey = await channel.keyEnsure();
      validateP256PublicKey(pubKey);
      _publicKey = pubKey;
      final sysInfo = await channel.hostInfo();
      final enrolled = enrollmentStore.current ?? await enrollmentStore.load();

      final ws = _connector(wsUri);
      _socket = ws;
      _socketSub = ws.stream.listen(
        _onRawFrame,
        onError: (_) => _onSocketClosed(),
        onDone: _onSocketClosed,
        cancelOnError: false,
      );

      if (enrolled != null) {
        _activeHostId = enrolled.hostId;
        _activeEnrollCode = null;
        _setEnrollmentDisplay(null);
        _sendFrame(
          XtpRequest(
            id: _nextRpcId++,
            method: 'xuna/hello',
            params: <String, Object?>{
              'protocols': const <String>['xtp/1'],
              'hostId': enrolled.hostId,
              'platform': sysInfo.platform.wire,
              'osVersion': sysInfo.osVersion,
              'agentVersion': agentVersion,
            },
            typedParams: HelloReconnectParams(
              protocols: const <String>['xtp/1'],
              hostId: enrolled.hostId,
              platform: sysInfo.platform,
              osVersion: sysInfo.osVersion,
              agentVersion: agentVersion,
            ),
          ),
        );
      } else {
        final code = Uint8List.fromList(
          List<int>.generate(16, (_) => _random.nextInt(256)),
        );
        _activeEnrollCode = code;
        _activeHostId = null;
        _sendFrame(
          XtpRequest(
            id: _nextRpcId++,
            method: 'xuna/hello',
            params: <String, Object?>{
              'protocols': const <String>['xtp/1'],
              'enroll': <String, Object?>{
                'code': base64UrlNoPadEncode(code),
                'publicKey': base64.encode(pubKey),
                'platform': sysInfo.platform.wire,
                'osVersion': sysInfo.osVersion,
                'agentVersion': agentVersion,
                'hostname': sysInfo.hostname,
              },
            },
            typedParams: HelloEnrollParams(
              protocols: const <String>['xtp/1'],
              codeBytes: code,
              publicKeyBytes: pubKey,
              platform: sysInfo.platform,
              osVersion: sysInfo.osVersion,
              agentVersion: agentVersion,
              hostname: sysInfo.hostname,
            ),
          ),
        );
      }
    } catch (_) {
      logger.error('session.connect_failed');
      _scheduleReconnect();
    }
  }

  Future<void> _onRawFrame(Object? raw) async {
    if (raw is! String) {
      logger.warning('session.binary_frame_ignored');
      return;
    }
    final XtpFrame frame;
    try {
      frame = XtpFrame.parse(raw);
    } on XtpProtocolException catch (error) {
      logger.warning('session.frame_rejected', <String, Object?>{
        'errorCode': error.message,
      });
      final errResp = error.toErrorResponse();
      if (errResp != null) {
        _sendFrame(errResp);
      }
      return;
    }

    switch (frame) {
      case XtpNotification():
        await _handleNotification(frame);
      case XtpRequest():
        await _handleRequest(frame);
      case XtpResponse():
        // Responses to xuna/hello, xuna/proof, or ping.
        break;
      case XtpErrorResponse():
        logger.warning('session.rpc_error', <String, Object?>{
          'errorCode': frame.message,
        });
    }
  }

  Future<void> _handleNotification(XtpNotification notification) async {
    final typed = notification.typedParams;
    switch (typed) {
      case ChallengeParams():
        await _handleChallenge(typed);
      case EnrollPendingParams():
        await _handleEnrollPending(typed);
      case EnrolledParams():
        await _handleEnrolled(typed);
      case ReadyParams():
        _handleReady(typed);
      case CancelledParams():
        dispatcher.cancelRequest(typed.requestId, typed.reason);
      case StopParams():
        if (typed.reason == StopReason.revoked) {
          dispatcher.cancelAllInFlight('revoked');
          await enrollmentStore.clear();
          _activeHostId = null;
          await _closeCurrentSocket();
          if (enableAutoReconnect) {
            await connect();
          }
          return;
        }
        stopController.triggerStop(typed.reason);
      case LanPeerParams():
        if (typed.phonePublicKeys.isNotEmpty) {
          final keysB64 = typed.phonePublicKeys
              .map(base64.encode)
              .toList(growable: false);
          await enrollmentStore.updatePhonePublicKeys(keysB64);
          logger.info('session.lan_peer_keys_updated', <String, Object?>{
            'count': keysB64.length,
          });
        }
      case ProgressParams():
      case ToolsListChangedParams():
        break;
    }
  }

  Future<void> _handleChallenge(ChallengeParams challenge) async {
    final pubKey = _publicKey;
    if (pubKey == null) return;

    final Uint8List payload;
    final String? hostId;
    switch (challenge.purpose) {
      case HostProofPurpose.enroll:
        final code = _activeEnrollCode;
        if (code == null) return;
        payload = code;
        hostId = null;
      case HostProofPurpose.session:
        final currentHostId = _activeHostId ?? enrollmentStore.current?.hostId;
        if (currentHostId == null) return;
        payload = pubKey;
        hostId = currentHostId;
    }

    final message = hostProofMessage(
      nonce: challenge.nonceBytes,
      purpose: challenge.purpose,
      payload: payload,
      hostIdUuid: hostId,
    );
    final signature = await channel.keySign(message);
    _sendFrame(
      XtpRequest(
        id: _nextRpcId++,
        method: 'xuna/proof',
        params: <String, Object?>{
          'purpose': challenge.purpose.code,
          'signature': base64.encode(signature),
        },
        typedParams: ProofParams(
          purpose: challenge.purpose,
          signatureBytes: signature,
        ),
      ),
    );
  }

  Future<void> _handleEnrollPending(EnrollPendingParams pending) async {
    final code = _activeEnrollCode;
    final pubKey = _publicKey;
    if (code == null || pubKey == null) return;
    final sysInfo = await channel.hostInfo();
    final qrUri = buildEnrollmentUri(
      enrollmentCode: code,
      publicKey: pubKey,
      hostname: sysInfo.hostname,
    );
    final sas = computeSas(enrollmentCode: code, publicKey: pubKey);
    _setEnrollmentDisplay(
      PendingEnrollmentDisplay(
        qrUri: qrUri,
        sas: sas,
        hostname: sysInfo.hostname,
        expiresInSeconds: pending.expiresIn,
      ),
    );
    _setPhase(HostSessionPhase.enrollWaitingConfirmation);
  }

  Future<void> _handleEnrolled(EnrolledParams enrolled) async {
    _activeHostId = enrolled.hostId;
    _activeEnrollCode = null;
    await enrollmentStore.save(hostId: enrolled.hostId, alias: enrolled.alias);
    _setEnrollmentDisplay(null);
    logger.info('session.enrolled', <String, Object?>{
      'hostId': enrolled.hostId,
    });
  }

  void _handleReady(ReadyParams ready) {
    _reconnectAttempt = 0;
    _setEnrollmentDisplay(null);
    _setPhase(HostSessionPhase.ready);
    logger.info('session.ready');

    if (enrollmentStore.current?.lanEnabled == true) {
      sendLanPeerAdvertisement(enabled: true);
    }

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      Duration(seconds: ready.heartbeatS),
      (_) => _sendFrame(
        XtpRequest(
          id: _nextRpcId++,
          method: 'ping',
          params: const <String, Object?>{},
          typedParams: const PingParams(),
        ),
      ),
    );
  }

  Future<void> _handleRequest(XtpRequest request) async {
    final typed = request.typedParams;
    switch (typed) {
      case PingParams():
        _sendFrame(
          XtpResponse(id: request.id, result: const <String, Object?>{}),
        );
      case ToolsListParams():
        final tools = await dispatcher.buildManifest();
        _sendFrame(
          XtpResponse(
            id: request.id,
            result: <String, Object?>{
              'tools': tools.map((t) => t.toJson()).toList(),
            },
          ),
        );
      case ToolsCallParams():
        final response = await dispatcher.dispatch(
          requestId: request.id,
          params: typed,
        );
        _sendFrame(response);
      case HelloEnrollParams():
      case HelloReconnectParams():
      case ProofParams():
        _sendFrame(
          XtpErrorResponse(
            id: request.id,
            code: JsonRpcErrorCode.methodNotFound,
            message: 'Method not found',
          ),
        );
    }
  }

  void _onSocketClosed() {
    _heartbeatTimer?.cancel();
    final closeCode = _socket?.closeCode;
    final closeReason = _socket?.closeReason;
    _socket = null;
    _setPhase(HostSessionPhase.disconnected);

    logger.info('session.closed', <String, Object?>{
      if (closeCode != null) 'closeCode': closeCode,
      if (closeReason != null) 'reason': closeReason,
    });

    if (closeCode == XtpCloseCode.policyViolation &&
        (closeReason == 'unauthorized' || closeReason == 'revoked')) {
      dispatcher.cancelAllInFlight('revoked');
      unawaited(enrollmentStore.clear());
      _activeHostId = null;
    }

    if (closeCode == XtpCloseCode.duplicateSession) {
      // Another session superseded this one; do not loop aggressively.
      return;
    }

    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || !enableAutoReconnect) return;
    _reconnectTimer?.cancel();
    final delayMs = computeBackoffMs(_reconnectAttempt);
    _reconnectAttempt++;
    logger.info('session.reconnect_scheduled', <String, Object?>{
      'attempt': _reconnectAttempt,
      'delayMs': delayMs,
    });
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      unawaited(connect());
    });
  }

  void _sendNotification(XtpNotification notification) =>
      _sendFrame(notification);

  void _sendFrame(XtpFrame frame) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.sink.add(frame.encode());
    } catch (_) {
      // Socket closed while sending.
    }
  }

  void _setPhase(HostSessionPhase next) {
    if (_phase == next) return;
    _phase = next;
    if (!_phaseChanges.isClosed) {
      _phaseChanges.add(next);
    }
  }

  void _setEnrollmentDisplay(PendingEnrollmentDisplay? display) {
    _enrollmentDisplay = display;
    if (!_enrollmentDisplayChanges.isClosed) {
      _enrollmentDisplayChanges.add(display);
    }
  }

  Future<void> _closeCurrentSocket() async {
    await _socketSub?.cancel();
    _socketSub = null;
    final ws = _socket;
    _socket = null;
    if (ws != null) {
      try {
        await ws.sink.close(XtpCloseCode.goingAway, 'going_away');
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    stopController.removeCancelListener(_onLocalEmergencyStop);
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    await _policySub?.cancel();
    await _closeCurrentSocket();
    await _phaseChanges.close();
    await _enrollmentDisplayChanges.close();
  }
}
