import 'dart:async';

import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Emergency stop ("Dừng XUNA") controller (`UDC-3` §5.6.5 & §7).
///
/// Triggered by:
/// - Global hotkey (`Ctrl+Alt+Shift+X` / `Cmd+Option+Shift+X`)
/// - Tray menu action `"Dừng XUNA"`
/// - Remote `xuna/stop` notification from the backend
///
/// When triggered:
/// 1. Marks [isStopped] = `true` (blocking new tool calls except `host.status`
///    with `xuna/status = "denied"`, `errorCode = "stopped"`).
/// 2. Invokes all registered in-flight cancellation callbacks immediately.
/// 3. Remains suspended until the owner explicitly calls [resumeFromTray].
class EmergencyStopController {
  EmergencyStopController({required ContentFreeLogger logger})
    : _logger = logger;

  final ContentFreeLogger _logger;
  final StreamController<bool> _stateChanges =
      StreamController<bool>.broadcast();
  final List<void Function(StopReason reason)> _cancelCallbacks =
      <void Function(StopReason reason)>[];

  bool _isStopped = false;
  StopReason? _lastReason;

  bool get isStopped => _isStopped;
  StopReason? get lastReason => _lastReason;
  Stream<bool> get stateChanges => _stateChanges.stream;

  /// Registers a callback invoked immediately whenever emergency stop fires.
  void addCancelListener(void Function(StopReason reason) callback) {
    _cancelCallbacks.add(callback);
  }

  void removeCancelListener(void Function(StopReason reason) callback) {
    _cancelCallbacks.remove(callback);
  }

  /// Activates emergency stop and aborts all in-flight invocations.
  void triggerStop(StopReason reason) {
    _isStopped = true;
    _lastReason = reason;
    _logger.warning('estop.triggered', <String, Object?>{
      'reason': reason.wire,
    });
    for (final callback in List<void Function(StopReason)>.of(
      _cancelCallbacks,
    )) {
      callback(reason);
    }
    if (!_stateChanges.isClosed) {
      _stateChanges.add(true);
    }
  }

  /// Resumes normal tool execution when the owner clicks `"Bật lại XUNA"` in
  /// the system tray.
  void resumeFromTray() {
    if (!_isStopped) return;
    _isStopped = false;
    _lastReason = null;
    _logger.info('estop.resumed');
    if (!_stateChanges.isClosed) {
      _stateChanges.add(false);
    }
  }

  Future<void> dispose() async {
    _cancelCallbacks.clear();
    await _stateChanges.close();
  }
}
