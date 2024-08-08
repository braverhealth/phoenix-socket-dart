import 'dart:async';
import 'dart:math';

final _random = Random();

final class SocketConnectionAttempt {
  SocketConnectionAttempt({required Duration delay}) {
    _delayTimer = Timer(delay, () {
      if (!_delayCompleter.isCompleted) {
        _delayCompleter.complete();
      }
    });
  }

  SocketConnectionAttempt.aborted() {
    _delayTimer = Timer(Duration.zero, () {});
    completionFuture.ignore();
    abort();
  }

  final AttemptId id = AttemptId();

  final Completer<void> _delayCompleter = Completer();
  Future<void> get completionFuture => _delayCompleter.future;
  bool get done => _delayCompleter.isCompleted;

  late Timer _delayTimer;

  void completeNow() {
    if (_delayTimer.isActive) {
      _delayTimer.cancel();
    }
    if (!_delayCompleter.isCompleted) {
      _delayCompleter.complete();
    }
  }

  void abort() {
    if (_delayTimer.isActive) {
      _delayTimer.cancel();
    }
    if (!_delayCompleter.isCompleted) {
      _delayCompleter.completeError(
        'Connection attempt ${id.toIdString()} aborted.',
        StackTrace.current,
      );
    }
  }
}

extension type AttemptId._(int id) {
  AttemptId() : this._(_random.nextInt(1 << 32));

  String toIdString() {
    return id.toRadixString(16).padLeft(8, '0');
  }

  bool equals(AttemptId other) {
    return other is int && other.id == id;
  }
}
