import 'dart:async';

import 'package:quiver/collection.dart';
import 'package:equatable/equatable.dart';

import 'channel.dart';
import 'message.dart';

class PushResponse implements Equatable {
  final String status;
  final dynamic response;

  PushResponse({this.status, this.response});

  factory PushResponse.fromPayload(Map<String, dynamic> data) {
    return PushResponse(
      status: data["status"],
      response: data["response"],
    );
  }

  @override
  List<Object> get props => [status, response];
}

class Push {
  final String event;
  final dynamic Function() payload;

  static String replyEventName(ref) => 'chan_reply_$ref';

  Duration timeout;
  PushResponse _received;
  PhoenixChannel _channel;
  bool _sent = false;
  ListMultimap<String, Completer<PushResponse>> _receivers = ListMultimap();
  Timer _timeoutTimer;
  String _ref;

  String get ref {
    _ref ??= _channel.socket.makeRef();
    return _ref;
  }

  Push(
    PhoenixChannel channel, {
    this.event,
    this.payload,
    this.timeout,
  }) : _channel = channel;

  bool get sent => _sent;
  String get _replyEvent => replyEventName(ref);

  bool hasReceived(String status) => _received.status == status;

  Future<PushResponse> onReply(String status) {
    if (status == _received.status) {
      return Future.value(_received.response);
    }
    Completer<PushResponse> completer = Completer();
    _receivers[status].add(completer);
    return completer.future;
  }

  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void reset() {
    cancelTimeout();
    _channel.removeWaiters(_replyEvent);
    _received = null;
    _ref = null;
    _sent = false;
  }

  void trigger(PushResponse response) {
    _received = response;
    for (var completer in _receivers[response.status]) {
      completer.complete(response);
    }
  }

  void startTimeout() {
    _channel.onPushReply(_replyEvent).then((Message response) {
      if (response is Message) {
        cancelTimeout();
        trigger(PushResponse.fromPayload(response.payload));
      }
    });
    _timeoutTimer = Timer(timeout, () {
      _timeoutTimer = null;
      _channel.trigger(Message(
        event: _replyEvent,
        payload: {
          "status": "timeout",
          "response": {},
        },
      ));
    });
  }

  void send() async {
    if (hasReceived("timeout")) return;
    _sent = true;

    _channel.socket.sendMessage(Message(
      event: event,
      topic: _channel.topic,
      payload: payload(),
      ref: ref,
      joinRef: _channel.joinRef,
    ));
    startTimeout();
  }

  void resend(Duration newTimeout) {
    timeout = newTimeout ?? timeout;
    reset();
    send();
  }
}
