import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';
import 'package:quiver/collection.dart';

import 'exception.dart';
import 'message.dart';
import 'push.dart';
import 'socket.dart';

/// Encapsulates constants used in the protocol over [PhoenixChannel].
class PhoenixChannelEvents {
  static String close = 'phx_close';
  static String error = 'phx_error';
  static String join = 'phx_join';
  static String reply = 'phx_reply';
  static String leave = 'phx_leave';

  static Set<String> statuses = {
    close,
    error,
    join,
    reply,
    leave,
  };
}

enum PhoenixChannelState {
  closed,
  errored,
  joined,
  joining,
  leaving,
}

/// Bi-directional and isolated communication channel shared between differents clients
/// through a common Phoenix server.
class PhoenixChannel {
  final Map<String, String> _parameters;
  final PhoenixSocket _socket;
  final StreamController<Message> _controller;
  final ListMultimap<String, Completer<Message>> _waiters;
  final List<StreamSubscription> _subscriptions = [];

  Duration _timeout;
  PhoenixChannelState _state = PhoenixChannelState.closed;
  Timer _rejoinTimer;
  bool _joinedOnce = false;
  String _reference;
  Push _joinPush;
  Logger _logger;

  String topic;
  final List<Push> pushBuffer = [];

  PhoenixChannel.fromSocket(
    this._socket, {
    this.topic,
    Map<String, String> parameters,
    Duration timeout,
  })  : _parameters = parameters ?? {},
        _controller = StreamController.broadcast(),
        _waiters = ListMultimap(),
        _timeout = timeout ?? _socket.defaultTimeout {
    _joinPush = _prepareJoin();
    _logger = Logger('phoenix_socket.channel.$loggerName');
    _subscriptions.add(messages.listen(_onMessage));
    _subscriptions.addAll(_subscribeToSocketStreams(_socket));
  }

  Duration get timeout => _timeout;
  Map<String, String> get parameters => _parameters;
  Stream<Message> get messages => _controller.stream;
  String get joinRef => _joinPush.ref;
  PhoenixSocket get socket => _socket;
  PhoenixChannelState get state => _state;

  bool get isClosed => _state == PhoenixChannelState.closed;
  bool get isErrored => _state == PhoenixChannelState.errored;
  bool get isJoined => _state == PhoenixChannelState.joined;
  bool get isJoining => _state == PhoenixChannelState.joining;
  bool get isLeaving => _state == PhoenixChannelState.leaving;

  bool get canPush => socket.isConnected && isJoined;

  String _loggerName;
  String get loggerName => _loggerName ??= topic.replaceAll(
      RegExp(
        '[:,*&?!@#\$%]',
      ),
      '_');

  String get reference {
    _reference ??= _socket.nextRef;
    return _reference;
  }

  Future<Message> onPushReply(replyRef) {
    final completer = Completer<Message>();
    _waiters[replyRef].add(completer);
    return completer.future;
  }

  void removeWaiters(replyRef) {
    _waiters.removeAll(replyRef);
  }

  void close() {
    if (_state == PhoenixChannelState.closed) {
      return;
    }
    _state = PhoenixChannelState.closed;

    pushBuffer.forEach((push) => push.cancelTimeout());
    _subscriptions.forEach((sub) => sub.cancel());

    _joinPush?.cancelTimeout();

    _controller.close();
    _waiters.clear();
    _socket.removeChannel(this);
  }

  void trigger(Message message) =>
      _controller.isClosed ? null : _controller.add(message);

  void triggerError(PhoenixException error) {
    _logger.fine('Receiving error on channel', error);
    if (!(isErrored || isLeaving || isClosed)) {
      trigger(error.message);
      _logger.warning('Got error on channel', error);
      _waiters.forEach((k, waiter) => waiter.completeError(error));
      _waiters.clear();
      _state = PhoenixChannelState.errored;
      if (isJoining) {
        _joinPush.reset();
      }
      if (socket.isConnected) {
        _startRejoinTimer();
      }
    }
  }

