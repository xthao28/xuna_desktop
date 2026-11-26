import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Result of loading declarative capability manifests from disk directories.
class LoadedCapabilityManifests {
  const LoadedCapabilityManifests({
    required this.manifests,
    required this.rejectedCount,
  });

  final List<CapabilityManifest> manifests;
  final int rejectedCount;
}

/// Loads declarative JSON capability manifests from one or more directories
/// (`ADR-0021` §1 / Upgrade Plan P4.1).
///
/// Invalid, shell-bearing, untyped, unapproved, or tampered (`manifestSha256`
/// mismatch) manifests are rejected fail-closed without logging paths or
/// manifest contents (`desktop/AGENTS.md` §3.6).
class CapabilityManifestLoader {
  CapabilityManifestLoader({
    required List<Directory> manifestDirectories,
    ContentFreeLogger? logger,
  }) : _manifestDirectories = List<Directory>.unmodifiable(manifestDirectories),
       _logger = logger;

  static const int maxManifestBytes = 64 * 1024;
  static const int maxManifestFiles = 64;

  /// Resolves bundled read-only seed manifest directories next to the built
  /// executable (`data/flutter_assets/assets/capabilities` on Windows/Linux,
  /// `../Frameworks/App.framework/Resources/flutter_assets/assets/capabilities`
  /// on macOS) plus the source-tree fallback `<cwd>/assets/capabilities`.
  static List<Directory> bundledSeedDirectories({
    String? resolvedExecutableOverride,
    String? currentDirectoryOverride,
    bool? isMacOsOverride,
  }) {
    final sep = Platform.pathSeparator;
    final exePath = resolvedExecutableOverride ?? Platform.resolvedExecutable;
    final cwdPath = currentDirectoryOverride ?? Directory.current.path;
    final isMac = isMacOsOverride ?? Platform.isMacOS;
    final exeDir = File(exePath).parent.path;
    final relAssets = 'assets${sep}capabilities';
    final candidates = <String>[
      if (isMac)
        '$exeDir$sep..${sep}Frameworks${sep}App.framework${sep}Resources${sep}flutter_assets$sep$relAssets'
      else
        '$exeDir${sep}data${sep}flutter_assets$sep$relAssets',
      '$cwdPath$sep$relAssets',
    ];
    final seen = <String>{};
    final dirs = <Directory>[];
    for (final raw in candidates) {
      if (seen.add(raw)) {
        dirs.add(Directory(raw));
      }
    }
    return List<Directory>.unmodifiable(dirs);
  }

  final List<Directory> _manifestDirectories;
  final ContentFreeLogger? _logger;

  List<Directory> get directories => _manifestDirectories;

  /// Loads and strictly validates all `.json` manifests across configured
  /// directories. Later directories do not overwrite an already-loaded `id`.
  LoadedCapabilityManifests loadAll({bool includeUnapproved = false}) {
    final valid = <CapabilityManifest>[];
    final seenIds = <String>{};
    var rejected = 0;

    for (final dir in _manifestDirectories) {
      if (!dir.existsSync()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        if (valid.length >= maxManifestFiles) break;
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.json')) continue;
        try {
          if (entity.lengthSync() > maxManifestBytes) {
            rejected++;
            _logger?.warning('capability.manifest_rejected', <String, Object?>{
              'reason': 'too_large',
            });
            continue;
          }
          final raw = jsonDecode(entity.readAsStringSync());
          if (raw is! Map) {
            rejected++;
            continue;
          }
          final manifest = CapabilityManifest.fromJson(
            raw.map((k, v) => MapEntry<String, Object?>(k.toString(), v)),
          );
          if (!manifest.hasValidManifestPin) {
            rejected++;
            _logger?.warning('capability.manifest_rejected', <String, Object?>{
              'reason': 'manifest_sha256_mismatch',
            });
            continue;
          }
          if (!includeUnapproved && !manifest.provenance.approved) {
            rejected++;
            _logger?.warning('capability.manifest_rejected', <String, Object?>{
              'reason': 'not_approved',
            });
            continue;
          }
          if (!seenIds.add(manifest.id)) {
            rejected++;
            continue;
          }
          valid.add(manifest);
        } on Object {
          rejected++;
          _logger?.warning('capability.manifest_rejected', <String, Object?>{
            'reason': 'invalid_manifest',
          });
        }
      }
    }

    return LoadedCapabilityManifests(
      manifests: List<CapabilityManifest>.unmodifiable(valid),
      rejectedCount: rejected,
    );
  }
}
