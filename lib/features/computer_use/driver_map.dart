import 'package:xuna_xtp/xuna_xtp.dart';

/// Pinned Cua Driver evaluation and mapping constants (`UDC-8` S8.1 & §4.1).
///
/// Re-verified against `trycua/cua` (`libs/cua-driver/rust/Cargo.toml` and
/// `libs/cua-driver/contract/manifest.json`):
/// - License: `MIT` (core Rust driver `crates/cua-driver*`).
/// - AGPL-3.0 `cua-perception` (OmniParser) extension is strictly forbidden and
///   never installed, loaded, or enabled (`allowPerceptionExtension == false`).
class CuaDriverMap {
  const CuaDriverMap._();

  static const String pinnedDriverVersion = '0.38.0';
  static const String pinnedContractVersion = '0.8.0';
  static const String pinnedMcpProtocolVersion = '2026-07-28';
  static const String driverLicense = 'MIT';
  static const bool allowPerceptionExtension = false;
  static const String macOsHostBundleId = 'com.xuna.desktop';

  /// Maps a XUNA computer-use tool name (`UDC-8` §4.2) to the corresponding
  /// Cua Driver `0.38.0` MCP tool name.
  static String toCuaDriverTool({
    required String xunaToolName,
    Map<String, Object?> arguments = const <String, Object?>{},
  }) {
    switch (xunaToolName) {
      case 'cu.session_start':
        return 'start_session';
      case 'screen.capture':
        final scope = arguments['scope'] as String? ?? 'active_window';
        return scope == 'screen' ? 'get_desktop_state' : 'get_window_state';
      case 'ui.inspect':
        return 'get_window_state';
      case 'input.click':
        return 'click';
      case 'input.type_text':
        return 'type_text';
      case 'input.key':
        final combo = arguments['combo'] as String? ?? '';
        return combo.contains('+') || combo.startsWith('⌘')
            ? 'hotkey'
            : 'press_key';
      case 'input.scroll':
        return 'scroll';
      case 'cu.session_end':
        return 'end_session';
      default:
        throw ArgumentError.value(
          xunaToolName,
          'xunaToolName',
          'Unknown XUNA computer-use tool',
        );
    }
  }

  /// Translates XUNA tool arguments into Cua Driver `0.38.0` MCP `tools/call`
  /// arguments (`contract/manifest.json` v0.8.0).
  static Map<String, Object?> toCuaDriverArguments({
    required String xunaToolName,
    required String sessionId,
    required Map<String, Object?> arguments,
    int? targetPid,
    int? targetWindowId,
  }) {
    final windowTarget = <String, Object?>{
      'kind': 'window',
      if (targetPid != null) 'pid': targetPid,
      if (targetWindowId != null) 'window_id': targetWindowId,
    };

    switch (xunaToolName) {
      case 'cu.session_start':
        return <String, Object?>{'session': sessionId};
      case 'screen.capture':
        final scope = arguments['scope'] as String? ?? 'active_window';
        if (scope == 'screen') {
          return <String, Object?>{
            'session': sessionId,
            'max_edge': arguments['maxEdge'] ?? 1280,
          };
        }
        return <String, Object?>{
          'session': sessionId,
          if (targetPid != null) 'pid': targetPid,
          if (targetWindowId != null) 'window_id': targetWindowId,
          'include_accessibility_tree': false,
        };
      case 'ui.inspect':
        return <String, Object?>{
          'session': sessionId,
          if (targetPid != null) 'pid': targetPid,
          if (targetWindowId != null) 'window_id': targetWindowId,
          'max_elements': arguments['maxNodes'] ?? 300,
        };
      case 'input.click':
        final elementId = arguments['elementId'] as String?;
        final x = arguments['x'] as int?;
        final y = arguments['y'] as int?;
        return <String, Object?>{
          'session': sessionId,
          'target': windowTarget,
          'delivery_mode': elementId != null ? 'background' : 'foreground',
          if (elementId != null && elementId.isNotEmpty)
            'element_token': elementId,
          if (x != null) 'x': x,
          if (y != null) 'y': y,
        };
      case 'input.type_text':
        return <String, Object?>{
          'session': sessionId,
          'target': windowTarget,
          'element_token': arguments['elementId'],
          'text': arguments['text'],
        };
      case 'input.key':
        final combo = arguments['combo'] as String;
        if (combo.contains('+') || combo.startsWith('⌘')) {
          final normalizedCombo = combo.startsWith('⌘')
              ? <String>['Command', combo.substring(1)]
              : combo.split('+');
          return <String, Object?>{
            'session': sessionId,
            'target': windowTarget,
            'keys': normalizedCombo,
          };
        }
        return <String, Object?>{
          'session': sessionId,
          'target': windowTarget,
          'key': combo,
        };
      case 'input.scroll':
        return <String, Object?>{
          'session': sessionId,
          'target': windowTarget,
          if (arguments['elementId'] != null)
            'element_token': arguments['elementId'],
          'direction': arguments['direction'],
          'amount': arguments['amount'],
        };
      case 'cu.session_end':
        return <String, Object?>{'session': sessionId};
      default:
        throw ArgumentError.value(
          xunaToolName,
          'xunaToolName',
          'Unknown XUNA computer-use tool',
        );
    }
  }

