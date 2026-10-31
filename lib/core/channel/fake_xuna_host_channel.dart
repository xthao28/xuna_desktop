import 'dart:typed_data';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Deterministic in-memory implementation of [XunaHostChannel] for unit tests
/// (`UDC-3` §6 Session S3.4).
///
/// Never records sensitive arguments in logs; exposes counters and hooks so
/// tests can simulate permissions, failures, and timeouts.
class FakeXunaHostChannel implements XunaHostChannel {
  FakeXunaHostChannel({
    Uint8List? publicKey,
    Uint8List Function(Uint8List message)? signer,
    this.systemInfo = const HostSystemInfo(
      platform: HostPlatform.windows,
      osVersion: '10.0.22631',
      hostname: 'PC-PHONG-LAM-VIEC',
    ),
    this.permissionSnapshot = const HostPermissionSnapshot(),
  }) : _publicKey = publicKey ?? _defaultPublicKey,
       _signer = signer ?? _defaultSigner;

  static final Uint8List defaultPrivateScalar = Uint8List.fromList(
    List<int>.generate(32, (i) => (i + 11) & 0xff),
  );

  static final Uint8List _defaultPublicKey = deriveP256PublicKey(
    defaultPrivateScalar,
  );

  static Uint8List _defaultSigner(Uint8List message) => signP256Deterministic(
    privateScalar32: defaultPrivateScalar,
    message: message,
  );

  final Uint8List _publicKey;
  final Uint8List Function(Uint8List message) _signer;

  HostSystemInfo systemInfo;
  HostPermissionSnapshot permissionSnapshot;
  NowPlayingSnapshot nowPlayingResult = const NowPlayingSnapshot(
    state: 'playing',
    title: 'Lofi Study Beats',
    artist: 'XUNA Radio',
    app: 'spotify',
  );
  String mediaStateResult = 'playing';
  int currentVolume = 50;
  BrowserTabSnapshot browserCurrentUrlResult = const BrowserTabSnapshot(
    url: 'https://github.com/xthao28/xuna_pet',
    browser: 'edge',
  );

  /// Optional artificial delay before tool calls return (to test deadlines and
  /// cancellation).
  Duration simulatedDelay = Duration.zero;

  /// Optional exception to throw on the next provider call.
  XunaHostChannelException? nextException;

  final List<String> invokedMethods = <String>[];
  final List<({String title, String body})> toasts =
      <({String title, String body})>[];

  int get displayWakeCount =>
      invokedMethods.where((m) => m == 'displayWake').length;

  @override
  Future<Uint8List> keyEnsure() async {
    invokedMethods.add('keyEnsure');
    _throwIfConfigured();
    return Uint8List.fromList(_publicKey);
  }

  @override
  Future<Uint8List> keySign(Uint8List message) async {
    invokedMethods.add('keySign');
    _throwIfConfigured();
    return _signer(message);
  }

  @override
  Future<String> media(String cmd) async {
    invokedMethods.add('media:$cmd');
    await _delayAndThrowIfConfigured();
    return mediaStateResult;
  }

  @override
  Future<int> volumeSet(int level) async {
    invokedMethods.add('volumeSet');
    await _delayAndThrowIfConfigured();
    currentVolume = level;
    return currentVolume;
  }

  @override
  Future<NowPlayingSnapshot> nowPlaying(List<String> players) async {
    invokedMethods.add('nowPlaying');
    await _delayAndThrowIfConfigured();
    if (players.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'platform_unsupported',
      );
    }
    return nowPlayingResult;
  }

  @override
  Future<void> appLaunch({
    required AppLaunchKind kind,
    required String target,
  }) async {
    invokedMethods.add('appLaunch:${kind.wire}');
    await _delayAndThrowIfConfigured();
  }

  @override
  Future<void> urlOpen(String url) async {
    invokedMethods.add('urlOpen');
    await _delayAndThrowIfConfigured();
  }

  @override
  Future<BrowserTabSnapshot> browserCurrentUrl({
    String browser = 'auto',
  }) async {
    invokedMethods.add('browserCurrentUrl:$browser');
    await _delayAndThrowIfConfigured();
    return browserCurrentUrlResult;
  }

  @override
  Future<void> workflowRun({
    required WorkflowKind kind,
    required String target,
  }) async {
    invokedMethods.add('workflowRun:${kind.wire}');
    await _delayAndThrowIfConfigured();
  }

  @override
  Future<bool> displayWake() async {
    invokedMethods.add('displayWake');
    await _delayAndThrowIfConfigured();
    return true;
  }

  @override
  Future<HostPermissionSnapshot> permissions() async {
    invokedMethods.add('permissions');
    _throwIfConfigured();
    return permissionSnapshot;
  }

  @override
  Future<XtpPermissionState> requestPermission(String kind) async {
    invokedMethods.add('requestPermission:$kind');
    _throwIfConfigured();
    permissionSnapshot = const HostPermissionSnapshot(
      accessibility: XtpPermissionState.granted,
      notifications: XtpPermissionState.granted,
    );
    return XtpPermissionState.granted;
  }

  @override
  Future<HostSystemInfo> hostInfo() async {
    invokedMethods.add('hostInfo');
    _throwIfConfigured();
    return systemInfo;
  }

  @override
  Future<void> showToast({required String title, required String body}) async {
    invokedMethods.add('showToast');
    toasts.add((title: title, body: body));
  }

  Future<void> _delayAndThrowIfConfigured() async {
    if (simulatedDelay > Duration.zero) {
      await Future<void>.delayed(simulatedDelay);
    }
    _throwIfConfigured();
  }

  void _throwIfConfigured() {
    final err = nextException;
    if (err != null) {
      nextException = null;
      throw err;
    }
  }
}
