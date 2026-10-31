import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Default port for the Desktop Agent LAN offline server (`UDC-7` S7.4).
const int defaultLanOfflinePort = 47821;

/// Default WebSocket path for the LAN offline server (`UDC-7` S7.4).
const String lanOfflinePath = '/xuna-lan';

/// Optional LAN offline WebSocket server + UDP mDNS responder (`UDC-7` S7.4).
///
/// Security invariants:
/// - **Off by default**; only started when the owner explicitly enables LAN
///   mode in the Desktop Agent settings.
/// - Rejects browser `Origin` headers (`http://` / `https://`) to prevent
///   cross-origin WebSocket hijacking from web pages.
/// - Requires **mutual P-256 challenge-response proof**:
///   1. Server challenges the client (`xuna/challenge`, 32-byte nonce) and
///      verifies `xuna/proof` against the owner's pinned phone public keys
///      received over the authenticated backend session (`xuna/lanPeer`).
///   2. Client challenges the server (`xuna/challenge`, 32-byte nonce) and
///      server signs `xuna/proof` with the host's hardware-backed P-256 key so
///      the phone verifies the pinned host public key.
/// - **Strictly `media.*` only**: any `tools/call` whose tool name does not
///   start with `media.` is immediately rejected with `XtpStatus.denied` and
///   `errorCode = "lan_media_only"` (`app.*`, `url.*`, `workflow.*`, `host.*`
///   are never reachable over LAN).
class LanOfflineServer {
  LanOfflineServer({
    required this.channel,
    required this.enrollmentStore,
    required this.dispatcher,
    required this.logger,
    this.bindAddress = '0.0.0.0',
    this.port = defaultLanOfflinePort,
    this.enableMdns = true,
    Random? random,
  }) : _random = random ?? Random.secure();

  final XunaHostChannel channel;
  final EnrollmentStateStore enrollmentStore;
  final HostToolDispatcher dispatcher;
  final ContentFreeLogger logger;
  final String bindAddress;
  final int port;
  final bool enableMdns;
  final Random _random;

  HttpServer? _httpServer;
  RawDatagramSocket? _mdnsSocket;
  StreamSubscription<HttpRequest>? _httpSub;
  StreamSubscription<RawSocketEvent>? _mdnsSub;
  final Set<WebSocket> _activeSockets = <WebSocket>{};

  bool get isRunning => _httpServer != null;
  int? get boundPort => _httpServer?.port;

  /// Computes the 16-hex-character `hostIdHash` advertised over mDNS TXT/JSON.
  static String computeHostIdHash(String hostId) =>
      sha256.convert(utf8.encode(hostId)).toString().substring(0, 16);

  /// Starts listening for LAN WebSocket connections on `[bindAddress]:[port]`.
  Future<void> start() async {
    if (_httpServer != null) return;
    final server = await HttpServer.bind(bindAddress, port, shared: true);
    _httpServer = server;
    _httpSub = server.listen(
      _handleHttpRequest,
      onError: (_) {},
      cancelOnError: false,
    );

    if (enableMdns) {
      await _startMdnsResponder();
    }

    logger.info('lan.server_started', <String, Object?>{
      'port': server.port,
    });
  }

