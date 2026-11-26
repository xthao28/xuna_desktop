import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/presence/host_toolchain_prober.dart';
import 'package:xuna_desktop/features/presence/presence_models.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Builds a sanitized, path-free [ResourceDigest] for `xuna/resources` (`M3` Phase 2, P1.2 / U4).
///
/// Reuses [AutoAppScanner.discoverApps] (`app.id` only),
/// [AutoWorkspaceIndexer.discoverWorkspaces] (`AutoWorkspaceIndexer.sanitizeAlias`
/// only), and cached [HostToolchainProber.cachedToolchains] (`{id, version}`
/// only). Never reads or emits real filesystem paths.
class ResourceDigestBuilder {
  ResourceDigestBuilder({
    required this.appScanner,
    required this.workspaceIndexer,
    this.toolchainProber,
  });

  static const int maxInstalledApps = 256;
  static const int maxWorkspaces = 128;

  static final RegExp _workspaceAliasPattern = RegExp(
    r'^[a-zA-Z0-9_.-]{1,64}$',
  );

  final AutoAppScanner appScanner;
  final AutoWorkspaceIndexer workspaceIndexer;
  final HostToolchainProber? toolchainProber;

  ResourceDigest build({bool forceRefresh = false}) {
    final seenApps = <String>{};
    final apps = <String>[];
    for (final app in appScanner.discoverApps(forceRefresh: forceRefresh)) {
      final id = app.id;
      if (!isValidShortId(id) || isHardDeniedAppOrProcess(id)) {
        continue;
      }
      if (seenApps.add(id)) {
        apps.add(id);
      }
    }
    apps.sort();
    final cappedApps = apps.length > maxInstalledApps
        ? apps.sublist(0, maxInstalledApps)
        : apps;

    final seenWorkspaces = <String>{};
    final workspaces = <String>[];
    for (final ws in workspaceIndexer.discoverWorkspaces(
      forceRefresh: forceRefresh,
    )) {
      if (workspaces.length >= maxWorkspaces) break;
      final rawAlias = ws.alias;
      if (rawAlias.contains('/') ||
          rawAlias.contains(r'\') ||
          rawAlias == '.' ||
          rawAlias == '..' ||
          rawAlias.contains('..')) {
        continue;
      }
      final sanitized = AutoWorkspaceIndexer.sanitizeAlias(rawAlias);
      if (sanitized.contains('/') ||
          sanitized.contains(r'\') ||
          sanitized == '.' ||
          sanitized == '..' ||
          sanitized.contains('..') ||
          !_workspaceAliasPattern.hasMatch(sanitized)) {
        continue;
      }
      if (seenWorkspaces.add(sanitized)) {
        workspaces.add(sanitized);
      }
    }
    workspaces.sort();

    final rawToolchains =
        toolchainProber?.cachedToolchains ?? const <XtpToolchainEntry>[];
    final seenToolchains = <String>{};
    final toolchains = <XtpToolchainEntry>[];
    for (final candidate in rawToolchains) {
      final valid = XtpToolchainEntry.tryFromJson(<String, Object?>{
        'id': candidate.id,
        'version': candidate.version,
      });
      if (valid == null) continue;
      if (seenToolchains.add(valid.id)) {
        toolchains.add(valid);
      }
    }
    toolchains.sort((a, b) => a.id.compareTo(b.id));
    final cappedToolchains = toolchains.length > XtpToolchainEntry.maxToolchains
        ? toolchains.sublist(0, XtpToolchainEntry.maxToolchains)
        : toolchains;

    final canonicalMap = <String, Object?>{
      'apps': cappedApps,
      'workspaces': workspaces,
      if (cappedToolchains.isNotEmpty)
        'toolchains': cappedToolchains
            .map((entry) => entry.toJson())
            .toList(growable: false),
    };
    final canonical = jsonEncode(canonicalMap);
    final digestHex8 = sha256
        .convert(utf8.encode(canonical))
        .toString()
        .substring(0, 8);

    return ResourceDigest(
      installedApps: List<String>.unmodifiable(cappedApps),
      workspaces: List<String>.unmodifiable(workspaces),
      capabilitiesVersion: 'r1_$digestHex8',
      toolchains: List<XtpToolchainEntry>.unmodifiable(cappedToolchains),
    );
  }
}
