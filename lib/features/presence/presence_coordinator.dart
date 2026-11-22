import 'dart:async';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/presence/presence_models.dart';
import 'package:xuna_desktop/features/presence/resource_digest_builder.dart';
import 'package:xuna_desktop/features/presence/subnet_hash.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Coordinates `xuna/presence`, `xuna/resources`, and `xuna/focusRequest`
/// publishing for a live [XtpSessionClient] (`M3` Phase 2).
class PresenceCoordinator {
  PresenceCoordinator({
    required this.channel,
    required this.sessionClient,
    required this.resourceDigestBuilder,
    required this.subnetHashCalculator,
    required this.logger,
    DateTime Function()? clock,
    this.deltaPollInterval = const Duration(seconds: 5),
    this.periodicInterval = const Duration(seconds: 30),
    this.resourceDebounceDuration = const Duration(milliseconds: 500),
  }) : _clock = clock ?? DateTime.now {
    _phaseSub = sessionClient.phaseChanges.listen(_onSessionPhaseChanged);
    if (sessionClient.phase == HostSessionPhase.ready) {
      _onSessionPhaseChanged(HostSessionPhase.ready);
    }
  }

  final XunaHostChannel channel;
  final XtpSessionClient sessionClient;
  final ResourceDigestBuilder resourceDigestBuilder;
  final SubnetHashCalculator subnetHashCalculator;
  final ContentFreeLogger logger;
  final DateTime Function() _clock;
  final Duration deltaPollInterval;
  final Duration periodicInterval;
  final Duration resourceDebounceDuration;

  StreamSubscription<HostSessionPhase>? _phaseSub;
  Timer? _pollTimer;
  Timer? _resourceDebounceTimer;
  HostPresenceSnapshot? _lastEmittedPresence;
  DateTime? _lastPresenceSentAt;
  String? _lastCapabilitiesVersion;
  bool _probingInFlight = false;
  bool _disposed = false;

  void _onSessionPhaseChanged(HostSessionPhase phase) {
    if (_disposed) return;
    if (phase == HostSessionPhase.ready) {
      _lastEmittedPresence = null;
      _lastPresenceSentAt = null;
      _lastCapabilitiesVersion = null;
      unawaited(publishResources());
      unawaited(pollAndPublishPresence(forceEmit: true));
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(deltaPollInterval, (_) {
        unawaited(pollAndPublishPresence());
      });
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      _resourceDebounceTimer?.cancel();
      _resourceDebounceTimer = null;
    }
  }

  /// Probes the local host and emits `xuna/presence` when a state delta or
  /// periodic interval (>= [periodicInterval]) occurs, or when [forceEmit] is
  /// true. Fails closed on native probe errors without fabricating telemetry.
  Future<bool> pollAndPublishPresence({bool forceEmit = false}) async {
    if (_disposed || sessionClient.phase != HostSessionPhase.ready) {
      return false;
    }
    if (_probingInFlight) {
      return false;
    }
    _probingInFlight = true;
    try {
      final probe = await channel.presenceProbe();
      if (_disposed || sessionClient.phase != HostSessionPhase.ready) {
        return false;
      }
      final subnetHash = await subnetHashCalculator.compute();
      if (_disposed || sessionClient.phase != HostSessionPhase.ready) {
        return false;
      }
      final nowUtc = _clock().toUtc();
      final snapshot = HostPresenceSnapshot.fromProbe(
        probe,
        subnetHash: subnetHash,
        updatedAt: nowUtc,
      );

      final lastSent = _lastPresenceSentAt;
      final periodicDue =
          lastSent == null || nowUtc.difference(lastSent) >= periodicInterval;
      final shouldEmit =
          forceEmit ||
          periodicDue ||
          snapshot.hasPresenceDelta(_lastEmittedPresence);

      if (!shouldEmit) {
        return false;
      }

      final sent = sessionClient.sendPresence(snapshot.toPresenceParams());
      if (sent) {
        _lastEmittedPresence = snapshot;
        _lastPresenceSentAt = nowUtc;
      }
      return sent;
    } on XunaHostChannelException catch (error) {
      logger.warning('presence.probe_failed', <String, Object?>{
        'status': error.status.wire,
        'errorCode': error.errorCode,
      });
      return false;
    } catch (error) {
      logger.warning('presence.probe_error', <String, Object?>{
        'errorCode': error.runtimeType.toString(),
      });
      return false;
    } finally {
      _probingInFlight = false;
    }
  }

  /// Schedules a debounced `xuna/resources` publish if capabilities changed.
  void scheduleResourcesPublish({bool forceRefresh = false}) {
    if (_disposed || sessionClient.phase != HostSessionPhase.ready) {
      return;
    }
    _resourceDebounceTimer?.cancel();
    _resourceDebounceTimer = Timer(resourceDebounceDuration, () {
      unawaited(publishResources(forceRefresh: forceRefresh));
    });
  }

  /// Builds the normalized resource digest and emits `xuna/resources` if the
  /// session is ready and the capabilities digest changed.
  Future<bool> publishResources({bool forceRefresh = false}) async {
    if (_disposed || sessionClient.phase != HostSessionPhase.ready) {
      return false;
    }
    final digest = resourceDigestBuilder.build(forceRefresh: forceRefresh);
    if (_lastCapabilitiesVersion == digest.capabilitiesVersion) {
      return false;
    }
    final sent = sessionClient.sendResources(digest.toResourcesParams());
    if (sent) {
      _lastCapabilitiesVersion = digest.capabilitiesVersion;
    }
    return sent;
  }

  /// Emits `xuna/focusRequest` when the session is ready; returns `false`
  /// without faking success if the session is not connected/ready.
  bool requestFocus({required FocusRequestSource source, bool? followMe}) {
    if (_disposed) return false;
    final sent = sessionClient.sendFocusRequest(
      FocusRequestParams(source: source, followMe: followMe),
    );
    if (sent) {
      logger.info('mesh.focus_requested', <String, Object?>{
        'source': source.wire,
      });
    } else {
      logger.warning('mesh.focus_not_ready', <String, Object?>{
        'source': source.wire,
      });
    }
    return sent;
  }

  Future<void> dispose() async {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _resourceDebounceTimer?.cancel();
    _resourceDebounceTimer = null;
    await _phaseSub?.cancel();
    _phaseSub = null;
  }
}
