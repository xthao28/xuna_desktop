import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

typedef HomeDirectoryResolver = String? Function();

/// Native OS watch driver backed by bounded unary `xuna/host` MethodChannel calls
/// (`watchStart`, `watchPoll`, `watchStop`) for macOS and Windows.
class NativeWatchSignalDriver implements WatchSignalDriver {
  NativeWatchSignalDriver({
    required XunaHostChannel channel,
    required AutoWorkspaceIndexer workspaceIndexer,
    required ContentFreeLogger logger,
    this.pollInterval = const Duration(milliseconds: 500),
    HomeDirectoryResolver? homeDirectoryResolver,
  }) : _channel = channel,
       _workspaceIndexer = workspaceIndexer,
       _logger = logger,
       _homeDirectoryResolver =
           homeDirectoryResolver ?? _defaultHomeDirectoryResolver;

  static String? _defaultHomeDirectoryResolver() =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  static const Set<String> _forbiddenWorkspaceSegments = <String>{
    '.ssh',
    '.aws',
    '.gnupg',
    '.kube',
    '.docker',
    '.claude',
    '.gemini',
    '.npmrc',
    '.netrc',
    '.pypirc',
    'library',
    'appdata',
    'keychains',
  };

  final XunaHostChannel _channel;
  final AutoWorkspaceIndexer _workspaceIndexer;
  final ContentFreeLogger _logger;
  final Duration pollInterval;
  final HomeDirectoryResolver _homeDirectoryResolver;

  @override
  Set<WatchSignal> get supportedSignals => const <WatchSignal>{
    WatchSignal.uiQuiescence,
    WatchSignal.uiChange,
    WatchSignal.processIdle,
    WatchSignal.fsQuiescence,
  };

  @override
  Future<WatchSignalSubscription> startSignal({
    required String watchId,
    required WatchSignal signal,
    required WatchTarget target,
    required bool releaseFocus,
    required void Function(WatchSignalUpdate update) onUpdate,
  }) async {
    if (!supportedSignals.contains(signal)) {
      throw WatchDriverException(
        errorCode: 'watch_unsupported',
        message: 'Signal ${signal.wire} is not handled by native driver.',
      );
    }

    if (target.appId != null && isHardDeniedAppOrProcess(target.appId)) {
      _logger.warning('watch.native_rejected', const <String, Object?>{
        'source': 'native_watch',
        'status': 'rejected',
        'errorCode': 'policy_blocked',
      });
      throw const WatchDriverException(
        errorCode: 'policy_blocked',
        message: 'Target application is blocked by policy.',
      );
    }

    String? workspacePath;
    switch (signal) {
      case WatchSignal.uiQuiescence:
      case WatchSignal.uiChange:
        if (target.pid == null &&
            target.windowId == null &&
            target.appId == null) {
          throw const WatchDriverException(
            errorCode: 'target_not_found',
            message: 'UI watch requires pid, windowId, or appId.',
          );
        }
      case WatchSignal.processIdle:
        if (target.pid == null || target.pid! <= 0) {
          throw const WatchDriverException(
            errorCode: 'target_not_found',
            message: 'process_idle requires a positive pid.',
          );
        }
      case WatchSignal.fsQuiescence:
        final alias = target.workspaceAlias;
        if (alias == null || alias.trim().isEmpty) {
          throw const WatchDriverException(
            errorCode: 'workspace_not_found',
            message: 'fs_quiescence requires workspaceAlias.',
          );
        }
        workspacePath = resolveSafeWatchWorkspacePath(alias);
      case WatchSignal.cdpIdle:
      case WatchSignal.timer:
      case WatchSignal.protocolAsync:
      case WatchSignal.execAsync:
        throw const WatchDriverException(
          errorCode: 'watch_unsupported',
          message: 'Unsupported signal for native watch driver.',
        );
    }

    final HostWatchStartResult startRes;
    try {
      startRes = await _channel.watchStart(
        watchId: watchId,
        signal: signal.wire,
        releaseFocus: releaseFocus,
        pid: target.pid,
        windowId: target.windowId,
        appId: target.appId,
        workspacePath: workspacePath,
      );
    } on MissingPluginException {
      _logger.warning('watch.native_start_failed', const <String, Object?>{
        'source': 'native_watch',
        'status': 'failed',
        'errorCode': 'watch_unsupported',
      });
      throw const WatchDriverException(
        errorCode: 'watch_unsupported',
        message: 'Native watch plugin is unavailable on this platform.',
      );
    } on XunaHostChannelException catch (error) {
      final mapped = _mapChannelException(error, forStart: true);
      _logger.warning('watch.native_start_failed', <String, Object?>{
        'source': 'native_watch',
        'status': 'failed',
        'errorCode': mapped,
      });
      throw WatchDriverException(errorCode: mapped, message: error.message);
    } catch (_) {
      _logger.warning('watch.native_start_failed', const <String, Object?>{
        'source': 'native_watch',
        'status': 'failed',
        'errorCode': 'watch_unsupported',
      });
      throw const WatchDriverException(
        errorCode: 'watch_unsupported',
        message: 'Unexpected failure starting native watch.',
      );
    }

    final subscription = _NativeWatchSubscription(
      watchId: watchId,
      signal: signal,
      channel: _channel,
      logger: _logger,
      pollInterval: pollInterval,
      eventDriven: startRes.eventDriven,
      fallbackUsed: startRes.fallbackUsed,
      onUpdate: onUpdate,
    );
    subscription.startPolling();

    _logger.info('watch.native_started', <String, Object?>{
      'source': 'native_watch',
      'status': 'started',
      'reason': signal.wire,
    });
    return subscription;
  }

