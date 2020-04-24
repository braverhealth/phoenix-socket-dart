import 'dart:async';

import 'package:logging/logging.dart';
import 'package:quiver/collection.dart';
import 'package:equatable/equatable.dart';

import 'channel.dart';
import 'events.dart';
import 'exception.dart';
import 'message.dart';

/// Encapsulates the response to a [Push].
class PushResponse implements Equatable {
  /// Status provided by the backend.
  ///
  /// Value is usually either 'ok' or 'error'.
  final String status;

  /// Arbitrary JSON content provided by the backend.
  final dynamic response;

  /// Builds a PushResponse from a status and response.
  PushResponse({
    this.status,
    this.response,
  });

  /// Builds a PushResponse from a Map payload.
  ///
  /// Standard is such that the message payload should
  /// be something like
  ///
  /// ```
  /// {
  ///   status: "ok",
  ///   response: {
  ///     foo: "bar"
  ///   }
  /// }
  /// ```
  factory PushResponse.fromMessage(Message message) {
    final data = message.payload;
    return PushResponse(
      status: data['status'] as String,
      response: data['response'],
    );
  }

  /// Whether the response as a 'ok' status.
  bool get isOk => status == 'ok';

  /// Whether the response as a 'error' status.
  bool get isError => status == 'error';

  /// Whether the response as a 'error' status.
  bool get isTimeout => status == 'timeout';

  @override
  List<Object> get props => [status, response];

  @override
  bool get stringify => true;
}

typedef PayloadGetter = Map<String, dynamic> Function();

class Push {
  final Logger _logger;
  final PhoenixChannelEvent event;
  final PayloadGetter payload;
  final PhoenixChannel _channel;
  final ListMultimap<String, void Function(PushResponse)> _receivers =
      ListMultimap();

  Duration timeout;
  PushResponse _received;
  bool _sent = false;
  bool _awaitingReply = false;
  Timer _timeoutTimer;
  String _ref;
  PhoenixChannelEvent _replyEvent;

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
  })  : _channel = channel,
        _logger = Logger('phoenix_socket.push.${channel.loggerName}');

  bool get sent => _sent;

  String get ref => _ref ??= _channel.socket.nextRef;

  void _resetRef() {
    _ref = null;
    _replyEvent = null;
  }

  PhoenixChannelEvent get replyEvent =>
      _replyEvent ??= PhoenixChannelEvent.replyFor(ref);

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
    _received = null;
    _resetRef();
    _sent = false;
    _responseCompleter = null;
  }

  void clearWaiters() {
    _receivers.clear();
    _responseCompleter = null;
  }

  void trigger(PushResponse response) {
    _received = response;

    if (_responseCompleter != null) {
      if (_responseCompleter.isCompleted) {
        _logger.warning('Push being completed more than once');
        _logger.warning(
          () => '  event: $replyEvent, status: ${response.status}',
        );
        _logger.finer(
          () => '  response: ${response.response}',
        );
        return;
      } else {
        _logger.finer(
          () => 'Completing for $replyEvent with response ${response.response}',
        );
        _responseCompleter.complete(response);
      }
    }
    _logger.finer(() {
      if (_receivers[response.status].isNotEmpty) {
        return 'Triggering ${_receivers[response.status].length} callbacks';
      }
      return 'Not triggering any callbacks';
    });
    for (final cb in _receivers[response.status]) {
      cb(response);
    }
    clearWaiters();
  }

  void _receiveResponse(dynamic response) {
    cancelTimeout();
    if (response is Message) {
      if (response.event == replyEvent) {
        trigger(PushResponse.fromMessage(response));
      }
    } else if (response is PhoenixException) {
      if (_responseCompleter is Completer && !_responseCompleter.isCompleted) {
        _responseCompleter.completeError(response);
        clearWaiters();
      }
    }
  }

  void startTimeout() {
    if (!_awaitingReply) {
      _channel.onPushReply(replyEvent)
        ..then(_receiveResponse)
        ..catchError(_receiveResponse);
      _awaitingReply = true;
    }

    _timeoutTimer ??= Timer(timeout, () {
      _timeoutTimer = null;
      _logger.warning('Push $ref timed out');
      _channel.trigger(Message.timeoutFor(ref));
    });
  }

  Future<void> send() async {
    if (_received is PushResponse && _received.isTimeout) {
      _logger.warning('Trying to send push $ref after timeout');
      return;
    }
    _logger.finer('Sending out push for $ref');
    _sent = true;
    _awaitingReply = false;

    startTimeout();
    try {
      await _channel.socket.sendMessage(Message(
        event: event,
        topic: _channel.topic,
        payload: payload(),
        ref: ref,
        joinRef: _channel.joinRef,
      ));
      // ignore: avoid_catches_without_on_clauses
    } catch (err, stacktrace) {
      _logger.warning(
        'Catched error for push $ref',
        err,
        stacktrace,
      );
      _receiveResponse(err);
    }
  }

  Future<void> resend(Duration newTimeout) async {
    timeout = newTimeout ?? timeout;
    reset();
    await send();
  }
}
