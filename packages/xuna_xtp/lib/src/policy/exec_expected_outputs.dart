/// Output postconditions for `exec.run` (`expectFiles`, upgrade plan P1.1 / U3,
/// `XUNA_XTP_V1_CONTRACT.md` §8).
///
/// Pure Dart: parsing of the `expectFiles` argument and the decision from
/// host-observed file facts. The Desktop Agent does the disk I/O (stat, header
/// read, SHA-256) and passes [ObservedExpectedFile]s to [evaluateExpectedFiles].
library;

/// Most entries accepted in `expectFiles`.
const int expectFilesMaxEntries = 16;

/// Most header bytes a `magic` prefix may name.
const int expectFilesMaxMagicBytes = 16;

/// Largest file the host hashes (64 MiB). A larger file gets no `sha256` in
/// its artifact; a `sha256` expectation on it is a mismatch.
const int expectFilesMaxHashBytes = 64 * 1024 * 1024;

/// Error code when an expected file is absent, not a regular file or smaller
/// than `minBytes`.
const String expectedOutputMissing = 'expected_output_missing';

/// Error code when an expected file exists but its magic prefix or SHA-256
/// does not match, it could not be read, or it is a forbidden target.
const String expectedOutputMismatch = 'expected_output_mismatch';

final RegExp _magicPattern = RegExp(r'^(?:[0-9a-fA-F]{2}){1,16}$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// One validated `expectFiles` entry.
class ExpectedFileSpec {
  const ExpectedFileSpec({
    required this.path,
    this.minBytes,
    this.magic,
    this.sha256,
  });

  /// The path exactly as the caller sent it (absolute or `~`-prefixed).
  final String path;
  final int? minBytes;

  /// Expected leading bytes, or null.
  final List<int>? magic;

  /// Expected lowercase hex SHA-256, or null.
  final String? sha256;

  /// Parses the raw `expectFiles` argument. Returns null when it is not a
  /// 1..[expectFilesMaxEntries] list of objects with exactly the keys
  /// `path` (1..512 chars, required), `minBytes` (int ≥ 0), `magic`
  /// (1..16 bytes as hex) and `sha256` (64 hex chars).
  static List<ExpectedFileSpec>? parseList(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > expectFilesMaxEntries) {
      return null;
    }
    final specs = <ExpectedFileSpec>[];
    for (final item in raw) {
      if (item is! Map) return null;
      const allowed = <String>{'path', 'minBytes', 'magic', 'sha256'};
      if (item.keys.any((k) => !allowed.contains(k))) return null;
      final path = item['path'];
      if (path is! String ||
          path.isEmpty ||
          path.length > 512 ||
          path.contains('\x00')) {
        return null;
      }
      final minBytes = item['minBytes'];
      if (item.containsKey('minBytes') && (minBytes is! int || minBytes < 0)) {
        return null;
      }
      final magic = item['magic'];
      if (item.containsKey('magic') &&
          (magic is! String || !_magicPattern.hasMatch(magic))) {
        return null;
      }
      final sha = item['sha256'];
      if (item.containsKey('sha256') &&
          (sha is! String || !_sha256Pattern.hasMatch(sha))) {
        return null;
      }
      specs.add(
        ExpectedFileSpec(
          path: path,
          minBytes: minBytes as int?,
          magic: magic is String ? _hexBytes(magic) : null,
          sha256: sha is String ? sha.toLowerCase() : null,
        ),
      );
    }
    return specs;
  }
}

List<int> _hexBytes(String hex) => <int>[
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];

/// What the host found at an expected path after the command exited.
class ObservedExpectedFile {
  const ObservedExpectedFile.missing()
      : exists = false,
        isFile = false,
        forbidden = false,
        unreadable = false,
        sizeBytes = null,
        header = const <int>[],
        sha256 = null;

  const ObservedExpectedFile.notAFile()
      : exists = true,
        isFile = false,
        forbidden = false,
        unreadable = false,
        sizeBytes = null,
        header = const <int>[],
        sha256 = null;

  /// The real path is a Hard-Deny location or a secret file (e.g. a symlink
  /// created by the command). Only its existence is reported (no size, hash
  /// or magic).
  const ObservedExpectedFile.forbidden()
      : exists = true,
        isFile = false,
        forbidden = true,
        unreadable = false,
        sizeBytes = null,
        header = const <int>[],
        sha256 = null;

  /// A regular file the host could not read.
  const ObservedExpectedFile.unreadable({this.sizeBytes})
      : exists = true,
        isFile = true,
        forbidden = false,
        unreadable = true,
        header = const <int>[],
        sha256 = null;

