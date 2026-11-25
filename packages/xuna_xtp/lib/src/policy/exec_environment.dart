/// Environment allowlist for `exec.run` children (`ADR-0018`).
///
/// A child process receives only toolchain and locale variables. Everything
/// else (API keys, tokens, `XUNA_*`, cloud credentials, shell start-up hooks
/// such as `BASH_ENV`/`ENV`/`ZDOTDIR`) is dropped, so a command such as
/// `echo $GEMINI_API_KEY` prints an empty line.
library;

const Set<String> _posixAllowlist = <String>{
  'PATH', 'HOME', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TERM', //
  'COLORTERM', 'TMPDIR', 'SHELL', 'NVM_DIR', 'NVM_BIN', 'FVM_CACHE_PATH',
  'VIRTUAL_ENV', 'GOPATH', 'GOROOT', 'CARGO_HOME', 'RUSTUP_HOME',
  'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'FLUTTER_ROOT',
  'PUB_CACHE', 'PYENV_ROOT', 'CONDA_PREFIX', 'DEVELOPER_DIR', 'SDKROOT',
};

const Set<String> _windowsAllowlist = <String>{
  'SYSTEMROOT', 'SYSTEMDRIVE', 'WINDIR', 'COMSPEC', 'PATHEXT', 'TEMP', 'TMP', //
  'USERPROFILE', 'USERNAME', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMFILES',
  'PROGRAMFILES(X86)', 'PROGRAMW6432', 'PROGRAMDATA', 'COMMONPROGRAMFILES',
  'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'OS', 'HOMEDRIVE',
  'HOMEPATH',
};

/// Prefixes that are never passed to a child, even if a future allowlist
/// entry matched them. Compared case-insensitively.
const List<String> execSecretEnvPrefixes = <String>[
  'XUNA_', 'GEMINI_', 'OPENAI_', 'GROQ_', 'AWS_', 'ANTHROPIC_', 'FIREBASE_', //
  'GOOGLE_', 'AZURE_', 'GITHUB_TOKEN', 'GH_TOKEN', 'NPM_TOKEN',
];

/// Returns the sanitized child environment built from [parent].
Map<String, String> sanitizeExecEnvironment(
  Map<String, String> parent, {
  required bool windows,
}) {
  final out = <String, String>{};
  for (final entry in parent.entries) {
    final upper = entry.key.toUpperCase();
    if (execSecretEnvPrefixes.any(upper.startsWith)) continue;
    final allowed = windows
        ? (_posixAllowlist.contains(upper) || _windowsAllowlist.contains(upper))
        : _posixAllowlist.contains(entry.key);
    if (allowed) out[entry.key] = entry.value;
  }
  return out;
}
