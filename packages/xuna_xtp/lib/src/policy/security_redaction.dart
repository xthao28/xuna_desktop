import 'dart:convert';

import '../schemas.dart';

/// Consequential UI element lexicon (`UDC-8` §4.2) in Vietnamese and English.
/// Clicking an element whose name matches any token here escalates `input.click`
/// from `R2` to `R3` (requiring a phone-signed single-use approval).
const List<String> consequentialElementKeywords = <String>[
  'send',
  'submit',
  'delete',
  'remove',
  'erase',
  'buy',
  'pay',
  'checkout',
  'check out',
  'purchase',
  'post',
  'publish',
  'transfer',
  'wire',
  'confirm payment',
  'place order',
  'gửi',
  'nộp',
  'xóa',
  'xoá',
  'gỡ bỏ',
  'hủy',
  'hủy bỏ',
  'hủy tài khoản',
  'mua',
  'thanh toán',
  'chuyển khoản',
  'đặt hàng',
  'đăng',
  'xuất bản',
];

final RegExp _wordSplitRe = RegExp(
  r'[^a-z0-9àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]+',
);

/// Returns `true` when [elementName] matches the consequential action lexicon
/// (`send`, `submit`, `delete`, `buy`, `pay`, `post` in Vietnamese or English).
bool isConsequentialElementName(String? elementName) {
  if (elementName == null || elementName.trim().isEmpty) return false;
  final decomposed = elementName.replaceAllMapped(
    RegExp(r'([a-z])([A-Z])'),
    (m) => '${m[1]} ${m[2]}',
  );
  final normalized = decomposed.trim().toLowerCase();
  final words =
      normalized.split(_wordSplitRe).where((w) => w.isNotEmpty).toSet();
  if (words.contains('checkout') ||
      normalized.replaceAll(' ', '').contains('checkout') ||
      normalized.replaceAll(RegExp(r'[\s_\-]+'), '').contains('checkout')) {
    return true;
  }
  for (final keyword in consequentialElementKeywords) {
    if (keyword.contains(' ')) {
      if (normalized.contains(keyword)) return true;
    } else if (words.contains(keyword)) {
      return true;
    }
  }
  return false;
}

/// High-impact UI element lexicon for `TrustPreset.autopilot` (ADR-0015
/// Autopilot amendment 2026-11-22): financial/payment, destructive/account,
/// and external outbound send/publish actions ALWAYS stay `R3` phone-signed.
/// Normal UI/IDE controls (`submit`, bare `confirm`, `remove`, `cancel`/`hủy`,
/// `order`) are intentionally excluded so Autopilot can work uninterrupted.
const List<String> highImpactElementKeywords = <String>[
  // External outbound send & public publish
  'send',
  'post',
  'publish',
  'gửi',
  'xuất bản',
  // Destructive & account/system impact
  'delete',
  'erase',
  'empty trash',
  'format',
  'uninstall',
  'sign out',
  'log out',
  'logout',
  'xóa',
  'xoá',
  'gỡ cài đặt',
  'hủy tài khoản',
  'xóa tài khoản',
  'xoá tài khoản',
  'dọn sạch thùng rác',
  'đăng xuất',
  // Financial / payment / purchase / transfer
  'buy',
  'pay',
  'payment',
  'checkout',
  'check out',
  'purchase',
  'transfer',
  'wire',
  'confirm payment',
  'place order',
  'mua',
  'mua ngay',
  'thanh toán',
  'chuyển khoản',
  'đặt hàng',
];

const Set<String> _nonPublishDangFollowers = <String>{
  'nhập',
  'nhap',
  'ký',
  'ky',
};

/// Returns `true` when [elementName] represents a high-impact action that must
/// stay `R3` phone-signed even under `TrustPreset.autopilot`: financial,
/// destructive/account/system, or external send/publish actions.
bool isHighImpactElementName(String? elementName) {
  if (elementName == null || elementName.trim().isEmpty) return false;
  final decomposed = elementName.replaceAllMapped(
    RegExp(r'([a-z])([A-Z])'),
    (m) => '${m[1]} ${m[2]}',
  );
  final normalized = decomposed.trim().toLowerCase();
  final wordList =
      normalized.split(_wordSplitRe).where((w) => w.isNotEmpty).toList();
  final words = wordList.toSet();
  if (words.contains('checkout') ||
      normalized.replaceAll(' ', '').contains('checkout') ||
      normalized.replaceAll(RegExp(r'[\s_\-]+'), '').contains('checkout')) {
    return true;
  }
  for (var i = 0; i < wordList.length; i++) {
    if (wordList[i] == 'đăng') {
      final next = i + 1 < wordList.length ? wordList[i + 1] : null;
      if (next == null || !_nonPublishDangFollowers.contains(next)) {
        return true;
      }
    }
  }
  for (final keyword in highImpactElementKeywords) {
    if (keyword.contains(' ')) {
      if (normalized.contains(keyword)) return true;
    } else if (words.contains(keyword)) {
      return true;
    }
  }
  return false;
}

/// Checks whether a browser interaction is high-impact under
/// `TrustPreset.autopilot` (financial/payment, credentials/cards, destructive,
/// or external send/publish). Excludes bare `submit`/`confirm`/`xac nhan`.
bool isHighImpactBrowserTarget({
  required String ref,
  String? selector,
  String? targetText,
  String? value,
}) {
  if (isHighImpactElementName(ref)) return true;
  if (selector != null && isHighImpactElementName(selector)) return true;
  if (targetText != null && isHighImpactElementName(targetText)) return true;
  if (value != null && isHighImpactElementName(value)) return true;

  final rawCombined =
      '$ref ${selector ?? ''} ${targetText ?? ''} ${value ?? ''}';
  final decomposed = rawCombined
      .replaceAllMapped(
        RegExp(r'([a-z])([A-Z])'),
        (m) => '${m[1]} ${m[2]}',
      )
      .toLowerCase();
  final words =
      decomposed.split(_wordSplitRe).where((w) => w.isNotEmpty).toSet();

  if (words.contains('pin') ||
      words.contains('card') ||
      words.contains('credit') ||
      words.contains('token') ||
      words.contains('secret') ||
      words.contains('thẻ') ||
      words.contains('transfer') ||
      words.contains('payment') ||
      words.contains('checkout') ||
      words.contains('wire') ||
      decomposed.replaceAll(RegExp(r'[\s_\-]+'), '').contains('checkout') ||
      decomposed.contains('check out')) {
    return true;
  }

  if (decomposed.contains('password') ||
      decomposed.contains('passwd') ||
      decomposed.contains('cvv') ||
      decomposed.contains('cvc') ||
      decomposed.contains('mật khẩu') ||
      decomposed.contains('mat khau') ||
      decomposed.contains('chuyen khoan') ||
      decomposed.contains('thanh toan') ||
      decomposed.contains('dat hang') ||
      decomposed.contains('mua ngay') ||
      decomposed.contains('the tin dung') ||
      decomposed.contains('the visa') ||
      decomposed.contains('the mastercard') ||
      decomposed.contains('the atm') ||
      decomposed.contains('the ngan hang')) {
    return true;
  }
  return false;
}