  /// Resolves [workspaceAlias] strictly inside `$HOME`/`%USERPROFILE%` using
  /// exact case-insensitive alias matching (no fuzzy or `'recent'`/`'latest'`
  /// fallback, Rules H3/H5/U5).
  String resolveSafeWatchWorkspacePath(String workspaceAlias) {
    final trimmed = workspaceAlias.trim();
    if (trimmed.isEmpty || !isValidWorkspaceQuery(trimmed)) {
      throw const WatchDriverException(
        errorCode: 'workspace_not_found',
        message: 'Workspace alias is missing or invalid.',
      );
    }
    final clean = trimmed.toLowerCase();
    if (clean == 'recent' || clean == 'latest') {
      throw const WatchDriverException(
        errorCode: 'workspace_not_found',
        message: 'Ambiguous workspace alias is not permitted for watching.',
      );
    }
    if (clean.startsWith('.') ||
        _forbiddenWorkspaceSegments.contains(clean) ||
        clean.startsWith('.env')) {
      throw const WatchDriverException(
        errorCode: 'policy_blocked',
        message: 'Sensitive workspace alias is blocked by policy.',
      );
    }

    final homeRaw = (_homeDirectoryResolver() ?? '').trim();
    if (homeRaw.isEmpty || !Directory(homeRaw).existsSync()) {
      throw const WatchDriverException(
        errorCode: 'policy_blocked',
        message: 'Home directory is unavailable for workspace validation.',
      );
    }
    final canonicalHome = Directory(homeRaw).resolveSymbolicLinksSync();
    final sep = Platform.pathSeparator;
    final normHome = canonicalHome.endsWith(sep)
        ? canonicalHome.substring(0, canonicalHome.length - 1)
        : canonicalHome;

    var workspaces = _workspaceIndexer.discoverWorkspaces();
    var matches = workspaces
        .where((w) => w.alias.trim().toLowerCase() == clean)
        .toList(growable: false);
    if (matches.isEmpty) {
      workspaces = _workspaceIndexer.discoverWorkspaces(forceRefresh: true);
      matches = workspaces
          .where((w) => w.alias.trim().toLowerCase() == clean)
          .toList(growable: false);
    }
    if (matches.isEmpty) {
      throw const WatchDriverException(
        errorCode: 'workspace_not_found',
        message: 'Requested workspace alias was not found.',
      );
    }

    final distinctCanonical = <String>{};
    for (final ws in matches) {
      final entityType = FileSystemEntity.typeSync(ws.path, followLinks: true);
      if (entityType == FileSystemEntityType.notFound) {
        if (Link(ws.path).existsSync()) {
          throw const WatchDriverException(
            errorCode: 'policy_blocked',
            message: 'Broken workspace symlink is blocked by policy.',
          );
        }
        continue;
      }
      if (entityType != FileSystemEntityType.directory) {
        continue;
      }

      final canonicalTarget = Directory(ws.path).resolveSymbolicLinksSync();
      if (canonicalTarget == normHome ||
          !canonicalTarget.startsWith('$normHome$sep')) {
        throw const WatchDriverException(
          errorCode: 'policy_blocked',
          message: 'Workspace must reside strictly inside home directory.',
        );
      }

      final rel = canonicalTarget.substring(normHome.length + 1);
      final segments = rel
          .split(RegExp(r'[\\/]'))
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (segments.isEmpty) {
        throw const WatchDriverException(
          errorCode: 'policy_blocked',
          message: 'Workspace cannot be the home root directory.',
        );
      }
      for (var i = 0; i < segments.length; i++) {
        final seg = segments[i].toLowerCase();
        if (seg.startsWith('.') ||
            _forbiddenWorkspaceSegments.contains(seg) ||
            seg.startsWith('.env') ||
            seg.endsWith('.pem') ||
            seg.endsWith('.key') ||
            seg.endsWith('.p12') ||
            seg.endsWith('.kdbx')) {
          throw const WatchDriverException(
            errorCode: 'policy_blocked',
            message: 'Sensitive workspace path is blocked by policy.',
          );
        }
        if (seg == '.git' &&
            i + 1 < segments.length &&
            segments[i + 1].toLowerCase() == 'objects') {
          throw const WatchDriverException(
            errorCode: 'policy_blocked',
            message: 'Internal git object directory is blocked by policy.',
          );
        }
      }

      distinctCanonical.add(canonicalTarget);
    }

    if (distinctCanonical.isEmpty) {
      throw const WatchDriverException(
        errorCode: 'workspace_not_found',
        message: 'Workspace directory does not exist on disk.',
      );
    }
    if (distinctCanonical.length > 1) {
      throw const WatchDriverException(
        errorCode: 'workspace_not_found',
        message: 'Multiple distinct workspaces matched the alias.',
      );
    }
    return distinctCanonical.single;
  }

