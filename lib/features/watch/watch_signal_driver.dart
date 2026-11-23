import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Content-free signal sample delivered by a [WatchSignalDriver] subscription.
class WatchSignalUpdate {
  const WatchSignalUpdate({
    required this.signal,
    required this.state,
    this.digestChanged = false,
    this.errorCode,
  });

  final WatchSignal signal;
  final WatchSignalState state;
  final bool digestChanged;
  final String? errorCode;
}

/// Active observation handle for one signal on one watch.
abstract interface class WatchSignalSubscription {
  bool get eventDriven;
  bool get fallbackUsed;
  Future<void> dispose();
}

/// Fail-closed startup or runtime exception thrown by a [WatchSignalDriver].
class WatchDriverException implements Exception {
  const WatchDriverException({required this.errorCode, this.message});

  final String errorCode;
  final String? message;

  @override
  String toString() =>
      'WatchDriverException(errorCode: $errorCode, message: $message)';
}

/// Port implemented by platform / browser / protocol watch drivers (AW-M4).
abstract interface class WatchSignalDriver {
  /// Signals supported by this driver.
  Set<WatchSignal> get supportedSignals;

  /// Starts observing [signal] for [watchId] and [target].
  ///
  /// Implementations MUST respect [releaseFocus] (never steal window focus)
  /// and fail closed by throwing [WatchDriverException] rather than fabricating
  /// `settled` or guessing missing targets.
  Future<WatchSignalSubscription> startSignal({
    required String watchId,
    required WatchSignal signal,
    required WatchTarget target,
    required bool releaseFocus,
    required void Function(WatchSignalUpdate update) onUpdate,
  });
}