/// Checks whether a browser interaction is consequential and requires elevation to R3 (`UDC-18` §Wave B).
bool isConsequentialBrowserTarget({
  required String ref,
  String? selector,
  String? targetText,
  String? value,
}) {
  if (isConsequentialElementName(ref)) return true;
  if (selector != null && isConsequentialElementName(selector)) return true;
  if (targetText != null && isConsequentialElementName(targetText)) return true;
  if (value != null && isConsequentialElementName(value)) return true;

  final rawCombined =
      '$ref ${selector ?? ''} ${targetText ?? ''} ${value ?? ''}';
  final decomposed = rawCombined
      .replaceAllMapped(
        RegExp(r'([a-z])([A-Z])'),
        (m) => '${m[1]} ${m[2]}',
      )
      .toLowerCase();
  final words =
      decomposed.split(_wordSplitRe).where((w) => w.isNotEmpty).toSet();

  // Word-boundary sensitive matches (prevent false positives like spin, opinion, wildcard, cardigan)
  if (words.contains('pin') ||
      words.contains('card') ||
      words.contains('credit') ||
      words.contains('token') ||
      words.contains('secret') ||
      words.contains('thẻ') ||
      words.contains('transfer') ||
      words.contains('payment') ||
      words.contains('checkout') ||
      words.contains('wire') ||
      decomposed.replaceAll(RegExp(r'[\s_\-]+'), '').contains('checkout') ||
      decomposed.contains('check out')) {
    return true;
  }

  // Multi-word or specific banking / credential substring matches
  if (decomposed.contains('password') ||
      decomposed.contains('passwd') ||
      decomposed.contains('cvv') ||
      decomposed.contains('cvc') ||
      decomposed.contains('mật khẩu') ||
      decomposed.contains('mat khau') ||
      decomposed.contains('chuyen khoan') ||
      decomposed.contains('thanh toan') ||
      decomposed.contains('dat hang') ||
      decomposed.contains('mua ngay') ||
      decomposed.contains('xac nhan') ||
      decomposed.contains('the tin dung') ||
      decomposed.contains('the visa') ||
      decomposed.contains('the mastercard') ||
      decomposed.contains('the atm') ||
      decomposed.contains('the ngan hang')) {
    return true;
  }
  return false;
}

/// Built-in hard-refusal denylist for computer use (`UDC-8` §4.2):
/// terminals, password managers, banking apps, and system/security settings
/// are refused regardless of the session allowlist.
const Set<String> hardDeniedAppsAndProcesses = <String>{
  // Terminals
  'cmd',
  'cmd.exe',
  'powershell',
  'powershell.exe',
  'pwsh',
  'pwsh.exe',
  'wt',
  'wt.exe',
  'windowsterminal',
  'windowsterminal.exe',
  'terminal',
  'terminal.app',
  'com.apple.terminal',
  'iterm',
  'iterm2',
  'iterm.app',
  'com.googlecode.iterm2',
  'bash',
  'bash.exe',
  'zsh',
  'wsl',
  'wsl.exe',
  'conhost',
  'conhost.exe',
  'warp',
  'dev.warp.warp-stable',
  'alacritty',
  'org.alacritty',
  'kitty',
  'net.kovidgoyal.kitty',
  'wezterm',
  'wezterm-gui',
  'wezterm-gui.exe',
  'com.github.wez.wezterm',
  'ghostty',
  'com.mitchellh.ghostty',
  'hyper',
  'co.zeit.hyper',
  // Password managers & credential stores
  '1password',
  '1password.exe',
  'com.1password.1password',
  'bitwarden',
  'bitwarden.exe',
  'com.bitwarden.desktop',
  'keepass',
  'keepass.exe',
  'keepassxc',
  'keepassxc.exe',
  'org.keepassxc.keepassxc',
  'lastpass',
  'dashlane',
  'keychain',
  'keychain access',
  'com.apple.keychainaccess',
  // System & security settings
  'systemsettings',
  'systemsettings.exe',
  'system_settings',
  'com.apple.systemsettings',
  'control',
  'control.exe',
  'regedit',
  'regedit.exe',
  'mmc',
  'mmc.exe',
  'taskmgr',
  'taskmgr.exe',
  'secpol',
  'secpol.msc',
  'gpedit',
  'gpedit.msc',
  'system settings',
  'system preferences',
  'com.apple.systempreferences',
  'com.apple.settings',
  // Banking / financial keywords
  'banking',
  'vietcombank',
  'techcombank',
  'mbbank',
  'tpbank',
  'vpbank',
  'bidv',
  'agribank',
  'acb',
  'momo',
  'zalopay',
  'vnpay',
};

String _stripDelimiters(String s) => s.replaceAll(RegExp(r'[-_\s]'), '');

final Set<String> _normalizedHardDeniedAppsAndProcesses =
    hardDeniedAppsAndProcesses.map(_stripDelimiters).toSet();

