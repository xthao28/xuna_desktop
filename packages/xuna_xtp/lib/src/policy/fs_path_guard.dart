import '../schemas.dart';
import 'shell_control_policy.dart';

/// Kind of filesystem access being classified by [classifyFsPath].
enum FsAccessKind { read, write }

/// Result of [classifyFsPath] and `classifyExecCommand`: either a refusal
/// ([denied] with a stable [errorCode]) or the effective [risk].
class FsGuardDecision {
  const FsGuardDecision.allow(this.risk, this.reasonCode)
      : denied = false,
        errorCode = null;

  const FsGuardDecision.deny(this.errorCode, this.reasonCode)
      : denied = true,
        risk = RiskTier.r3;

  final bool denied;
  final String? errorCode;
  final RiskTier risk;

  /// Short machine-readable reason (`^[a-z0-9_.-]{1,64}$`).
  final String reasonCode;

  /// Combines two decisions: any refusal wins, otherwise the higher risk.
  FsGuardDecision merge(FsGuardDecision other) {
    if (denied) return this;
    if (other.denied) return other;
    return other.risk > risk ? other : this;
  }
}

final RegExp _controlChars = RegExp(r'[\x00-\x1f\x7f]');
final RegExp _driveLetter = RegExp(r'^[A-Za-z]:$');
final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:/');

