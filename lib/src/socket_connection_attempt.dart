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

  final int _id = _random.nextInt(1 << 32);
  late final idAsString = _id.toRadixString(16).padLeft(8, '0');

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