/// Returns `true` if [appIdOrProcess] is on XUNA's hard-refusal denylist
/// (terminals, password managers, banking apps, or system security panes).
bool isHardDeniedAppOrProcess(String? appIdOrProcess) {
  if (appIdOrProcess == null || appIdOrProcess.trim().isEmpty) return true;
  final raw = appIdOrProcess.trim().toLowerCase();
  final trimmedPath = raw.replaceAll(RegExp(r'[/\\]+$'), '');
  if (trimmedPath.isEmpty) return true;
  final baseName = trimmedPath.split(RegExp(r'[/\\]')).last;
  if (hardDeniedAppsAndProcesses.contains(raw) ||
      hardDeniedAppsAndProcesses.contains(trimmedPath) ||
      hardDeniedAppsAndProcesses.contains(baseName)) {
    return true;
  }
  final withoutExt = baseName.endsWith('.exe')
      ? baseName.substring(0, baseName.length - 4)
      : (baseName.endsWith('.app')
          ? baseName.substring(0, baseName.length - 4)
          : baseName);
  if (hardDeniedAppsAndProcesses.contains(withoutExt)) {
    return true;
  }

  // Normalize delimiters (e.g. system_settings or system-settings -> systemsettings)
  final strippedRaw = _stripDelimiters(raw);
  final strippedTrimmed = _stripDelimiters(trimmedPath);
  final strippedBase = _stripDelimiters(baseName);
  final strippedWithoutExt = _stripDelimiters(withoutExt);

  if (hardDeniedAppsAndProcesses.contains(strippedRaw) ||
      hardDeniedAppsAndProcesses.contains(strippedTrimmed) ||
      hardDeniedAppsAndProcesses.contains(strippedBase) ||
      hardDeniedAppsAndProcesses.contains(strippedWithoutExt)) {
    return true;
  }

  if (_normalizedHardDeniedAppsAndProcesses.contains(strippedRaw) ||
      _normalizedHardDeniedAppsAndProcesses.contains(strippedTrimmed) ||
      _normalizedHardDeniedAppsAndProcesses.contains(strippedBase) ||
      _normalizedHardDeniedAppsAndProcesses.contains(strippedWithoutExt)) {
    return true;
  }

  return false;
}

/// Returns `true` if a UI node represents a password field (`UDC-8` §4.2).
bool isPasswordUiNode(Map<String, Object?> node) {
  if (node['isPassword'] == true ||
      node['password'] == true ||
      node['secure'] == true) {
    return true;
  }
  final role = (node['role'] as String?)?.toLowerCase() ?? '';
  if (role.contains('password') ||
      role.contains('securetext') ||
      role == 'axsecuretextfield') {
    return true;
  }
  // macOS marks secure fields by subrole (`AXTextField` + `AXSecureTextField`);
  // web inputs by type. Same rules as the backend's `is_password_ui_node`.
  final subrole = (node['subrole'] as String?)?.toLowerCase() ?? '';
  final inputType = (node['inputType'] as String?)?.toLowerCase() ?? '';
  if (subrole.contains('secure') ||
      subrole.contains('password') ||
      inputType.contains('password')) {
    return true;
  }
  // The name is a weak signal: it decides only for an editable field, or for a
  // node whose role is unknown (fail closed). A "Quên mật khẩu" button or link
  // is not a password field (UDC-17 S17.6).
  if (role.isNotEmpty && !isEditableFieldRole(role)) return false;
  final name = (node['name'] as String?)?.toLowerCase() ?? '';
  return name.contains('password') ||
      name.contains('mật khẩu') ||
      name.contains('passcode') ||
      name.contains('mã pin');
}

/// Role fragments of editable text inputs across UIA, AX and web trees
/// (`Edit`, `AXTextField`, `AXTextArea`, `textbox`, `searchbox`, `combobox`).
/// Static text (`Text`, `AXStaticText`) is not editable.
const List<String> _editableFieldRoleHints = <String>[
  'edit',
  'field',
  'input',
  'textbox',
  'textarea',
  'searchbox',
  'combobox',
];

/// Whether a lower-case [role] names an editable text input.
bool isEditableFieldRole(String role) =>
    _editableFieldRoleHints.any(role.contains);

/// Roles treated as transparent web/Electron layout wrappers when unnamed and
/// non-actionable (`agent-desktop` web-wrapper skipping).
const Set<String> transparentWebWrapperRoles = <String>{
  'group',
  'custom',
  'pane',
  'generic',
  'div',
  'section',
  'layout_item',
  'axgroup',
};

/// Returns `true` when [node] is an unnamed, non-actionable layout wrapper
/// (`group`/`custom`/`pane`/`div`) that adds DOM bloat in Electron/WebView2
/// trees without carrying semantic identity or direct actionability.
bool isTransparentWebWrapperNode(Map<String, Object?> node) {
  if (isPasswordUiNode(node)) return false;
  if (node['actionable'] == true || node['interactive'] == true) return false;
  final role = ((node['role'] as String?) ?? '').trim().toLowerCase();
  if (!transparentWebWrapperRoles.contains(role)) return false;
  final name = ((node['name'] as String?) ?? '').trim();
  final value = ((node['value'] as String?) ?? '').trim();
  return name.isEmpty && value.isEmpty;
}

/// Roles treated as modal/overlay surfaces (`dialog`, `sheet`, `alert`,
/// `popover`, `menu`) that can occlude underlying window controls.
const Set<String> overlaySurfaceRoles = <String>{
  'dialog',
  'alert',
  'alertdialog',
  'sheet',
  'menu',
  'popover',
  'modal',
};

/// Returns `true` when [node] represents an open overlay surface (modal dialog,
/// sheet, alert, popover, or menu).
bool isOverlaySurfaceNode(Map<String, Object?> node) {
  final role = ((node['role'] as String?) ?? '').trim().toLowerCase();
  final surface = ((node['surface'] as String?) ?? '').trim().toLowerCase();
  return overlaySurfaceRoles.contains(role) ||
      overlaySurfaceRoles.contains(surface) ||
      node['modal'] == true;
}