/// Lexically normalizes [raw] to an absolute path with `/` separators.
///
/// Expands `~`, `~/`, `$HOME/` and `${HOME}/` with [homeDirectory], joins a
/// relative path onto [baseDirectory], and collapses `.`/`..`. Returns `null`
/// when the path cannot be made absolute without guessing (relative with no
/// base, `~` with no known home) or contains control characters.
String? normalizeHostPath(
  String raw, {
  String? homeDirectory,
  String? baseDirectory,
  bool windows = false,
}) {
  if (raw.isEmpty || raw.length > 4096 || _controlChars.hasMatch(raw)) {
    return null;
  }
  var path = windows ? raw.replaceAll(r'\', '/') : raw;
  final home = homeDirectory == null
      ? null
      : (windows ? homeDirectory.replaceAll(r'\', '/') : homeDirectory);
  for (final prefix in const <String>[r'${HOME}', r'$HOME', '~']) {
    if (path == prefix || path.startsWith('$prefix/')) {
      if (home == null) return null;
      path = '$home${path.substring(prefix.length)}';
      break;
    }
  }
  final isAbsolute =
      path.startsWith('/') || (windows && _windowsAbsolute.hasMatch(path));
  if (!isAbsolute) {
    if (baseDirectory == null) return null;
    final base = normalizeHostPath(
      baseDirectory,
      homeDirectory: homeDirectory,
      windows: windows,
    );
    if (base == null) return null;
    path = '$base/$path';
  }
  final parts = <String>[];
  String? drive;
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (windows &&
        drive == null &&
        parts.isEmpty &&
        _driveLetter.hasMatch(segment)) {
      drive = segment.toUpperCase();
      continue;
    }
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  final joined = parts.join('/');
  return drive != null ? '$drive/$joined' : '/$joined';
}

/// Whether normalized [path] equals or is below normalized [root].
bool isPathInsideRoot(String path, String root, {bool caseInsensitive = true}) {
  var p = caseInsensitive ? path.toLowerCase() : path;
  var r = caseInsensitive ? root.toLowerCase() : root;
  if (r.length > 1 && r.endsWith('/')) r = r.substring(0, r.length - 1);
  if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
  if (r == '/') return true;
  return p == r || p.startsWith('$r/');
}

const Set<String> _secretDirectorySegments = <String>{
  '.ssh',
  '.gnupg',
  '.aws',
  '.kube',
  '.password-store',
  'keychains',
};

const List<String> _passwordManagerMarkers = <String>[
  '1password',
  'bitwarden',
  'keepassxc',
  'keepass',
  'lastpass',
  'dashlane',
];

const List<String> _hardDeniedSystemPaths = <String>[
  '/etc/shadow',
  '/etc/gshadow',
  '/etc/master.passwd',
  '/etc/sudoers',
  '/etc/sudoers.d',
];

/// Returns a reason when [path] (normalized) is inside a credential store,
/// secret vault or protected system file that no tool may touch
/// (`ADR-0018` Hard-Deny), otherwise `null`. Matching is case-insensitive.
String? hardDeniedPathReason(String path) {
  var lower = path.toLowerCase().replaceAll(r'\', '/');
  if (lower.startsWith('/private/')) lower = lower.substring('/private'.length);
  final segments = lower.split('/').where((s) => s.isNotEmpty).toList();
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    if (_secretDirectorySegments.contains(segment)) return 'secret_store_path';
    if (_passwordManagerMarkers.any(segment.contains)) {
      return 'password_manager_path';
    }
    if (segment == '.netrc' || segment == '.git-credentials') {
      return 'secret_store_path';
    }
    final next = i + 1 < segments.length ? segments[i + 1] : null;
    if (segment == '.docker' && next == 'config.json') {
      return 'secret_store_path';
    }
    if (segment == '.git' && next == 'config') return 'secret_store_path';
    if (segment == 'system32' && next == 'config' && i + 2 < segments.length) {
      return 'system_credential_path';
    }
  }
  for (final denied in _hardDeniedSystemPaths) {
    if (isPathInsideRoot(lower, denied)) return 'system_credential_path';
  }
  return null;
}

/// Whether the file name of [path] looks like a secret (`.env`, `.env.*`,
/// keys and certificates, SSH private keys, token rc files).
bool isSecretFileName(String path) {
  final name = path.replaceAll(r'\', '/').split('/').last.toLowerCase();
  if (name == '.env' || name.startsWith('.env.')) return true;
  for (final ext in const <String>['.pem', '.key', '.p12', '.pfx', '.jks']) {
    if (name.endsWith(ext)) return true;
  }
  for (final prefix in const <String>[
    'id_rsa',
    'id_ed25519',
    'id_ecdsa',
    'id_dsa',
  ]) {
    if (name.startsWith(prefix)) return true;
  }
  return const <String>{'.npmrc', '.pypirc', '.pgpass', '.htpasswd'}
      .contains(name);
}

const List<String> _systemWriteRoots = <String>[
  '/etc',
  '/private/etc',
  '/usr',
  '/bin',
  '/sbin',
  '/system',
  '/library',
  '/applications',
  '/opt',
  'c:/windows',
  'c:/program files',
  'c:/program files (x86)',
  'c:/programdata',
];

/// Classifies one access to [normalizedPath] (and to [resolvedPath], its real
/// path after symlink resolution, when the host could resolve it).
///
/// Reads: Hard-Deny paths and secret files are refused, everything else is
/// `R1`. Writes: Hard-Deny paths are refused; secret files, dotfiles in the
/// home directory, system locations and anything outside
/// [ShellControlPolicy.workspaceRoots] are `R3`; the rest is `R2`.
FsGuardDecision classifyFsPath({
  required String normalizedPath,
  String? resolvedPath,
  required FsAccessKind access,
  required ShellControlPolicy shellControl,
  String? homeDirectory,
  bool windows = false,
  bool caseInsensitive = true,
  String? Function(String normalizedPath)? realPath,
}) {
  final lexical = _classifyOne(
    normalizedPath,
    access,
    shellControl,
    homeDirectory,
    windows,
    caseInsensitive,
    null,
  );
  if (resolvedPath == null || resolvedPath == normalizedPath) return lexical;
  // The real path is compared with the real paths of the home directory and
  // workspace roots too (e.g. `/var` → `/private/var` on macOS).
  return lexical.merge(
    _classifyOne(
      resolvedPath,
      access,
      shellControl,
      homeDirectory,
      windows,
      caseInsensitive,
      realPath,
    ),
  );
}

/// Whether normalized [path] is inside one of [shellControl]'s workspace
/// roots (always `false` when none are configured).
bool isInsideWorkspaceRoots(
  String path,
  ShellControlPolicy shellControl, {
  String? homeDirectory,
  bool windows = false,
  bool caseInsensitive = true,
  String? Function(String normalizedPath)? realPath,
}) {
  for (final rawRoot in shellControl.workspaceRoots) {
    final root = normalizeHostPath(
      rawRoot,
      homeDirectory: homeDirectory,
      windows: windows,
    );
    if (root == null) continue;
    final realRoot = realPath?.call(root);
    for (final candidate in <String?>[root, realRoot]) {
      if (candidate != null &&
          isPathInsideRoot(path, candidate, caseInsensitive: caseInsensitive)) {
        return true;
      }
    }
  }
  return false;
}

FsGuardDecision _classifyOne(
  String path,
  FsAccessKind access,
  ShellControlPolicy shellControl,
  String? homeDirectory,
  bool windows,
  bool caseInsensitive,
  String? Function(String normalizedPath)? realPath,
) {
  final hardReason = hardDeniedPathReason(path);
  if (hardReason != null) {
    return FsGuardDecision.deny('fs_path_forbidden', hardReason);
  }
  final secret = isSecretFileName(path);
  if (access == FsAccessKind.read) {
    return secret
        ? const FsGuardDecision.deny('fs_secret_file_forbidden', 'secret_file')
        : const FsGuardDecision.allow(RiskTier.r1, 'read');
  }
  if (secret) return const FsGuardDecision.allow(RiskTier.r3, 'secret_file');
  final home = homeDirectory == null
      ? null
      : normalizeHostPath(homeDirectory, windows: windows);
  for (final h in <String?>[home, if (home != null) realPath?.call(home)]) {
    if (h == null ||
        !isPathInsideRoot(path, h, caseInsensitive: caseInsensitive)) {
      continue;
    }
    final rest = path.substring(h.length).split('/').where((s) => s.isNotEmpty);
    if (rest.isNotEmpty && rest.first.startsWith('.')) {
      return const FsGuardDecision.allow(RiskTier.r3, 'dotfile_target');
    }
  }
  for (final root in _systemWriteRoots) {
    if (isPathInsideRoot(path, root)) {
      return const FsGuardDecision.allow(RiskTier.r3, 'system_target');
    }
  }
  if (isInsideWorkspaceRoots(
    path,
    shellControl,
    homeDirectory: homeDirectory,
    windows: windows,
    caseInsensitive: caseInsensitive,
    realPath: realPath,
  )) {
    return const FsGuardDecision.allow(RiskTier.r2, 'workspace');
  }
  return const FsGuardDecision.allow(RiskTier.r3, 'outside_workspace');
}
