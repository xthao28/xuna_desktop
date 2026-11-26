import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Combined local host presence snapshot sent over `xuna/presence` (`M3` Phase 2).
class HostPresenceSnapshot {
  const HostPresenceSnapshot({
    required this.idleSeconds,
    required this.screenLocked,
    required this.mediaPlaying,
    this.batteryPercent,
    this.isCharging,
    this.subnetHash,
    this.foregroundAppId,
    required this.updatedAt,
  });

  factory HostPresenceSnapshot.fromProbe(
    HostPresenceProbeResult probe, {
    String? subnetHash,
    required DateTime updatedAt,
  }) => HostPresenceSnapshot(
    idleSeconds: probe.idleSeconds,
    screenLocked: probe.screenLocked,
    mediaPlaying: probe.mediaPlaying,
    batteryPercent: probe.batteryPercent,
    isCharging: probe.isCharging,
    subnetHash: subnetHash,
    foregroundAppId: probe.foregroundAppId,
    updatedAt: updatedAt.toUtc(),
  );

  final int idleSeconds;
  final bool screenLocked;
  final bool mediaPlaying;
  final int? batteryPercent;
  final bool? isCharging;
  final String? subnetHash;
  final String? foregroundAppId;
  final DateTime updatedAt;

  /// Returns `true` when any presence state other than [idleSeconds] or
  /// [updatedAt] changed since [previous], triggering an immediate delta push.
  bool hasPresenceDelta(HostPresenceSnapshot? previous) {
    if (previous == null) return true;
    return screenLocked != previous.screenLocked ||
        mediaPlaying != previous.mediaPlaying ||
        foregroundAppId != previous.foregroundAppId ||
        subnetHash != previous.subnetHash ||
        batteryPercent != previous.batteryPercent ||
        isCharging != previous.isCharging;
  }

  PresenceParams toPresenceParams() => PresenceParams(
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

/// Sanitized, path-free capability digest sent over `xuna/resources` (`M3` Phase 2, P1.2 / U4).
class ResourceDigest {
  const ResourceDigest({
    required this.installedApps,
    required this.workspaces,
    required this.capabilitiesVersion,
    this.toolchains = const <XtpToolchainEntry>[],
  });

  final List<String> installedApps;
  final List<String> workspaces;
  final String capabilitiesVersion;
  final List<XtpToolchainEntry> toolchains;

  ResourcesParams toResourcesParams() => ResourcesParams(
    installedApps: installedApps,
    workspaces: workspaces,
    capabilitiesVersion: capabilitiesVersion,
    toolchains: toolchains,
  );
}