  /// Tools allowed inside Cua Driver's `bounded` capability manifest v3.
  static const List<String> boundedAllowedDriverTools = <String>[
    'start_session',
    'end_session',
    'list_windows',
    'get_window_state',
    'get_desktop_state',
    'click',
    'type_text',
    'press_key',
    'hotkey',
    'scroll',
    'verify_state',
  ];

  /// Tools explicitly denied in Cua Driver's `bounded` capability manifest v3
  /// (including AGPL `parse_visual_regions`, clipboard access, and session
  /// escalation).
  static const List<String> boundedDeniedDriverTools = <String>[
    'parse_visual_regions',
    'clipboard_read',
    'clipboard_write',
    'escalate_session',
    'invoke_menu',
    'set_window_frame',
    'drag',
  ];

  /// Builds a Cua Driver Capability Manifest v3 YAML document (`UDC-8` S8.1 &
  /// `cua-driver-core/src/session_manifest.rs`).
  ///
  /// Note: Manifest v3 omits top-level `mode` and `ask.tools`, and requires
  /// both `expires_after` and `idle_timeout` in `bounded` mode.
  static String buildBoundedCapabilityManifestYaml({
    required List<AllowedAppConfig> allowedApps,
    required List<String> allowedDomains,
    required int maxMinutes,
  }) {
    final clampedMinutes = maxMinutes.clamp(1, 10);
    final idleMinutes = clampedMinutes < 5 ? clampedMinutes : 5;
    final buf = StringBuffer()
      ..writeln('version: 3')
      ..writeln('expires_after: ${clampedMinutes}m')
      ..writeln('idle_timeout: ${idleMinutes}m')
      ..writeln('resources:');

    if (allowedApps.isEmpty) {
      buf.writeln('  apps: []');
    } else {
      buf.writeln('  apps:');
      for (final app in allowedApps) {
        if (isHardDeniedAppOrProcess(app.id) ||
            isHardDeniedAppOrProcess(app.target)) {
          continue;
        }
        final escapedTarget = app.target.replaceAll("'", "''");
        if (app.kind == AppLaunchKind.exe) {
          buf
            ..writeln("    - executable: '$escapedTarget'")
            ..writeln('      launch: false')
            ..writeln('      windows: all')
            ..writeln('      terminate: deny');
        } else {
          buf
            ..writeln("    - bundle_id: '$escapedTarget'")
            ..writeln('      launch: false')
            ..writeln('      windows: all')
            ..writeln('      terminate: deny');
        }
      }
    }

    if (allowedDomains.isEmpty) {
      buf
        ..writeln('  browser:')
        ..writeln('    origins: []');
    } else {
      buf
        ..writeln('  browser:')
        ..writeln('    origins:');
      for (final domain in allowedDomains) {
        final ascii = normalizeDomainAllowlistEntry(domain);
        buf.writeln("      - 'https://$ascii'");
      }
    }

    buf
      ..writeln('allow:')
      ..writeln('  tools:');
    for (final tool in boundedAllowedDriverTools) {
      buf.writeln('    - $tool');
    }

    buf
      ..writeln('deny:')
      ..writeln('  tools:');
    for (final tool in boundedDeniedDriverTools) {
      buf.writeln('    - $tool');
    }

    return buf.toString();
  }

  /// CLI arguments to spawn `cua-driver` in `bounded` MCP stdio mode.
  static List<String> buildLaunchArgs({required String manifestFilePath}) =>
      <String>[
        'mcp',
        '--direct',
        '--permission-mode',
        'bounded',
        '--capability-manifest',
        manifestFilePath,
        '--approve-capability-manifest',
      ];

  /// Environment variables passed to the spawned `cua-driver` child process.
  static Map<String, String> buildLaunchEnvironment({
    required String manifestFilePath,
    required HostPlatform platform,
  }) => <String, String>{
    'CUA_DRIVER_PERMISSION_MODE': 'bounded',
    'CUA_DRIVER_CAPABILITY_MANIFEST_FILE': manifestFilePath,
    'CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED': '1',
    if (platform == HostPlatform.macos) ...<String, String>{
      'CUA_DRIVER_EMBEDDED': '1',
      'CUA_DRIVER_HOST_BUNDLE_ID': macOsHostBundleId,
    },
  };
}

