import 'dart:async';

import 'package:pedantic/pedantic.dart';
import 'package:quiver/collection.dart';

import 'message.dart';
import 'push.dart';
import 'socket.dart';

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

  String get reference {
    _reference ??= _socket.nextRef;
    return _reference;
  }

  Future<Message> onPushReply(replyRef) {
    var completer = Completer<Message>();
    _waiters[replyRef].add(completer);
    return completer.future;
  }

  void removeWaiters(replyRef) {
    _waiters.removeAll(replyRef);
  }

  void dispose() {
    pushBuffer.forEach((push) => push.cancelTimeout());
    _joinPush?.cancelTimeout();

    _subscriptions.forEach((sub) => sub.cancel());
    _controller.close();
    _waiters.clear();
  }

  void trigger(Message message) => _controller.add(message);

  void triggerError() {
    if (!(isErrored || isLeaving || isClosed)) {
      trigger(Message(event: PhoenixChannelEvents.error));
      _waiters.forEach((k, waiter) =>
          waiter.completeError(Message(event: PhoenixChannelEvents.error)));
      _waiters.clear();
    }
  }

  Push leave([Duration timeout]) {
    _joinPush?.cancelTimeout();
    _rejoinTimer?.cancel();

    _state = PhoenixChannelState.leaving;
    var leavePush = Push(
      this,
      event: PhoenixChannelEvents.leave,
      payload: () => {},
      timeout: timeout,
    );

    leavePush
      ..onReply('ok').then(_onClose)
      ..onReply('timeout').then(_onClose)
      ..send();

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

  Push push(String event, Map payload, [Duration newTimeout]) {
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
    var push = Push(
      this,
      event: PhoenixChannelEvents.join,
      payload: () => parameters,
      timeout: providedTimeout ?? timeout,
    );
    push
      ..onReply('ok').then((PushResponse response) {
        _state = PhoenixChannelState.joined;
        _rejoinTimer?.cancel();
        pushBuffer.forEach((push) => push.send());
        pushBuffer.clear();
      })
      ..onReply('error').then((PushResponse response) {
        _state = PhoenixChannelState.errored;
        if (socket.isConnected) {
          _startRejoinTimer();
        }
      })
      ..onReply('timeout').then((PushResponse response) {
        var leavePush = Push(
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
      _rejoinTimer?.cancel();
      _state = PhoenixChannelState.closed;
      socket.removeChannel(this);
    } else if (message.event == PhoenixChannelEvents.error) {
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
      _waiters[message.event]
          .forEach((completer) => completer.complete(message));
      removeWaiters(message.event);
    }
  }

  void _onClose(PushResponse response) {
    trigger(Message(
      event: PhoenixChannelEvents.close,
      payload: {'ok': 'leave'},
    ));
  }
}
