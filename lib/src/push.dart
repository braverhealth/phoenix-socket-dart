import 'dart:async';

import 'package:logging/logging.dart';
import 'package:quiver/collection.dart';
import 'package:equatable/equatable.dart';

import 'exception.dart';
import 'channel.dart';
import 'message.dart';

final Logger _logger = Logger('phoenix_socket.push');

class PushResponse implements Equatable {
  final String status;
  final dynamic response;

  PushResponse({this.status, this.response});

  factory PushResponse.fromPayload(Map<String, dynamic> data) {
    return PushResponse(
      status: data['status'] as String,
      response: data['response'],
    );
  }

  bool get isOk => status == 'ok';
  bool get isError => status == 'error';

  @override
  List<Object> get props => [status, response];

  @override
  bool get stringify => true;
}

typedef PayloadGetter = Map<String, dynamic> Function();

class Push {
  final String event;
  final PayloadGetter payload;
  final PhoenixChannel _channel;
  final ListMultimap<String, void Function(PushResponse)> _receivers =
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
    _responseCompleter ??= Completer<PushResponse>();
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

  void onReply(
    String status,
    void Function(PushResponse) callback,
  ) {
    _receivers[status].add(callback);
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

    if (_responseCompleter != null) {
      if (_responseCompleter.isCompleted) {
        _logger.warning('Push being completed more than once');
        _logger.warning('  event: $_replyEvent, status: ${response.status}');
        return;
      } else {
        _logger.finer(
          'Completing for $_replyEvent with response ${response.response}',
        );
        _responseCompleter.complete(response);
      }
    }
    _logger.finer(() {
      if (_receivers[response.status].isNotEmpty) {
        return 'Triggering ${_receivers[response.status].length}';
      }
      return null;
    });
    for (final cb in _receivers[response.status]) {
      cb(response);
    }
    _receivers.clear();
    _channel.removeWaiters(_replyEvent);
  }

  void _receiveResponse(dynamic response) {
    if (response is Message) {
      cancelTimeout();
      if (response.event == _replyEvent) {
        trigger(PushResponse.fromPayload(response.payload));
      }
    } else if (response is PhoenixException) {
      cancelTimeout();
      if (_responseCompleter is Completer) {
        _responseCompleter.completeError(response);
      }
    }
  }

  void startTimeout() {
    if (!_boundCompleter) {
      _channel.onPushReply(_replyEvent)
        ..then(_receiveResponse)
        ..catchError(_receiveResponse);
      _boundCompleter = true;
    }

    _timeoutTimer ??= Timer(timeout, () {
      _timeoutTimer = null;
      _logger.warning('Push $_ref timed out');
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
    if (hasReceived('timeout')) {
      _logger.warning('Trying to send push $_ref after timeout');
      return;
    }
    _sent = true;
    _boundCompleter = false;

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