  Push leave([Duration timeout]) {
    _joinPush?.cancelTimeout();
    _rejoinTimer?.cancel();

    _state = PhoenixChannelState.leaving;

    final leavePush = Push(
      this,
      event: PhoenixChannelEvents.leave,
      payload: () => {},
      timeout: timeout,
    );

    leavePush
      ..onReply('ok', _onClose)
      ..onReply('timeout', _onClose)
      ..send().then((value) => close());

    if (!socket.isConnected || !isJoined) {
      leavePush.trigger(PushResponse(status: 'ok'));
    }

    return leavePush;
  }

  Push join([Duration newTimeout]) {
    assert(!_joinedOnce);

    if (newTimeout is Duration) {
      _timeout = newTimeout;
    }

    _joinedOnce = true;
    _attemptJoin();

    return _joinPush;
  }

  Push push(String event, Map<String, dynamic> payload, [Duration newTimeout]) {
    assert(_joinedOnce);

    final pushEvent = Push(
      this,
      event: event,
      payload: () => payload,
      timeout: newTimeout ?? timeout,
    );

    if (canPush) {
      pushEvent.send();
    } else {
      pushEvent.startTimeout();
      pushBuffer.add(pushEvent);
    }

    return pushEvent;
  }

  void rejoin() {
    _rejoinTimer?.cancel();
    _attemptJoin();
  }

  List<StreamSubscription> _subscribeToSocketStreams(PhoenixSocket socket) {
    return [
      socket.streamForTopic(topic).where(_isMember).listen(_controller.add),
      socket.errorStream.listen((error) => _rejoinTimer?.cancel()),
      socket.openStream.listen((event) {
        _rejoinTimer?.cancel();
        if (isErrored) {
          _attemptJoin();
        }
      })
    ];
  }

  Push _prepareJoin([Duration providedTimeout]) {
    final push = Push(
      this,
      event: PhoenixChannelEvents.join,
      payload: () => parameters,
      timeout: providedTimeout ?? timeout,
    );
    push
      ..onReply('ok', (PushResponse response) {
        _logger.finer("Join message was ok'ed");
        _state = PhoenixChannelState.joined;
        _rejoinTimer?.cancel();
        pushBuffer.forEach((push) => push.send());
        pushBuffer.clear();
      })
      ..onReply('error', (PushResponse response) {
        _logger.warning('Join message got error response', response);
        _state = PhoenixChannelState.errored;
        if (socket.isConnected) {
          _startRejoinTimer();
        }
      })
      ..onReply('timeout', (PushResponse response) {
        _logger.warning('Join message timed out');
        final leavePush = Push(
          this,
          event: PhoenixChannelEvents.leave,
          payload: () => {},
          timeout: timeout,
        );
        leavePush.send();
        _state = PhoenixChannelState.errored;
        _joinPush.reset();
        if (socket.isConnected) {
          _startRejoinTimer();
        }
      });

    return push;
  }

  void _startRejoinTimer() {
    _rejoinTimer?.cancel();
    _rejoinTimer = Timer(timeout, () {
      if (socket.isConnected) _attemptJoin();
    });
  }

  void _attemptJoin() {
    if (!isLeaving) {
      _state = PhoenixChannelState.joining;
      unawaited(_joinPush.resend(timeout));
    }
  }

  bool _isMember(Message message) {
    if (message.joinRef != null &&
        message.joinRef != _joinPush.ref &&
        PhoenixChannelEvents.statuses.contains(message.event)) {
      return false;
    }
    return true;
  }

  void _onMessage(Message message) {
    if (message.event == PhoenixChannelEvents.close) {
      _logger.finer('Closing channel $topic');
      _rejoinTimer?.cancel();
      close();
    } else if (message.event == PhoenixChannelEvents.error) {
      _logger.finer('Erroring channel $topic');
      if (isJoining) {
        _joinPush.reset();
      }
      _state = PhoenixChannelState.errored;
      if (socket.isConnected) {
        _rejoinTimer?.cancel();
        _startRejoinTimer();
      }
    } else if (message.event == PhoenixChannelEvents.reply) {
      _controller.add(message.asReplyEvent());
    }
    if (_waiters.containsKey(message.event)) {
      _waiters[message.event].forEach((completer) {
        completer.complete(message);
      });
      removeWaiters(message.event);
    }
  }

  void _onClose(PushResponse response) {
    _logger.finer('Leave message has completed');
    trigger(Message(
      event: PhoenixChannelEvents.close,
      payload: {'ok': 'leave'},
    ));
  }
}
