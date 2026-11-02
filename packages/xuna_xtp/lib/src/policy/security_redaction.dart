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
  final normalized = elementName.trim().toLowerCase();
  final words =
      normalized.split(_wordSplitRe).where((w) => w.isNotEmpty).toSet();
  for (final keyword in consequentialElementKeywords) {
    if (keyword.contains(' ')) {
      if (normalized.contains(keyword)) return true;
    } else if (words.contains(keyword)) {
      return true;
    }
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

/// Returns `true` if [appIdOrProcess] is on XUNA's hard-refusal denylist
/// (terminals, password managers, banking apps, or system security panes).
bool isHardDeniedAppOrProcess(String? appIdOrProcess) {
  if (appIdOrProcess == null || appIdOrProcess.trim().isEmpty) return true;
  final raw = appIdOrProcess.trim().toLowerCase();
  final baseName = raw.split(RegExp(r'[/\\]')).last;
  if (hardDeniedAppsAndProcesses.contains(raw) ||
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
  return false;
}

/// Returns `true` if a UI node represents a password field (`UDC-8` §4.2).
bool isPasswordUiNode(Map<String, Object?> node) {
  if (node['isPassword'] == true || node['password'] == true) {
    return true;
  }
  final role = (node['role'] as String?)?.toLowerCase() ?? '';
  if (role.contains('password') ||
      role.contains('securetext') ||
      role == 'axsecuretextfield') {
    return true;
  }
  final name = (node['name'] as String?)?.toLowerCase() ?? '';
  if (name.contains('password') ||
      name.contains('mật khẩu') ||
      name.contains('passcode') ||
      name.contains('mã pin')) {
    return true;
  }
  return false;
}

/// Redacts password fields in a list of UI tree nodes (`UDC-8` §4.2):
/// replaces `name` with `'•••'` and removes `value`.
List<Map<String, Object?>> redactUiTreeNodes(
  List<Map<String, Object?>> nodes, {
  int maxNodes = 300,
}) {
  final out = <Map<String, Object?>>[];
  for (final node in nodes) {
    if (out.length >= maxNodes) break;
    final isPwd = isPasswordUiNode(node);
    final rawName = (node['name'] as String?) ?? '';
    final truncatedName = isPwd
        ? '•••'
        : (rawName.length > 60 ? rawName.substring(0, 60) : rawName);
    final redacted = <String, Object?>{
      'id': (node['id'] as String?) ?? '',
      'role': isPwd ? 'password' : ((node['role'] as String?) ?? 'unknown'),
      'name': truncatedName,
      'enabled': node['enabled'] != false,
      if (node['bounds'] is Map) 'bounds': node['bounds'],
      if (isPwd) 'isPassword': true,
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
  if (query == null) return false;
  final trimmed = query.trim();
  if (trimmed.isEmpty || trimmed.length > 64) return false;
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
  final finalString = truncated ? working.substring(0, clampedMax) : working;
  return (
    text: finalString,
    truncated: truncated,
    redactedCount: count,
  );
}

/// Convenience helper returning only the redacted string (`UDC-12` S12.2).
String redactSensitiveTokens(String rawText, {int maxChars = 1200}) =>
    redactSensitiveSelectionText(rawText, maxChars: maxChars).text;

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
  if (query == null) return false;
  final trimmed = query.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 64 ||
      trimmed.contains('..') ||
      trimmed.contains('/') ||
      trimmed.contains(r'\')) {
    return false;
  }
  return isSafeAgentPrompt(trimmed);
}

/// Validates text passed to `clipboard.write` (`UDC-15` S15.1, `UDC-T37`):
/// accepts `1..4000` UTF-8 characters without ASCII null/control bytes (allows
/// `\n`, `\r`, `\t` for multiline code snippets).
bool isSafeClipboardWriteText(String? text) {
  if (text == null) return false;
  final trimmed = text.trim();
  if (trimmed.isEmpty || text.length > 4000) return false;
  for (var i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
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