/// Roles treated as interactive controls when `interactiveOnly == true`.
const Set<String> interactiveUiRoles = <String>{
  'button',
  'axbutton',
  'textfield',
  'axtextfield',
  'edit',
  'searchbox',
  'searchfield',
  'axsearchfield',
  'textarea',
  'axtextarea',
  'document',
  'password',
  'password_edit',
  'axsecuretextfield',
  'checkbox',
  'axcheckbox',
  'radio',
  'radiobutton',
  'axradiobutton',
  'combobox',
  'axcombobox',
  'menuitem',
  'menu_item',
  'axmenuitem',
  'list_item',
  'listitem',
  'axrow',
  'link',
  'axlink',
  'tab',
  'tabitem',
  'slider',
  'switch',
  'toggle',
  'treeitem',
};

/// Returns `true` when [node] is an interactive control or explicitly marked
/// `actionable`/`interactive`.
bool isInteractiveUiNode(Map<String, Object?> node) {
  if (isPasswordUiNode(node)) return true;
  if (node['actionable'] == true || node['interactive'] == true) return true;
  final role = ((node['role'] as String?) ?? '').trim().toLowerCase();
  return interactiveUiRoles.contains(role);
}

/// Truncates [value] to at most [maxCodeUnits] UTF-16 code units without
/// splitting a surrogate pair.
String clampUtf16Safe(String value, int maxCodeUnits) {
  if (value.length <= maxCodeUnits) return value;
  final out = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    if (out.length + char.length > maxCodeUnits) break;
    out.write(char);
  }
  return out.toString();
}

/// Extracts a list of active overlay surfaces (`dialog`, `alert`, `sheet`,
/// `popover`, `menu`) from [nodes] so the agent knows if a modal blocks the
/// main window (`agent-desktop` surface detection).
List<Map<String, Object?>> extractOverlaySurfaces(
  List<Map<String, Object?>> nodes,
) {
  final surfaces = <Map<String, Object?>>[];
  for (final node in nodes) {
    if (!isOverlaySurfaceNode(node)) continue;
    final id = (node['id'] as String?) ?? '';
    final role =
        ((node['surface'] as String?) ?? (node['role'] as String?) ?? 'dialog')
            .toLowerCase();
    final name = (node['name'] as String?) ?? '';
    surfaces.add(<String, Object?>{
      'id': id,
      'kind': role,
      'title': clampUtf16Safe(name, 80),
      'modal': node['modal'] != false,
    });
  }
  return surfaces;
}

final RegExp _snapshotRefRe =
    RegExp(r'^@?(s[a-z0-9]{4,16}):(?:e)?([0-9]{1,6})$');

/// Formats a snapshot-qualified element reference (`@s<snapshotId>:e<index>`)
/// inspired by `agent-desktop` so stale refs from earlier observations can be
/// deterministically detected.
String qualifySnapshotElementRef({
  required String snapshotId,
  required String rawId,
  required int index1Based,
}) {
  final cleanSnap =
      snapshotId.startsWith('@') ? snapshotId.substring(1) : snapshotId;
  final parsed = parseSnapshotElementRef(rawId);
  if (parsed != null) {
    return '@$cleanSnap:e${parsed.elementNumber}';
  }
  return '@$cleanSnap:e$index1Based';
}

/// Parses either `@s00000001:e1` or `s00000001:1` into its `(snapshotId, elementNumber)`
/// components, or returns `null` if [ref] is not snapshot-qualified.
({String snapshotId, int elementNumber})? parseSnapshotElementRef(String? ref) {
  if (ref == null || ref.trim().isEmpty) return null;
  final match = _snapshotRefRe.firstMatch(ref.trim());
  if (match == null) return null;
  final numPart = int.tryParse(match.group(2)!);
  if (numPart == null) return null;
  return (snapshotId: match.group(1)!, elementNumber: numPart);
}

List<double>? _sanitizeBoundsList(Object? rawBounds) {
  if (rawBounds is! List || rawBounds.length != 4) return null;
  final sanitized = <double>[];
  for (final item in rawBounds) {
    if (item is! num || !item.isFinite) return null;
    sanitized.add(item.toDouble());
  }
  return sanitized;
}

Map<String, double>? _sanitizeBoundsMap(Object? rawBounds) {
  if (rawBounds is! Map || rawBounds.isEmpty) return null;
  final sanitized = <String, double>{};
  for (final entry in rawBounds.entries) {
    final key = entry.key;
    final val = entry.value;
    if (key is! String || val is! num || !val.isFinite) {
      return null;
    }
    sanitized[key] = val.toDouble();
  }
  return sanitized;
}

