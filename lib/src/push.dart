import 'dart:async';

import 'package:quiver/collection.dart';
import 'package:equatable/equatable.dart';

import 'channel.dart';
import 'message.dart';

class PushResponse implements Equatable {
  final String status;
  final Map response;

  PushResponse({this.status, this.response});

  factory PushResponse.fromPayload(Map<String, dynamic> data) {
    return PushResponse(
      status: data['status'],
      response: data['response'],
    );
  }

  bool get isOk => status == 'ok';
  bool get isError => status == 'error';

  @override
  List<Object> get props => [status, response];
}

typedef PayloadGetter = Map Function();

class Push {
  final String event;
  final PayloadGetter payload;
  final PhoenixChannel _channel;
  final ListMultimap<String, Completer<PushResponse>> _receivers =
      ListMultimap();

  static String replyEventName(ref) => 'chan_reply_$ref';

  Duration timeout;
  PushResponse _received;
  bool _sent = false;
  bool _boundCompleter = false;
  Timer _timeoutTimer;
  String _ref;

  String get ref {
    _ref ??= _channel.socket.nextRef;
    return _ref;
  }

  Completer<PushResponse> _responseCompleter;
  Future<PushResponse> get future {
    _responseCompleter ??= Completer();
    return _responseCompleter.future;
  }

  Push(
    PhoenixChannel channel, {
    this.event,
    this.payload,
    this.timeout,
  }) : _channel = channel;

  bool get sent => _sent;
  String get _replyEvent => replyEventName(ref);

  bool hasReceived(String status) => _received?.status == status;

  Future<PushResponse> onReply(String status) {
    if (status == _received?.status) {
      return Future.value(_received);
    }
    var completer = Completer<PushResponse>();
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
    _responseCompleter?.complete(response);
    for (var completer in _receivers[response.status]) {
      completer.complete(response);
    }
  }

  void startTimeout() {
    if (!_boundCompleter) {
      _channel.onPushReply(_replyEvent).then((Message response) {
        if (response is Message) {
          cancelTimeout();
          trigger(PushResponse.fromPayload(response.payload));
        }
      });
      _boundCompleter = true;
    }

    _timeoutTimer = Timer(timeout, () {
      _timeoutTimer = null;
      _channel.trigger(Message(
        event: _replyEvent,
        payload: {
          'status': 'timeout',
          'response': {},
        },
      ));
    });
  }

  Future<void> send() async {
    if (hasReceived('timeout')) return;
    _sent = true;

    startTimeout();
    await _channel.socket.sendMessage(Message(
      event: event,
      topic: _channel.topic,
      payload: payload(),
      ref: ref,
      joinRef: _channel.joinRef,
    ));
  }

  Future<void> resend(Duration newTimeout) async {
    timeout = newTimeout ?? timeout;
    reset();
    await send();
  }
}
