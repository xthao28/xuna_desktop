import 'dart:io';

/// Prevents multiple instances of the Desktop Agent from running concurrently
/// in the same user session (`UDC-3` §5.6.1).
///
/// Uses a local TCP loopback listener on a deterministic user port (or OS file
/// lock on [lockFile]) so a second process detects the active instance and
/// exits cleanly.
class SingleInstanceGuard {
  SingleInstanceGuard({required this.lockFile});

  final File lockFile;
  RandomAccessFile? _handle;

  bool get isLocked => _handle != null;

  /// Attempts to acquire an exclusive OS lock on [lockFile] without blocking.
  /// Returns `true` if this process is the primary instance, or `false` if
  /// another instance already holds the lock.
  Future<bool> tryAcquire() async {
    if (_handle != null) return true;
    try {
      await lockFile.parent.create(recursive: true);
      final raf = await lockFile.open(mode: FileMode.write);
      try {
        raf.lockSync(FileLock.exclusive);
      } on FileSystemException {
        await raf.close();
        return false;
      }
      await raf.truncate(0);
      await raf.writeString('$pid\n');
      await raf.flush();
      _handle = raf;
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Releases the lock when the agent exits.
  Future<void> release() async {
    final raf = _handle;
    _handle = null;
    if (raf == null) return;
    try {
      await raf.unlock();
    } on FileSystemException {
      // Ignore unlock errors on shutdown.
    }
    try {
      await raf.close();
    } on FileSystemException {
      // Ignore close errors on shutdown.
    }
  }
}