/// Redacts password fields in a list of UI tree nodes (`UDC-8` §4.2):
/// replaces `name` with `'•••'` and removes `value`.
///
/// Supports progressive observation upgrades inspired by `agent-desktop`:
/// - [collapseWebWrappers]: skips unnamed, non-actionable `group`/`custom`/`pane`
///   wrappers while preserving interactive descendants.
/// - [skeleton]: caps depth to shallow container overview (`depth <= 2`) and
///   annotates `childrenCount` for drill-down via [rootElementId].
/// - [interactiveOnly]: retains only interactive controls and overlay surfaces.
/// - [rootElementId]: scopes observation to the subtree under [rootElementId].
/// - [snapshotId]: attaches snapshot-qualified `@s<id>:e<N>` `ref` tags.
List<Map<String, Object?>> redactUiTreeNodes(
  List<Map<String, Object?>> nodes, {
  int maxNodes = 300,
  String? snapshotId,
  bool collapseWebWrappers = false,
  bool skeleton = false,
  bool interactiveOnly = false,
  String? rootElementId,
}) {
  final out = <Map<String, Object?>>[];
  final cleanRoot = rootElementId?.trim();
  final filterByRoot = cleanRoot != null && cleanRoot.isNotEmpty;

  // Collect descendant IDs when scoping to `rootElementId`.
  final allowedSubtreeIds = <String>{};
  if (filterByRoot) {
    allowedSubtreeIds.add(cleanRoot);
    for (final node in nodes) {
      final id = (node['id'] as String?) ?? '';
      final ref = (node['ref'] as String?) ?? '';
      final parentId = (node['parentId'] as String?) ?? '';
      if (id == cleanRoot || ref == cleanRoot) {
        if (id.isNotEmpty) allowedSubtreeIds.add(id);
      } else if (parentId.isNotEmpty && allowedSubtreeIds.contains(parentId)) {
        if (id.isNotEmpty) allowedSubtreeIds.add(id);
      }
    }
  }

  var elementIndex = 0;
  final usedIndices = <int>{};
  for (final node in nodes) {
    if (out.length >= maxNodes) break;
    final rawId = (node['id'] as String?) ?? '';
    final rawRef = (node['ref'] as String?) ?? '';
    final rawParentId = (node['parentId'] as String?) ?? '';
    if (filterByRoot &&
        !(rawId.isNotEmpty && allowedSubtreeIds.contains(rawId)) &&
        rawRef != cleanRoot &&
        !(rawParentId.isNotEmpty && allowedSubtreeIds.contains(rawParentId))) {
      continue;
    }
    if (collapseWebWrappers && isTransparentWebWrapperNode(node)) {
      continue;
    }
    if (interactiveOnly &&
        !isInteractiveUiNode(node) &&
        !isOverlaySurfaceNode(node)) {
      continue;
    }
    final depth = (node['depth'] as int?) ?? 0;
    if (skeleton && depth > 2) {
      continue;
    }

    elementIndex++;
    String? assignedRef;
    if (snapshotId != null && snapshotId.isNotEmpty) {
      final cleanSnap =
          snapshotId.startsWith('@') ? snapshotId.substring(1) : snapshotId;
      final candidate = qualifySnapshotElementRef(
        snapshotId: snapshotId,
        rawId: rawId,
        index1Based: elementIndex,
      );
      final parsedCandidate = parseSnapshotElementRef(candidate);
      var refIndex = parsedCandidate?.elementNumber ?? elementIndex;
      if (refIndex <= 0 || usedIndices.contains(refIndex)) {
        refIndex = elementIndex;
        while (usedIndices.contains(refIndex)) {
          refIndex++;
        }
        assignedRef = '@$cleanSnap:e$refIndex';
      } else {
        assignedRef = candidate;
      }
      usedIndices.add(refIndex);
    }

    final isPwd = isPasswordUiNode(node);
    final sanitizedBoundsMap =
        isPwd ? null : _sanitizeBoundsMap(node['bounds']);
    final sanitizedBoundsList =
        isPwd ? null : _sanitizeBoundsList(node['bounds']);
    final rawName = (node['name'] as String?) ?? '';
    final truncatedName = isPwd ? '•••' : clampUtf16Safe(rawName, 60);
    final redacted = <String, Object?>{
      'id': rawId,
      if (assignedRef != null)
        'ref': assignedRef
      else if (node['ref'] is String)
        'ref': node['ref'],
      'role': isPwd ? 'password' : ((node['role'] as String?) ?? 'unknown'),
      'name': truncatedName,
      'enabled': node['enabled'] != false,
      if (!isPwd) ...<String, Object?>{
        if (sanitizedBoundsMap != null)
          'bounds': sanitizedBoundsMap
        else if (sanitizedBoundsList != null)
          'bounds': sanitizedBoundsList,
      },
      if (isPwd) 'isPassword': true,
      if (node['visible'] is bool) 'visible': node['visible'],
      if (node['offscreen'] is bool) 'offscreen': node['offscreen'],
      if (node['editable'] is bool) 'editable': node['editable'],
      if (node['occluded'] is bool) 'occluded': node['occluded'],
      if (node['modal'] is bool) 'modal': node['modal'],
      if (node['parentSurfaceId'] is String)
        'parentSurfaceId': node['parentSurfaceId'],
      if (node['depth'] is int) 'depth': node['depth'],
      if (node['parentId'] is String) 'parentId': node['parentId'],
      if (node['childrenCount'] is int) 'childrenCount': node['childrenCount'],
    };
    out.add(redacted);
  }
  return out;
}

final RegExp _workspaceQueryRe = RegExp(r'^[a-zA-Z0-9_.\- ]{1,64}$');

/// Validates a project/workspace query string (`UDC-11` S11.2):
/// accepts `1..64` safe name characters and rejects path separators (`/`, `\`),
/// parent traversal (`..`), drive colons (`:`), home expansion (`~`), and shell
/// metacharacters.
bool isValidWorkspaceQuery(String? query) {
  if (query == null || query.length > 64) return false;
  final trimmed = query.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains('..')) return false;
  return _workspaceQueryRe.hasMatch(trimmed);
}

/// Validates a continuation prompt passed to `workspace.coding_agent` (`UDC-11` S11.3):
/// accepts `0..500` UTF-8 characters without ASCII control characters (`\x00`..`\x08`,
/// `\x0B`, `\x0C`, `\x0E`..`\x1F`, `\x7F`).
bool isSafeAgentPrompt(String? prompt) {
  if (prompt == null) return false;
  if (prompt.length > 500) return false;
  for (var i = 0; i < prompt.length; i++) {
    final code = prompt.codeUnitAt(i);
    if ((code >= 0x00 && code <= 0x08) ||
        code == 0x0B ||
        code == 0x0C ||
        (code >= 0x0E && code <= 0x1F) ||
        code == 0x7F) {
      return false;
    }
  }
  return true;
}

final List<RegExp> _sensitiveTokenPatterns = <RegExp>[
  RegExp(r'sk-[a-zA-Z0-9_\-]{12,}'),
  RegExp(r'gh[pousr]_[a-zA-Z0-9_]{12,}'),
  RegExp(r'github_pat_[a-zA-Z0-9_]{12,}'),
  RegExp(r'AIza[0-9A-Za-z\-_]{16,}'),
  RegExp(r'xox[baprs]-[a-zA-Z0-9\-]{10,}'),
  RegExp(r'(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])'),
  RegExp(r'Bearer\s+[a-zA-Z0-9\-._~+/]+=*', caseSensitive: false),
  RegExp(
    r'(?:password|passwd|secret|api_key|apikey|token|access_token)\s*[:=]\s*["\x27]?[^\s"\x27,;]{4,}["\x27]?',
    caseSensitive: false,
  ),
  RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'),
];

