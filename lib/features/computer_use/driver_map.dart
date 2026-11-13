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
    final clampedMinutes = maxMinutes.clamp(1, maxCuSessionMinutes);
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

/// Pinned `vercel-labs/agent-desktop` Rust MCP stdio driver mapping
/// (`agent-desktop mcp`, Apache-2.0, MCP protocol `2026-07-28`).
///
/// Maps XUNA's 8 computer-use tools to `agent-desktop` leaf MCP tools:
/// - `cu.session_start` -> `desktop_session_start`
/// - `screen.capture` -> `desktop_screenshot`
/// - `ui.inspect` -> `desktop_snapshot`
/// - `input.click` -> `desktop_click` (ref) or `desktop_mouse_click` (coords)
/// - `input.type_text` -> `desktop_set_value` (headless semantic) or `desktop_type` (`headed == true`)
/// - `input.key` -> `desktop_press`
/// - `input.scroll` -> `desktop_scroll`
/// - `cu.session_end` -> `desktop_session_end`
class AgentDesktopDriverMap {
  const AgentDesktopDriverMap._();

  static const String pinnedMcpProtocolVersion = '2026-07-28';
  static const String driverLicense = 'Apache-2.0';

  /// CLI arguments to spawn `agent-desktop` in MCP stdio mode.
  static List<String> buildLaunchArgs() => const <String>['mcp'];

  /// Maps a XUNA computer-use tool name to the corresponding `agent-desktop mcp`
  /// tool name (`src/mcp/catalog.rs`).
  static String toAgentDesktopTool({
    required String xunaToolName,
    Map<String, Object?> arguments = const <String, Object?>{},
  }) {
    switch (xunaToolName) {
      case 'cu.session_start':
        return 'desktop_session_start';
      case 'screen.capture':
        return 'desktop_screenshot';
      case 'ui.inspect':
        return 'desktop_snapshot';
      case 'input.click':
        final elementId = arguments['elementId'] as String?;
        final hasRef = elementId != null && elementId.trim().isNotEmpty;
        return hasRef ? 'desktop_click' : 'desktop_mouse_click';
      case 'input.type_text':
        final headed = arguments['headed'] == true;
        return headed ? 'desktop_type' : 'desktop_set_value';
      case 'input.key':
        return 'desktop_press';
      case 'input.scroll':
        return 'desktop_scroll';
      case 'cu.session_end':
        return 'desktop_session_end';
      default:
        throw ArgumentError.value(
          xunaToolName,
          'xunaToolName',
          'Unknown XUNA computer-use tool',
        );
    }
  }

  /// Normalizes an element reference into `agent-desktop`'s `@s<id>:e<N>` or
  /// `@e<N>` ref format.
  static String normalizeRefId(String rawRef) {
    final trimmed = rawRef.trim();
    if (trimmed.isEmpty) return trimmed;
    final parsed = parseSnapshotElementRef(trimmed);
    if (parsed != null) {
      return '@${parsed.snapshotId}:e${parsed.elementNumber}';
    }
    if (trimmed.startsWith('@')) return trimmed;
    return '@$trimmed';
  }

  /// Normalizes XUNA's allowlisted key combos (`⌘S`, `Cmd+F`, `ArrowDown`)
  /// into `agent-desktop`'s `desktop_press` combo syntax (`cmd+s`, `down`).
  static String normalizeKeyCombo(String rawCombo) {
    final trimmed = rawCombo.trim();
    if (trimmed.startsWith('⌘')) {
      return 'cmd+${trimmed.substring(1).toLowerCase()}';
    }
    switch (trimmed) {
      case 'Enter':
        return 'enter';
      case 'Tab':
        return 'tab';
      case 'Esc':
        return 'escape';
      case 'ArrowUp':
        return 'up';
      case 'ArrowDown':
        return 'down';
      case 'ArrowLeft':
        return 'left';
      case 'ArrowRight':
        return 'right';
      case 'PageUp':
        return 'pageup';
      case 'PageDown':
        return 'pagedown';
      default:
        return trimmed.toLowerCase();
    }
  }

