import 'dart:async';
import 'dart:math';

final _random = Random();

/// Like [Future.delayed], but allows some control of the delay before the
/// callback execution.
final class DelayedCallback<T> {
  /// Executes the provided [callback] after [delay] elapses, unless aborted
  /// during the delay.
  DelayedCallback({
    required Duration delay,
    required Future<T> Function() callback,
  }) : _callback = callback {
    _delayCompleter.future
        .then((_) => _runCallback())
        .catchError(_callbackCompleter.completeError);

    _delayTimer = Timer(delay, _delayCompleter.complete);
  }

  final int _id = _random.nextInt(1 << 32);
  late final idAsString = _id.toRadixString(16).padLeft(8, '0');

  late Timer _delayTimer;
  final _delayCompleter = Completer<void>();

  final Future<T> Function() _callback;
  bool _callbackRan = false;
  final _callbackCompleter = Completer<T>();

  /// Returns a future that is completed with result of callback execution.
  ///
  /// If the callback throws, then this future completes with the thrown error.
  ///
  /// If the callback gets aborted before execution, the future is completed
  /// with a custom error.
  late final Future<T> callbackFuture = _callbackCompleter.future;

  void _runCallback() {
    if (!_callbackRan) {
      _callbackRan = true;
      // This way the _callbackCompleter stays uncompleted until callback ends.
      _callback()
          .then(_callbackCompleter.complete)
          .catchError(_callbackCompleter.completeError);
    }
  }

  /// Whether the delay has expired. Does not guarantee that the callback was
  /// executed.
  bool get delayDone => !_delayTimer.isActive;

  /// Immediately skips delay and executes callback. Has no effect if the delay
  /// has expired already, or if the callback was aborted.
  void skipDelay() {
    if (_delayTimer.isActive) {
      _delayTimer.cancel();
    }
    if (!_delayCompleter.isCompleted) {
      _delayCompleter.complete();
    }
  }

  /// Aborts attempt at calling the callback. The [callbackFuture] is going to
  /// be completed with an error. Has no effect if the delay has expired
  /// already.
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
    return other is DelayedCallback && _id == other._id;
  }

  @override
  int get hashCode => _id.hashCode;

  @override
  String toString() {
    return 'SocketConnectionAttempt(id: $idAsString)';
  }
}
