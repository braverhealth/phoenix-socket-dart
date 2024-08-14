import 'dart:async';
import 'dart:math';

final _random = Random();

final class SocketConnectionAttempt {
  // Created a socket connection attempt whose delayFuture will complete after
  // the given delay.
  SocketConnectionAttempt({required Duration delay}) {
    _delayTimer = Timer(delay, () {
      if (!_delayCompleter.isCompleted) {
        _delayCompleter.complete();
      }
    });
  }

  final int _id = _random.nextInt(1 << 32);
  late final idAsString = _id.toRadixString(16).padLeft(8, '0');

  late Timer _delayTimer;
  final Completer<void> _delayCompleter = Completer();

  /// Whether the delayFuture has completed with either succesfully or with an
  /// error.
  bool get delayDone => _delayCompleter.isCompleted;

  // Future that completes successfully when the delay connection attempt should
  // be performed.
  late final Future<void> delayFuture = _delayCompleter.future;

  // Immediately successfully completes [delayFuture]. Has no effect if the
  // future was already completed.
  void skipDelay() {
    if (_delayTimer.isActive) {
      _delayTimer.cancel();
    }
    if (!_delayCompleter.isCompleted) {
      _delayCompleter.complete();
    }
  }

  // Immediately completes [delayFuture] with an error. Has no effect if the
  // future was already completed.
  void abort() {
    if (_delayTimer.isActive) {
      _delayTimer.cancel();
    }
    if (!_delayCompleter.isCompleted) {
      _delayCompleter.completeError(
        'Connection attempt $idAsString aborted.',
        StackTrace.current,
      );
    }
  }

  @override
  bool operator ==(Object other) {
    return other is SocketConnectionAttempt && _id == other._id;
  }

  @override
  int get hashCode => _id.hashCode;

  @override
  String toString() {
    return 'SocketConnectionAttempt(id: $idAsString)';
  }
}
