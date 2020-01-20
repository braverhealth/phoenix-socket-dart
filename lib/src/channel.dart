import 'dart:async';

import 'package:quiver/collection.dart';

import 'message.dart';
import 'push.dart';
import 'socket.dart';

class PhoenixChannelEvents {
  static String close = "phx_close";
  static String error = "phx_error";
  static String join = "phx_join";
  static String reply = "phx_reply";
  static String leave = "phx_leave";

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
  Map<String, String> parameters;
  PhoenixSocket _socket;
  StreamController<Message> _controller;
  PhoenixChannelState _state = PhoenixChannelState.closed;
  Timer _rejoinTimer;
  bool _joinedOnce = false;
  ListMultimap<String, Completer<Message>> _waiters;
  List<StreamSubscription> _subscriptions = [];
  String _reference;
  Push _joinPush;

  String topic;
  Duration timeout;
  List<Push> pushBuffer = List();

  PhoenixChannel.fromSocket(
    this._socket, {
    this.topic,
    Map<String, String> parameters,
    Duration timeout,
  })  : this.parameters = parameters ?? {},
        this._controller = StreamController.broadcast(),
        this._waiters = ListMultimap(),
        this.timeout = timeout ?? _socket.defaultTimeout {
    _joinPush = _prepareJoin();
    _subscriptions.add(messages.listen(_onMessage));
    _subscriptions.addAll(_subscribeToSocketStreams(this._socket));
  }

  bool get isClosed => _state == PhoenixChannelState.closed;
  bool get isErrored => _state == PhoenixChannelState.errored;
  bool get isJoined => _state == PhoenixChannelState.joined;
  bool get isJoining => _state == PhoenixChannelState.joining;
  bool get isLeaving => _state == PhoenixChannelState.leaving;

  bool get canPush => socket.isConnected && isJoined;

  String get joinRef => _joinPush.ref;
  PhoenixSocket get socket => _socket;
  PhoenixChannelState get state => _state;
  Stream<Message> get messages => _controller.stream;

  String get reference {
    _reference ??= _socket.makeRef();
    return _reference;
  }

  Future<Message> onPushReply(replyRef) {
    Completer<Message> completer = Completer();
    _waiters[replyRef].add(completer);
    return completer.future;
  }

  void removeWaiters(replyRef) {
    _waiters.removeAll(replyRef);
  }

  dispose() {
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
      timeout = newTimeout;
    }

    _joinedOnce = true;
    _attemptJoin();

    return _joinPush;
  }

  Push push(String event, dynamic payload, [Duration newTimeout]) {
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
      socket.messageStream.where(_isMember).listen(_controller.add),
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
      payload: () => this.parameters,
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
      _joinPush.resend(timeout);
    }
  }

  bool _isMember(Message message) {
    if (topic != message.topic) return false;

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
      this.socket.removeChannel(this);
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
      payload: "leave",
    ));
  }
}
