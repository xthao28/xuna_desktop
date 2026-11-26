import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Checks `exec.run` `expectFiles` on disk after the command exited 0
/// (upgrade plan P1.1 / U3, `XUNA_XTP_V1_CONTRACT.md` §8).
///
/// Every path is normalized and its real path re-checked right before it is
/// read: a target that now resolves into a Hard-Deny location or a secret
/// file (e.g. a symlink the command created) is reported `forbidden` without
/// size or hash. Files up to [expectFilesMaxHashBytes] are hashed.
Future<ExecOutputCheck> verifyExpectedFiles(
  List<ExpectedFileSpec> specs, {
  String? homeDirectory,
  bool? windows,
  String? Function(String normalizedPath)? realPath,
}) async {
  final isWindows = windows ?? Platform.isWindows;
  final home = homeDirectory ?? hostHomeDirectory();
  final resolve = realPath ?? resolveHostRealPath;
  final observed = <ObservedExpectedFile>[];
  for (final spec in specs) {
    final normalized = normalizeHostPath(
      spec.path,
      homeDirectory: home,
      windows: isWindows,
    );
    observed.add(
      normalized == null
          ? const ObservedExpectedFile.missing()
          : await _observe(normalized, resolve),
    );
  }
  final result = evaluateExpectedFiles(specs, observed);
  return ExecOutputCheck(
    artifacts: result.artifacts,
    errorCode: result.errorCode,
  );
}

bool _forbidden(String path) =>
    hardDeniedPathReason(path) != null || isSecretFileName(path);

Future<ObservedExpectedFile> _observe(
  String path,
  String? Function(String normalizedPath) realPath,
) async {
  final real = realPath(path);
  if (_forbidden(path) || (real != null && _forbidden(real))) {
    return const ObservedExpectedFile.forbidden();
  }
  final FileSystemEntityType type;
  try {
    type = await FileSystemEntity.type(path);
  } on FileSystemException {
    return const ObservedExpectedFile.missing();
  }
  if (type == FileSystemEntityType.notFound) {
    return const ObservedExpectedFile.missing();
  }
  if (type != FileSystemEntityType.file) {
    return const ObservedExpectedFile.notAFile();
  }
  final file = File(path);
  final int size;
  try {
    size = await file.length();
  } on FileSystemException {
    return const ObservedExpectedFile.unreadable();
  }
  try {
    final raf = await file.open();
    final List<int> header;
    try {
      header = await raf.read(expectFilesMaxMagicBytes);
    } finally {
      await raf.close();
    }
    final String? hash = size <= expectFilesMaxHashBytes
        ? (await sha256.bind(file.openRead()).first).toString()
        : null;
    return ObservedExpectedFile.file(
      sizeBytes: size,
      header: header,
      sha256: hash,
    );
  } on FileSystemException {
    return ObservedExpectedFile.unreadable(sizeBytes: size);
  }
}