  static String _mapChannelException(
    XunaHostChannelException error, {
    required bool forStart,
  }) {
    final raw = error.errorCode.trim().toLowerCase();
    switch (raw) {
      case 'needs_permission':
      case 'permission_missing':
      case 'screen_recording':
        return 'needs_permission';
      case 'target_not_found':
      case 'target_lost':
        return forStart ? 'target_not_found' : 'target_lost';
      case 'workspace_not_found':
        return 'workspace_not_found';
      case 'policy_blocked':
      case 'hard_denied_window':
      case 'denylisted_target_forbidden':
        return 'policy_blocked';
      case 'watch_limit_reached':
        return 'watch_limit_reached';
      case 'invalid_args':
      case 'schema_mismatch':
        return 'invalid_args';
      case 'watch_unsupported':
      case 'platform_unsupported':
        return 'watch_unsupported';
      default:
        break;
    }

    switch (error.status) {
      case XtpStatus.needsPermission:
        return 'needs_permission';
      case XtpStatus.denied:
        return 'policy_blocked';
      case XtpStatus.invalidArgs:
        return 'invalid_args';
      case XtpStatus.unsupported:
        return 'watch_unsupported';
      case XtpStatus.timeout:
      case XtpStatus.failed:
      case XtpStatus.ok:
      case XtpStatus.cancelled:
        return forStart ? 'watch_unsupported' : 'os_error';
    }
  }
}

class _NativeWatchSubscription implements WatchSignalSubscription {
  _NativeWatchSubscription({
    required this.watchId,
    required this.signal,
    required XunaHostChannel channel,
    required ContentFreeLogger logger,
    required Duration pollInterval,
    required this.eventDriven,
    required this.fallbackUsed,
    required this.onUpdate,
  }) : _channel = channel,
       _logger = logger,
       _pollInterval = pollInterval;