  /// Translates XUNA tool arguments into `agent-desktop mcp` `tools/call`
  /// arguments (`src/mcp/catalog.rs` & `src/mcp/call.rs`).
  static Map<String, Object?> toAgentDesktopArguments({
    required String xunaToolName,
    required String sessionId,
    required Map<String, Object?> arguments,
    String? targetApp,
    int? targetWindowId,
  }) {
    switch (xunaToolName) {
      case 'cu.session_start':
        return <String, Object?>{'name': sessionId};
      case 'screen.capture':
        return <String, Object?>{
          if (targetApp != null && targetApp.isNotEmpty) 'app': targetApp,
          if (targetWindowId != null) 'window_id': '$targetWindowId',
          'format': 'jpeg',
        };
      case 'ui.inspect':
        final rootElementId = arguments['rootElementId'] as String?;
        return <String, Object?>{
          if (targetApp != null && targetApp.isNotEmpty) 'app': targetApp,
          if (targetWindowId != null) 'window_id': '$targetWindowId',
          'compact': true,
          if (arguments['interactiveOnly'] == true) 'interactive_only': true,
          if (arguments['skeleton'] == true) 'skeleton': true,
          if (rootElementId != null && rootElementId.trim().isNotEmpty)
            'root': normalizeRefId(rootElementId),
        };
      case 'input.click':
        final elementId = arguments['elementId'] as String?;
        if (elementId != null && elementId.trim().isNotEmpty) {
          return <String, Object?>{'ref_id': normalizeRefId(elementId)};
        }
        final x = arguments['x'] as int? ?? 0;
        final y = arguments['y'] as int? ?? 0;
        return <String, Object?>{'coords': '$x,$y'};
      case 'input.type_text':
        final refId = normalizeRefId(arguments['elementId'] as String);
        final text = arguments['text'] as String;
        final headed = arguments['headed'] == true;
        return headed
            ? <String, Object?>{'ref_id': refId, 'text': text}
            : <String, Object?>{'ref_id': refId, 'value': text};
      case 'input.key':
        final combo = normalizeKeyCombo(arguments['combo'] as String);
        return <String, Object?>{'combo': combo};
      case 'input.scroll':
        final elementId = arguments['elementId'] as String?;
        return <String, Object?>{
          if (elementId != null && elementId.trim().isNotEmpty)
            'ref_id': normalizeRefId(elementId),
          'direction': arguments['direction'],
          'amount': arguments['amount'],
        };
      case 'cu.session_end':
        return <String, Object?>{'id': sessionId};
      default:
        throw ArgumentError.value(
          xunaToolName,
          'xunaToolName',
          'Unknown XUNA computer-use tool',
        );
    }
  }

  /// Maps an `agent-desktop` error code (`STALE_REF`, `AMBIGUOUS_TARGET`,
  /// `ELEMENT_NOT_FOUND`, `ACTION_NOT_SUPPORTED`, `PERM_DENIED`, `TIMEOUT`)
  /// into XUNA's canonical `(XtpStatus, errorCode)` pair.
  static ({XtpStatus status, String errorCode}) mapErrorCode(String? rawCode) {
    switch ((rawCode ?? '').trim().toUpperCase()) {
      case 'STALE_REF':
        return (status: XtpStatus.failed, errorCode: 'stale_ref');
      case 'AMBIGUOUS_TARGET':
        return (status: XtpStatus.failed, errorCode: 'ambiguous_target');
      case 'ELEMENT_NOT_FOUND':
      case 'WINDOW_NOT_FOUND':
      case 'APP_NOT_FOUND':
        return (status: XtpStatus.failed, errorCode: 'element_not_found');
      case 'ACTION_NOT_SUPPORTED':
      case 'PLATFORM_NOT_SUPPORTED':
        return (
          status: XtpStatus.unsupported,
          errorCode: 'platform_unsupported',
        );
      case 'PERM_DENIED':
        return (status: XtpStatus.denied, errorCode: 'permission_missing');
      case 'TIMEOUT':
        return (status: XtpStatus.failed, errorCode: 'wait_timeout');
      case 'INVALID_ARGS':
        return (status: XtpStatus.invalidArgs, errorCode: 'schema_mismatch');
      default:
        return (status: XtpStatus.failed, errorCode: 'cu_driver_error');
    }
  }
}
