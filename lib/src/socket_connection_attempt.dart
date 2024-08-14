import 'dart:async';
import 'dart:math';

final _random = Random();

sealed class SocketConnectionAttempt {
  SocketConnectionAttempt._();

  // Created a socket connection attempt whose delayFuture will complete after
  // the given delay.
  factory SocketConnectionAttempt({required Duration delay}) =>
      _DelayedSocketConnectionAttempt(delay: delay);

  // Creates a socket connection attempt whose delayFuture is completed with an
  // error.
  factory SocketConnectionAttempt.aborted() =>
      _AbortedSocketConnectionAttempt();

  final int _id = _random.nextInt(1 << 32);
  late final idAsString = _id.toRadixString(16).padLeft(8, '0');

  /// Whether the delayFuture has completed with either succesfully or with an
  /// error.
  bool get delayDone;

  // Future that completes successfully when the delay connection attempt should
  // be performed.
  Future<void> get delayFuture;

  // Immediately successfully completes [delayFuture]. Has no effect if the
  // future was already completed.
  void skipDelay();

  // Immediately completes [delayFuture] with an error. Has no effect if the
  // future was already completed.
  void abort();
}

final class _DelayedSocketConnectionAttempt extends SocketConnectionAttempt {
  _DelayedSocketConnectionAttempt({required Duration delay}) : super._() {
    _delayTimer = Timer(delay, () {
      if (!_delayCompleter.isCompleted) {
        _delayCompleter.complete();
      }
    });
  }

  late Timer _delayTimer;
  final Completer<void> _delayCompleter = Completer();
  @override
  late final Future<void> delayFuture = _delayCompleter.future;
  @override
  bool get delayDone => _delayCompleter.isCompleted;

  @override
  void skipDelay() {
    if (_delayTimer.isActive) {
      _delayTimer.cancel();
    }
    if (!_delayCompleter.isCompleted) {
      _delayCompleter.complete();
    }
  }

  @override
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
    return other is _DelayedSocketConnectionAttempt && _id == other._id;
  }

  @override
  int get hashCode => _id.hashCode;

  @override
  String toString() {
    return 'DelayedSocketConnectionAttempt(id: $idAsString)';
  }
}

final class _AbortedSocketConnectionAttempt extends SocketConnectionAttempt {
  _AbortedSocketConnectionAttempt() : super._();

  @override
  bool delayDone = false;

  @override
  late final Future<void> delayFuture =
      // Future.error completes after a microtask, so to be perfectly ok with
      // the superclass API, we set delayDone to true after the microtask is
      // done.
      Future.error('Attempt aborted').whenComplete(() => delayDone = true);

  @override
  void abort() {}

  @override
  void skipDelay() {}

  @override
  bool operator ==(Object other) {
    return other is _AbortedSocketConnectionAttempt && other._id == _id;
  }

  @override
  int get hashCode => _id.hashCode;
}