/// Result of redacting secrets/tokens in selected or clipboard text (`UDC-12` S12.2).
typedef RedactedSelectionResult = ({
  String text,
  bool truncated,
  int redactedCount,
});

/// Returns `true` if [text] contains disallowed ASCII control characters
/// (`0x00..0x08`, `0x0B`, `0x0C`, `0x0E..0x1F`, `0x7F`; allows `\t`, `\n`, `\r`)
/// or unpaired UTF-16 surrogates (`0xD800..0xDBFF` without a trailing
/// `0xDC00..0xDFFF`, or an orphan `0xDC00..0xDFFF`).
bool hasBinaryOrInvalidSurrogates(String text) {
  for (var i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if ((code >= 0x00 && code <= 0x08) ||
        code == 0x0B ||
        code == 0x0C ||
        (code >= 0x0E && code <= 0x1F) ||
        code == 0x7F) {
      return true;
    }
    if (code >= 0xD800 && code <= 0xDBFF) {
      if (i + 1 >= text.length) return true;
      final next = text.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    } else if (code >= 0xDC00 && code <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

/// Redacts common API keys, Bearer tokens, private keys, and password assignments
/// from [rawText] and truncates the result to [maxChars] (`80..1600`).
RedactedSelectionResult redactSensitiveSelectionText(
  String rawText, {
  int maxChars = 1200,
}) {
  final clampedMax = maxChars < 80 ? 80 : (maxChars > 1600 ? 1600 : maxChars);
  var working = rawText.trim();
  var count = 0;
  for (final pattern in _sensitiveTokenPatterns) {
    working = working.replaceAllMapped(pattern, (_) {
      count++;
      return '[REDACTED]';
    });
  }
  final truncated = working.length > clampedMax;
  final finalString = truncated ? clampUtf16Safe(working, clampedMax) : working;
  return (
    text: finalString,
    truncated: truncated,
    redactedCount: count,
  );
}

/// Redacts common API keys, Bearer tokens, private keys, and password assignments
/// from [rawText] for `clipboard.write`, supporting up to [maxChars] (`1..4000`)
/// without silently truncating `1601..4000` characters.
RedactedSelectionResult redactSensitiveClipboardText(
  String rawText, {
  int maxChars = 4000,
}) {
  final clampedMax = maxChars < 1 ? 1 : (maxChars > 4000 ? 4000 : maxChars);
  var working = rawText.trim();
  var count = 0;
  for (final pattern in _sensitiveTokenPatterns) {
    working = working.replaceAllMapped(pattern, (_) {
      count++;
      return '[REDACTED]';
    });
  }
  final truncated = working.length > clampedMax;
  final finalString = truncated ? clampUtf16Safe(working, clampedMax) : working;
  return (
    text: finalString,
    truncated: truncated,
    redactedCount: count,
  );
}

final RegExp _httpUrlSpanRe = RegExp(
  r'''https?://[^\s"'`<>()\[\]{}]+''',
  caseSensitive: false,
);

final RegExp _filesystemPathRe = RegExp(
  r'''(^|[\s"'`(\[{=:,])((?:(?:/Users|/home|/var|/tmp|/etc|/opt|/Applications|/Volumes|/Library|/System|/usr|/bin|/sbin|/root)/[^\s"'`<>(),;\]]*|\.{1,2}[/\\][^\s"'`<>(),;\]]*|~[/\\][^\s"'`<>(),;\]]*|[Ff][Ii][Ll][Ee]://[^\s"'`<>(),;\]]+|[A-Za-z]:\\[^\s"'`<>(),;\]]*|\\\\[^\s\\/"'`<>(),;\]]+\\[^\s"'`<>(),;\]]*))''',
);

/// Replaces Unix (`/Users/...`, `/home/...`, `/var/...`, `/tmp/...`,
/// `/etc/...`, `/opt/...`, `/Applications/...`, `/Volumes/...`, `/Library/...`,
/// `/System/...`, `/usr/...`, `/bin/...`, `/sbin/...`, `/root/...`), relative/home
/// (`./...`, `.\...`, `~/...`, `~\...`, `../...`, `..\...`), `file:///...`,
/// UNC (`\\server\share...`), and Windows (`[A-Za-z]:\...`) filesystem paths
/// in [text] with `[PATH]` while preserving full `https://` / `http://` URLs.
String redactFilesystemPaths(String text) => text.splitMapJoin(
      _httpUrlSpanRe,
      onMatch: (m) => m.group(0)!,
      onNonMatch: (segment) => segment.replaceAllMapped(
        _filesystemPathRe,
        (m) => '${m.group(1)}[PATH]',
      ),
    );

/// Convenience helper returning only the redacted string (`UDC-12` S12.2).
String redactSensitiveTokens(String rawText, {int maxChars = 1200}) =>
    redactSensitiveSelectionText(rawText, maxChars: maxChars).text;

/// Redacts sensitive credentials/tokens from browser snapshot text and bounds output to [maxBytes] (`UDC-18` §Wave B).
({String text, bool truncated, int byteCount}) redactBrowserSnapshot(
  String rawSnapshot, {
  int maxBytes = 6144,
}) {
  var working = rawSnapshot;
  for (final pattern in _sensitiveTokenPatterns) {
    working = working.replaceAllMapped(pattern, (_) => '[REDACTED]');
  }
  final encoded = utf8.encode(working);
  if (encoded.length <= maxBytes) {
    return (text: working, truncated: false, byteCount: encoded.length);
  }
  // Truncate cleanly at UTF-8 character boundary within maxBytes
  var byteLimit = maxBytes;
  while (byteLimit > 0 && (encoded[byteLimit - 1] & 0xC0) == 0x80) {
    byteLimit--; // back off UTF-8 continuation byte
  }
  if (byteLimit > 0 && (encoded[byteLimit - 1] & 0x80) != 0) {
    byteLimit--; // back off lead byte
  }
  final truncatedText =
      utf8.decode(encoded.sublist(0, byteLimit), allowMalformed: true);
  return (text: truncatedText, truncated: true, byteCount: byteLimit);
}

/// Extensions forbidden for `beam.transfer` (`UDC-13` S13.3):
/// executables, scripts, installers, libraries, and app bundles.
const Set<String> forbiddenBeamExtensions = <String>{
  'exe',
  'bat',
  'cmd',
  'com',
  'msi',
  'ps1',
  'vbs',
  'js',
  'jse',
  'wsf',
  'wsh',
  'scr',
  'pif',
  'reg',
  'dll',
  'sys',
  'drv',
  'sh',
  'bash',
  'zsh',
  'command',
  'app',
  'dmg',
  'pkg',
  'dylib',
  'so',
  'bin',
  'run',
  'jar',
  'py',
  'rb',
  'pl',
};

final RegExp _beamFileNameRe =
    RegExp(r'^[a-zA-Z0-9_.\- ()]+\.[a-zA-Z0-9]{1,10}$');

/// Validates a safe filename for `beam.transfer` (`UDC-13` S13.3):
/// rejects path separators (`/`, `\`), parent traversal (`..`), hidden files
/// starting with `.`, Windows reserved device names, and executable extensions
/// in [forbiddenBeamExtensions].
bool isValidBeamFileName(String? fileName) {
  if (fileName == null) return false;
  final trimmed = fileName.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 120 ||
      trimmed != fileName ||
      trimmed.startsWith('.') ||
      trimmed.endsWith('.') ||
      trimmed.contains('..') ||
      trimmed.contains('/') ||
      trimmed.contains(r'\')) {
    return false;
  }
  if (!_beamFileNameRe.hasMatch(trimmed)) return false;
  final dotIdx = trimmed.lastIndexOf('.');
  if (dotIdx <= 0 || dotIdx == trimmed.length - 1) return false;
  final stem = trimmed.substring(0, dotIdx).toLowerCase();
  const reservedWindowsStems = <String>{
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  };
  if (reservedWindowsStems.contains(stem)) return false;
  final ext = trimmed.substring(dotIdx + 1).toLowerCase();
  if (forbiddenBeamExtensions.contains(ext)) return false;
  return true;
}

final RegExp _smartHomeEntityRe = RegExp(r'^[a-z0-9_]{2,32}\.[a-z0-9_]{1,64}$');

/// Returns `true` if [entityId] belongs to a hard-denied physical security
/// smart-home domain (`lock.*`, `alarm_control_panel.*`, `camera.*`,
/// `garage_door.*`, `siren.*`, `UDC-T36`).
bool isHardDeniedSmartHomeEntity(String? entityId) {
  if (entityId == null) return false;
  final trimmed = entityId.trim().toLowerCase();
  final dotIdx = trimmed.indexOf('.');
  final domain = dotIdx > 0 ? trimmed.substring(0, dotIdx) : trimmed;
  if (hardDeniedSmartHomeDomains.contains(domain)) {
    return true;
  }
  final namePart = dotIdx > 0 ? trimmed.substring(dotIdx + 1) : '';
  if (namePart.contains('door_lock') ||
      namePart.contains('front_door') ||
      namePart.contains('garage') ||
      namePart.contains('alarm')) {
    return true;
  }
  return false;
}

/// Validates a Home Assistant entity ID (`<domain>.<object_id>`) against
/// [allowedSmartHomeDomains] and [hardDeniedSmartHomeDomains] (`UDC-14` S14.4).
bool isValidSmartHomeEntityId(String? entityId) {
  if (entityId == null) return false;
  final trimmed = entityId.trim().toLowerCase();
  if (trimmed != entityId || !_smartHomeEntityRe.hasMatch(trimmed)) {
    return false;
  }
  if (isHardDeniedSmartHomeEntity(trimmed)) {
    return false;
  }
  final domain = trimmed.split('.').first;
  return allowedSmartHomeDomains.contains(domain);
}

/// Validates a Smart TV device name or ID query (`1..64` UTF-8 characters,
/// allowing Vietnamese names like `'TV phòng khách'`, rejecting control chars
/// and path separators).
bool isValidTvDeviceQuery(String? query) {
  if (query == null || query.length > 64) return false;
  final trimmed = query.trim();
  if (trimmed.isEmpty ||
      trimmed.contains('..') ||
      trimmed.contains('/') ||
      trimmed.contains(r'\')) {
    return false;
  }
  return isSafeAgentPrompt(query);
}

/// Validates text passed to `clipboard.write` (`UDC-15` S15.1, `UDC-T37`):
/// accepts `1..4000` UTF-8 characters without ASCII null/control bytes (allows
/// `\n`, `\r`, `\t` for multiline code snippets) or unpaired UTF-16 surrogates.
bool isSafeClipboardWriteText(String? text) {
  if (text == null) return false;
  final trimmed = text.trim();
  if (trimmed.isEmpty || text.length > 4000) return false;
  return !hasBinaryOrInvalidSurrogates(text);
}

/// Allowed execution runtimes for LLM-synthesized tools (`FORGE-LATM`).
const Set<String> allowedSynthesizedToolRuntimes = <String>{
  'auto',
  'pipeline',
  'python',
  'node',
  'powershell',
  'bash',
};

final RegExp _toolSlugRe = RegExp(r'^[a-z][a-z_]{1,47}$');

/// Normalizes or validates an LLM-proposed tool slug (`a-z_`, `2..48` chars, XTP `^[a-z]+\.[a-z_]+$` safe).
String normalizeSynthesizedToolSlug(String? rawName,
    {String fallback = 'custom_tool'}) {
  final cleanFallback = fallback
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final safeFallback =
      cleanFallback.length >= 2 && _toolSlugRe.hasMatch(cleanFallback)
          ? cleanFallback
          : 'custom_tool';
  if (rawName == null || rawName.trim().isEmpty) return safeFallback;
  var slug = rawName
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (slug.isEmpty) return safeFallback;
  if (!RegExp(r'^[a-z]').hasMatch(slug)) {
    slug = 'tool_$slug';
  }
  if (slug.length > 48) {
    slug = slug.substring(0, 48).replaceAll(RegExp(r'_+$'), '');
  }
  if (slug.length < 2 || !_toolSlugRe.hasMatch(slug)) {
    return safeFallback;
  }
  return slug;
}

/// Result of static safety inspection on an LLM-synthesized script (`FORGE-LATM`).
typedef SynthesizedScriptValidationResult = ({
  bool safe,
  String normalizedRuntime,
  String? violationCode,
  String? reasonVi,
});

final List<({String code, RegExp pattern, String reasonVi})>
    _dangerousScriptRules = <({String code, RegExp pattern, String reasonVi})>[
  (
    code: 'destructive_fs',
    pattern: RegExp(
      r'(?:\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\b|\brm\s+-[a-zA-Z]*f[a-zA-Z]*r\b|'
      r'\bdel\s+/[fqs]|\brmdir\s+/s\b|\bFormat-Volume\b|\bClear-Disk\b|'
      r'Remove-Item\b[^\n]*-Recurse[^\n]*-Force|'
      r'shutil\.rmtree\s*\(\s*["\x27](?:/|[A-Za-z]:\\|~))',
      caseSensitive: false,
    ),
    reasonVi:
        'Từ chối mã công cụ chứa lệnh xóa hoặc định dạng ổ đĩa nguy hiểm (rm -rf / Format-Volume / rmtree gốc).',
  ),
  (
    code: 'credential_harvesting',
    pattern: RegExp(
      r'(?:[/\\]\.ssh[/\\]|[/\\]\.aws[/\\]|[/\\]\.gnupg[/\\]|[/\\]\.kube[/\\]|'
      r'\bid_rsa\b|\bid_ed25519\b|/etc/shadow\b|/etc/passwd\b|'
      r'\bsecurity\s+find-(?:generic|internet)-password\b|'
      r'\bcmdkey\b|\bvaultcmd\b|\b Mimikatz\b|\breg\s+save\s+hklm\\(?:sam|system)\b)',
      caseSensitive: false,
    ),
    reasonVi:
        'Từ chối mã công cụ truy cập khóa SSH, thông tin xác thực đám mây (.aws/.ssh) hoặc kho mật khẩu hệ điều hành.',
  ),
  (
    code: 'remote_shell_or_eval',
    pattern: RegExp(
      r'(?:/dev/tcp/|\bnc\s+-[a-zA-Z]*e\b|\bncat\b[^\n]*--exec|'
      r'\bInvoke-Expression\b|\biex\s*\(|\bDownloadString\s*\(|'
      r'\bcurl\b[^\n|]*\|\s*(?:sh|bash|zsh|pwsh|powershell|python)\b|'
      r'\bwget\b[^\n|]*\|\s*(?:sh|bash|zsh|python)\b|'
      r'\bpty\.spawn\s*\()',
      caseSensitive: false,
    ),
    reasonVi:
        'Từ chối mã công cụ tải thực thi từ xa (curl|sh, Invoke-Expression) hoặc mở kết nối reverse shell.',
  ),
  (
    code: 'arbitrary_shell_spawn',
    pattern: RegExp(
      r'(?:\bos\.system\s*\(|\bsubprocess\.(?:Popen|call|run|check_output)\s*\([^\)]*shell\s*=\s*True|'
      r'\bchild_process\b[^\n]*\bexec(?:Sync)?\s*\(|'
      r'\bStart-Process\b[^\n]*-Verb\s+RunAs)',
      caseSensitive: false,
    ),
    reasonVi:
        'Từ chối mã công cụ gọi shell lồng nhau không an toàn (os.system / shell=True / RunAs). Hãy dùng thư viện chuẩn trực tiếp.',
  ),
  (
    code: 'system_binary_modification',
    pattern: RegExp(
      r'(?:/System/Library/|/bin/|/sbin/|/usr/bin/|C:\\Windows\\System32|'
      r'\bchmod\s+[0-7]*777\b|\bchown\s+root\b|\bsudo\s+)',
      caseSensitive: false,
    ),
    reasonVi:
        'Từ chối mã công cụ can thiệp thư mục hệ thống hoặc leo thang đặc quyền (sudo / System32).',
  ),
];

/// Performs static defense-in-depth validation on LLM-synthesized tool code
/// (`FORGE-LATM`) before writing or executing it inside the XUNA sandbox.
SynthesizedScriptValidationResult validateSynthesizedToolScript({
  required String runtime,
  required String scriptCode,
}) {
  final normRuntime = runtime.trim().toLowerCase();
  if (!allowedSynthesizedToolRuntimes.contains(normRuntime)) {
    return (
      safe: false,
      normalizedRuntime: 'pipeline',
      violationCode: 'unsupported_runtime',
      reasonVi:
          'Runtime "$runtime" không nằm trong danh sách cho phép (python, node, powershell, bash, pipeline).',
    );
  }
  final trimmed = scriptCode.trim();
  if (trimmed.isEmpty) {
    return (
      safe: false,
      normalizedRuntime: normRuntime,
      violationCode: 'empty_script',
      reasonVi: 'Mã nguồn công cụ (scriptCode) không được để trống.',
    );
  }
  if (scriptCode.length > 4000) {
    return (
      safe: false,
      normalizedRuntime: normRuntime,
      violationCode: 'script_too_large',
      reasonVi: 'Mã nguồn công cụ vượt quá giới hạn an toàn 4.000 ký tự.',
    );
  }
  for (var i = 0; i < scriptCode.length; i++) {
    final code = scriptCode.codeUnitAt(i);
    if ((code >= 0x00 && code <= 0x08) ||
        code == 0x0B ||
        code == 0x0C ||
        (code >= 0x0E && code <= 0x1F) ||
        code == 0x7F) {
      return (
        safe: false,
        normalizedRuntime: normRuntime,
        violationCode: 'control_characters',
        reasonVi:
            'Mã nguồn công cụ chứa ký tự điều khiển nhị phân không hợp lệ.',
      );
    }
  }
  for (final rule in _dangerousScriptRules) {
    if (rule.pattern.hasMatch(scriptCode)) {
      return (
        safe: false,
        normalizedRuntime: normRuntime,
        violationCode: rule.code,
        reasonVi: rule.reasonVi,
      );
    }
  }
  return (
    safe: true,
    normalizedRuntime: normRuntime == 'auto' ? 'python' : normRuntime,
    violationCode: null,
    reasonVi: null,
  );
}
