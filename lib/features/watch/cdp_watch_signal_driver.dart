import 'dart:async';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/browser_bridge/cdp_browser_engine_provider.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Chrome DevTools Protocol (`cdp_idle`) driver observing DOM updates and
/// in-flight network requests on a specific browser `tabId`.
class CdpWatchSignalDriver implements WatchSignalDriver {
  CdpWatchSignalDriver({
    required CdpBrowserEngineProvider cdpProvider,
    required ContentFreeLogger logger,
  }) : _cdpProvider = cdpProvider,
       _logger = logger;

  final CdpBrowserEngineProvider _cdpProvider;
  final ContentFreeLogger _logger;

  @override
  Set<WatchSignal> get supportedSignals => const <WatchSignal>{
    WatchSignal.cdpIdle,
  };

  @override
  Future<WatchSignalSubscription> startSignal({
    required String watchId,
    required WatchSignal signal,
    required WatchTarget target,
    required bool releaseFocus,
    required void Function(WatchSignalUpdate update) onUpdate,
  }) async {
    if (signal != WatchSignal.cdpIdle) {
      throw WatchDriverException(
        errorCode: 'watch_unsupported',
        message: 'CDP driver supports only cdp_idle.',
      );
    }
    final tabId = target.tabId?.trim() ?? '';
    if (tabId.isEmpty) {
      throw const WatchDriverException(
        errorCode: 'target_not_found',
        message: 'cdp_idle requires target.tabId.',
      );
    }

    final CdpTabWatchSession session;
    try {
      session = await _cdpProvider.openTabWatchSession(tabId: tabId);
    } on XunaHostChannelException catch (error) {
      final mapped = _mapCdpErrorCode(error);
      _logger.warning('watch.cdp_start_failed', <String, Object?>{
        'source': 'cdp_watch',
        'status': 'failed',
        'errorCode': mapped,
      });
      throw WatchDriverException(errorCode: mapped, message: error.message);
    } on SocketException catch (error) {
      _logger.warning('watch.cdp_start_failed', const <String, Object?>{
        'source': 'cdp_watch',
        'status': 'failed',
        'errorCode': 'watch_unsupported',
      });
      throw WatchDriverException(
        errorCode: 'watch_unsupported',
        message: error.message,
      );
    } on TimeoutException catch (error) {
      _logger.warning('watch.cdp_start_failed', const <String, Object?>{
        'source': 'cdp_watch',
        'status': 'failed',
        'errorCode': 'watch_unsupported',
      });
      throw WatchDriverException(
        errorCode: 'watch_unsupported',
        message: error.message,
      );
    } catch (_) {
      _logger.warning('watch.cdp_start_failed', const <String, Object?>{
        'source': 'cdp_watch',
        'status': 'failed',
        'errorCode': 'watch_unsupported',
      });
      throw const WatchDriverException(
        errorCode: 'watch_unsupported',
        message: 'Unable to open CDP tab watch session.',
      );
    }

    final sub = _CdpWatchSubscription(
      session: session,
      logger: _logger,
      onUpdate: onUpdate,
    );
    sub.listen();
    _logger.info('watch.cdp_started', const <String, Object?>{
      'source': 'cdp_watch',
      'status': 'started',
    });
    return sub;
  }

  static String _mapCdpErrorCode(XunaHostChannelException error) {
    if (error.errorCode == 'target_not_found') {
      return 'target_not_found';
    }
    if (error.errorCode == 'invalid_args' ||
        error.status == XtpStatus.invalidArgs) {
      return 'target_not_found';
    }
    return 'watch_unsupported';
  }
}

class _CdpWatchSubscription implements WatchSignalSubscription {
  _CdpWatchSubscription({
    required CdpTabWatchSession session,
    required ContentFreeLogger logger,
    required this.onUpdate,
  }) : _session = session,
       _logger = logger;

  final CdpTabWatchSession _session;
  final ContentFreeLogger _logger;
  final void Function(WatchSignalUpdate update) onUpdate;

  final Set<String> _inflightIds = <String>{};
  int _anonymousInflight = 0;
  StreamSubscription<CdpPageEvent>? _eventSub;
  bool _disposed = false;
  bool _wasActive = false;

  @override
  bool get eventDriven => true;

  @override
  bool get fallbackUsed => false;

  void listen() {
    _eventSub = _session.events.listen(_handleEvent);
    unawaited(
      _session.closed.then((_) {
        if (_disposed) return;
        onUpdate(
          const WatchSignalUpdate(
            signal: WatchSignal.cdpIdle,
            state: WatchSignalState.lost,
          ),
        );
      }),
    );
  }

  bool get _hasInflight => _inflightIds.isNotEmpty || _anonymousInflight > 0;

  void _handleEvent(CdpPageEvent event) {
    if (_disposed) return;
    switch (event.method) {
      case 'Network.requestWillBeSent':
        final reqId = event.params['requestId'];
        if (reqId is String && reqId.isNotEmpty) {
          _inflightIds.add(reqId);
        } else {
          _anonymousInflight++;
        }
        _wasActive = true;
        onUpdate(
          const WatchSignalUpdate(
            signal: WatchSignal.cdpIdle,
            state: WatchSignalState.active,
          ),
        );
      case 'Network.loadingFinished':
      case 'Network.loadingFailed':
        final reqId = event.params['requestId'];
        if (reqId is String && reqId.isNotEmpty) {
          _inflightIds.remove(reqId);
        } else if (_anonymousInflight > 0) {
          _anonymousInflight--;
        }
        if (!_hasInflight) {
          if (_wasActive) {
            _wasActive = false;
            onUpdate(
              const WatchSignalUpdate(
                signal: WatchSignal.cdpIdle,
                state: WatchSignalState.changed,
              ),
            );
          } else {
            onUpdate(
              const WatchSignalUpdate(
                signal: WatchSignal.cdpIdle,
                state: WatchSignalState.idle,
              ),
            );
          }
        }
      case 'DOM.documentUpdated':
        onUpdate(
          const WatchSignalUpdate(
            signal: WatchSignal.cdpIdle,
            state: WatchSignalState.changed,
            digestChanged: true,
          ),
        );
        if (_disposed) return;
        if (_hasInflight) {
          onUpdate(
            const WatchSignalUpdate(
              signal: WatchSignal.cdpIdle,
              state: WatchSignalState.active,
            ),
          );
        }
      default:
        break;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _session.close();
    } catch (_) {
      // Best-effort cleanup.
    }
    _logger.info('watch.cdp_stopped', const <String, Object?>{
      'source': 'cdp_watch',
      'status': 'stopped',
    });
  }
}