  /// A readable regular file. [sha256] is null when it is larger than
  /// [expectFilesMaxHashBytes]; [header] holds up to
  /// [expectFilesMaxMagicBytes] leading bytes.
  const ObservedExpectedFile.file({
    required int this.sizeBytes,
    required this.header,
    required this.sha256,
  })  : exists = true,
        isFile = true,
        forbidden = false,
        unreadable = false;

  final bool exists;
  final bool isFile;
  final bool forbidden;
  final bool unreadable;
  final int? sizeBytes;
  final List<int> header;
  final String? sha256;
}

/// Why an expected file failed its check (`artifacts[].problem`).
enum ExpectedFileProblem {
  missing('missing', expectedOutputMissing),
  notAFile('not_a_file', expectedOutputMissing),
  tooSmall('too_small', expectedOutputMissing),
  magicMismatch('magic_mismatch', expectedOutputMismatch),
  sha256Mismatch('sha256_mismatch', expectedOutputMismatch),
  tooLargeToHash('too_large_to_hash', expectedOutputMismatch),
  unreadable('unreadable', expectedOutputMismatch),
  forbidden('forbidden', expectedOutputMismatch);

  const ExpectedFileProblem(this.wire, this.errorCode);
  final String wire;
  final String errorCode;
}

/// Per-file outcome; [toJson] is one `artifacts[]` entry.
class ExpectedFileCheck {
  const ExpectedFileCheck({
    required this.spec,
    required this.observed,
    this.problem,
  });

  final ExpectedFileSpec spec;
  final ObservedExpectedFile observed;
  final ExpectedFileProblem? problem;

  bool get ok => problem == null;

  Map<String, Object?> toJson() {
    final showFacts = observed.isFile && !observed.forbidden;
    final magic = spec.magic;
    return <String, Object?>{
      'path': spec.path,
      'exists': observed.exists,
      if (showFacts && observed.sizeBytes != null)
        'sizeBytes': observed.sizeBytes,
      if (showFacts && observed.sha256 != null) 'sha256': observed.sha256,
      if (magic != null && showFacts && !observed.unreadable)
        'magicOk': _startsWith(observed.header, magic),
      if (problem != null) 'problem': problem!.wire,
    };
  }
}

/// Result of checking every expected file.
class ExpectedOutputsResult {
  const ExpectedOutputsResult(this.checks);

  final List<ExpectedFileCheck> checks;

  bool get ok => checks.every((c) => c.ok);

  /// `expected_output_missing` when any file is missing / not a file / too
  /// small, else `expected_output_mismatch` when any other check failed, else
  /// null.
  String? get errorCode {
    final failed = checks.where((c) => !c.ok).toList();
    if (failed.isEmpty) return null;
    return failed.any((c) => c.problem!.errorCode == expectedOutputMissing)
        ? expectedOutputMissing
        : expectedOutputMismatch;
  }

  List<Map<String, Object?>> get artifacts =>
      <Map<String, Object?>>[for (final c in checks) c.toJson()];
}

bool _startsWith(List<int> header, List<int> prefix) {
  if (header.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (header[i] != prefix[i]) return false;
  }
  return true;
}

/// Decides each [specs] entry against the matching [observed] entry (same
/// order and length).
ExpectedOutputsResult evaluateExpectedFiles(
  List<ExpectedFileSpec> specs,
  List<ObservedExpectedFile> observed,
) {
  if (specs.length != observed.length) {
    throw ArgumentError('specs and observed must have the same length');
  }
  final checks = <ExpectedFileCheck>[];
  for (var i = 0; i < specs.length; i++) {
    final spec = specs[i];
    final o = observed[i];
    checks.add(
      ExpectedFileCheck(spec: spec, observed: o, problem: _problem(spec, o)),
    );
  }
  return ExpectedOutputsResult(checks);
}

ExpectedFileProblem? _problem(ExpectedFileSpec spec, ObservedExpectedFile o) {
  if (o.forbidden) return ExpectedFileProblem.forbidden;
  if (!o.exists) return ExpectedFileProblem.missing;
  if (!o.isFile) return ExpectedFileProblem.notAFile;
  final size = o.sizeBytes;
  final minBytes = spec.minBytes;
  if (minBytes != null && (size == null || size < minBytes)) {
    return ExpectedFileProblem.tooSmall;
  }
  if (o.unreadable) {
    return spec.magic != null || spec.sha256 != null
        ? ExpectedFileProblem.unreadable
        : null;
  }
  final magic = spec.magic;
  if (magic != null && !_startsWith(o.header, magic)) {
    return ExpectedFileProblem.magicMismatch;
  }
  final expectedSha = spec.sha256;
  if (expectedSha != null) {
    if (o.sha256 == null) return ExpectedFileProblem.tooLargeToHash;
    if (o.sha256 != expectedSha) return ExpectedFileProblem.sha256Mismatch;
  }
  return null;
}