  /// Stops the LAN server and closes all active LAN WebSocket sessions.
  Future<void> stop() async {
    await _mdnsSub?.cancel();
    _mdnsSub = null;
    _mdnsSocket?.close();
    _mdnsSocket = null;

    await _httpSub?.cancel();
    _httpSub = null;

    final sockets = List<WebSocket>.of(_activeSockets);
    _activeSockets.clear();
    for (final ws in sockets) {
      try {
        await ws.close(XtpCloseCode.goingAway, 'lan_stopped');
      } catch (_) {}
    }

    final server = _httpServer;
    _httpServer = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
      logger.info('lan.server_stopped');
    }
  }

  Future<void> _startMdnsResponder() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        5353,
        reuseAddress: true,
        reusePort: false,
      );
      try {
        socket.joinMulticast(InternetAddress('224.0.0.251'));
      } catch (_) {}
      _mdnsSocket = socket;
      _mdnsSub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        _handleMdnsDatagram(dg);
      });
    } catch (_) {
      // Non-fatal if port 5353 is unavailable or restricted in tests/OS.
    }
  }

  void _handleMdnsDatagram(Datagram dg) {
    final enrolled = enrollmentStore.current;
    final serverPort = _httpServer?.port;
    if (enrolled == null || serverPort == null) return;
    try {
      final text = utf8.decode(dg.data, allowMalformed: true);
      if (!text.contains('_xuna-host._tcp.local')) return;
      final payload = jsonEncode(<String, Object?>{
        'service': '_xuna-host._tcp.local',
        'hostIdHash': computeHostIdHash(enrolled.hostId),
        'port': serverPort,
      });
      _mdnsSocket?.send(utf8.encode(payload), dg.address, dg.port);
    } catch (_) {}
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final origin = request.headers.value('origin');
    if (origin != null &&
        (origin.startsWith('http://') || origin.startsWith('https://'))) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    if (request.uri.path != lanOfflinePath ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final enrolled = enrollmentStore.current;
    if (enrolled == null || enrolled.pinnedPhonePublicKeyBytes.isEmpty) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }

    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      return;
    }

    _activeSockets.add(ws);
    unawaited(_serveLanSocket(ws, enrolled));
  }

  Future<void> _serveLanSocket(
    WebSocket ws,
    EnrolledHostState enrolled,
  ) async {
    final serverNonce = Uint8List.fromList(
      List<int>.generate(hostProofNonceSize, (_) => _random.nextInt(256)),
    );
    var phoneAuthenticated = false;
    var nextServerRpcId = 1;

    void sendFrame(XtpFrame frame) {
      if (ws.readyState != WebSocket.open) return;
      try {
        ws.add(frame.encode());
      } catch (_) {}
    }

    // 1. Send server -> phone challenge immediately upon connect.
    sendFrame(
      XtpNotification(
        method: 'xuna/challenge',
        params: <String, Object?>{
          'purpose': HostProofPurpose.session.code,
          'nonce': base64.encode(serverNonce),
          'expiresIn': 60,
        },
        typedParams: ChallengeParams(
          purpose: HostProofPurpose.session,
          nonceBytes: serverNonce,
          expiresIn: 60,
        ),
      ),
    );

    try {
      await for (final raw in ws) {
        if (raw is! String) continue;
        final XtpFrame frame;
        try {
          frame = XtpFrame.parse(raw);
        } on XtpProtocolException catch (err) {
          final errResp = err.toErrorResponse();
          if (errResp != null) {
            sendFrame(errResp);
          }
          continue;
        }

        switch (frame) {
          case XtpNotification():
            final typed = frame.typedParams;
            if (typed is ChallengeParams &&
                typed.purpose == HostProofPurpose.session) {
              // Client challenges the host so the phone can verify the pinned
              // host P-256 public key (mutual proof).
              final hostPubKey = await channel.keyEnsure();
              final msg = hostProofMessage(
                nonce: typed.nonceBytes,
                purpose: HostProofPurpose.session,
                payload: hostPubKey,
                hostIdUuid: enrolled.hostId,
              );
              final sig = await channel.keySign(msg);
              sendFrame(
                XtpRequest(
                  id: nextServerRpcId++,
                  method: 'xuna/proof',
                  params: <String, Object?>{
                    'purpose': HostProofPurpose.session.code,
                    'signature': base64.encode(sig),
                  },
                  typedParams: ProofParams(
                    purpose: HostProofPurpose.session,
                    signatureBytes: sig,
                  ),
                ),
              );
            }
          case XtpRequest():
            final typed = frame.typedParams;
            switch (typed) {
              case ProofParams():
                if (typed.purpose != HostProofPurpose.session) {
                  await ws.close(XtpCloseCode.policyViolation, 'unauthorized');
                  return;
                }
                final pinnedKeys =
                    enrollmentStore.current?.pinnedPhonePublicKeyBytes ??
                    enrolled.pinnedPhonePublicKeyBytes;
                final matched = pinnedKeys.any((phonePubKey) {
                  final msg = hostProofMessage(
                    nonce: serverNonce,
                    purpose: HostProofPurpose.session,
                    payload: phonePubKey,
                    hostIdUuid: enrolled.hostId,
                  );
                  return verifyP256Signature(
                    publicKey: phonePubKey,
                    message: msg,
                    signature: typed.signatureBytes,
                  );
                });
                if (!matched) {
                  logger.warning('lan.auth_failed');
                  await ws.close(XtpCloseCode.policyViolation, 'unauthorized');
                  return;
                }
                phoneAuthenticated = true;
                sendFrame(
                  XtpResponse(
                    id: frame.id,
                    result: const <String, Object?>{'verified': true},
                  ),
                );
                sendFrame(
                  XtpNotification(
                    method: 'xuna/ready',
                    params: <String, Object?>{
                      'serverTime': DateTime.now().toUtc().toIso8601String(),
                      'heartbeatS': 30,
                    },
                    typedParams: ReadyParams(
                      serverTime: DateTime.now().toUtc(),
                      heartbeatS: 30,
                    ),
                  ),
                );
              case PingParams():
                sendFrame(
                  XtpResponse(id: frame.id, result: const <String, Object?>{}),
                );
              case ToolsCallParams():
                if (!phoneAuthenticated) {
                  await ws.close(XtpCloseCode.policyViolation, 'unauthorized');
                  return;
                }
                if (!typed.name.startsWith('media.')) {
                  sendFrame(
                    XtpResponse.toolCallResult(
                      id: frame.id,
                      text:
                          'Chế độ LAN ngoại tuyến chỉ hỗ trợ điều khiển nhạc (media.*).',
                      structuredContent: const <String, Object?>{},
                      status: XtpStatus.denied,
                      durationMs: 0,
                      errorCode: 'lan_media_only',
                    ),
                  );
                  continue;
                }
                final resp = await dispatcher.dispatch(
                  requestId: frame.id,
                  params: typed,
                );
                sendFrame(resp);
              case ToolsListParams():
              case HelloEnrollParams():
              case HelloReconnectParams():
                sendFrame(
                  XtpErrorResponse(
                    id: frame.id,
                    code: JsonRpcErrorCode.methodNotFound,
                    message: 'Method not found',
                  ),
                );
            }
          case XtpResponse():
          case XtpErrorResponse():
            break;
        }
      }
    } catch (_) {
      // Socket closed or errored.
    } finally {
      _activeSockets.remove(ws);
      try {
        await ws.close();
      } catch (_) {}
    }
  }
}