  final String watchId;
  final WatchSignal signal;
  final XunaHostChannel _channel;
  final ContentFreeLogger _logger;
  final Duration _pollInterval;
  final void Function(WatchSignalUpdate update) onUpdate;

  @override
  final bool eventDriven;

  @override
  final bool fallbackUsed;

  Timer? _timer;
  bool _disposed = false;
  bool _pollInFlight = false;
  int _lastChangeCount = 0;
  int _lastDigestChangeCount = 0;
  bool _wasActive = false;

  void startPolling() {
    if (_disposed) return;
    _timer = Timer.periodic(_pollInterval, (_) {
      unawaited(_pollOnce());
    });
  }

  Future<void> _pollOnce() async {
    if (_disposed || _pollInFlight) return;
    _pollInFlight = true;
    try {
      final poll = await _channel.watchPoll(
        watchId: watchId,
        signal: signal.wire,
      );
      if (_disposed) return;

      if (poll.state == 'lost') {
        _stopTimer();
        onUpdate(
          WatchSignalUpdate(signal: signal, state: WatchSignalState.lost),
        );
        return;
      }

      if (poll.state == 'error') {
        _stopTimer();
        onUpdate(
          WatchSignalUpdate(
            signal: signal,
            state: WatchSignalState.error,
            errorCode: poll.errorCode ?? 'os_error',
          ),
        );
        return;
      }

      final hasNewChange = poll.changeCount > _lastChangeCount;
      if (poll.changeCount >= _lastChangeCount) {
        _lastChangeCount = poll.changeCount;
      }

      final hasNewDigestChange =
          poll.digestChanged || poll.digestChangeCount > _lastDigestChangeCount;
      if (poll.digestChangeCount >= _lastDigestChangeCount) {
        _lastDigestChangeCount = poll.digestChangeCount;
      }

      if (poll.state == 'active') {
        _wasActive = true;
        if (hasNewChange) {
          onUpdate(
            WatchSignalUpdate(
              signal: signal,
              state: WatchSignalState.changed,
              digestChanged: hasNewDigestChange,
            ),
          );
          if (_disposed) return;
        }
        onUpdate(
          WatchSignalUpdate(signal: signal, state: WatchSignalState.active),
        );
        return;
      }

      // 'idle' or 'changed'
      if (poll.state == 'changed' || hasNewChange || _wasActive) {
        _wasActive = false;
        onUpdate(
          WatchSignalUpdate(
            signal: signal,
            state: WatchSignalState.changed,
            digestChanged: hasNewDigestChange,
          ),
        );
      } else {
        onUpdate(
          WatchSignalUpdate(signal: signal, state: WatchSignalState.idle),
        );
      }
    } on MissingPluginException {
      if (_disposed) return;
      _stopTimer();
      onUpdate(
        WatchSignalUpdate(
          signal: signal,
          state: WatchSignalState.error,
          errorCode: 'watch_unsupported',
        ),
      );
    } on XunaHostChannelException catch (error) {
      if (_disposed) return;
      _stopTimer();
      final mapped = NativeWatchSignalDriver._mapChannelException(
        error,
        forStart: false,
      );
      if (mapped == 'target_lost') {
        onUpdate(
          WatchSignalUpdate(signal: signal, state: WatchSignalState.lost),
        );
      } else {
        onUpdate(
          WatchSignalUpdate(
            signal: signal,
            state: WatchSignalState.error,
            errorCode: mapped,
          ),
        );
      }
    } catch (_) {
      if (_disposed) return;
      _stopTimer();
      onUpdate(
        WatchSignalUpdate(
          signal: signal,
          state: WatchSignalState.error,
          errorCode: 'os_error',
        ),
      );
    } finally {
      _pollInFlight = false;
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopTimer();
    try {
      await _channel.watchStop(watchId: watchId, signal: signal.wire);
    } catch (_) {
      // Best-effort native stop during teardown.
    }
    _logger.info('watch.native_stopped', <String, Object?>{
      'source': 'native_watch',
      'status': 'stopped',
      'reason': signal.wire,
    });
  }
}
