import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:logging/logging.dart';
import 'package:quiver/collection.dart';

import 'channel.dart';
import 'events.dart';
import 'exceptions.dart';
import 'message.dart';

/// Encapsulates the response to a [Push].
class PushResponse extends Equatable {
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
    final data = message.payload!;
    return PushResponse(
      status: data['status'] as String?,
      response: data['response'],
    );
  }

  /// Status provided by the backend.
  ///
  /// Value is usually either 'ok' or 'error'.
  final String? status;

  /// Arbitrary JSON content provided by the backend.
  final dynamic response;

  /// Whether the response as a 'ok' status.
  bool get isOk => status == 'ok';

  /// Whether the response as a 'error' status.
  bool get isError => status == 'error';

  /// Whether the response as a 'error' status.
  bool get isTimeout => status == 'timeout';

  @override
  List<Object?> get props => [status, response];

  @override
  bool get stringify => true;
}

/// Type of function that should return a push payload
typedef PayloadGetter = Map<String, dynamic> Function();

/// Object produced by [PhoenixChannel.push] to encapsulate
/// the message sent and its lifecycle.
class Push {
  /// Build a Push message from its content and associated channel.
  ///
  /// Prefer using [PhoenixChannel.push] instead of using this.
  Push(
    PhoenixChannel channel, {
    this.event,
    this.payload,
    this.timeout,
  })  : _channel = channel,
        _logger = Logger('phoenix_socket.push.${channel.loggerName}'),
        _responseCompleter = Completer<PushResponse>();

  final Logger _logger;
  final ListMultimap<String, void Function(PushResponse)> _receivers =
      ListMultimap();

  /// The event name associated with the pushed message
  final PhoenixChannelEvent? event;

  /// A getter function that yields the payload of the pushed message,
  /// usually a JSON object.
  final PayloadGetter? payload;

  /// Channel through which the message was sent.
  final PhoenixChannel _channel;

  /// The expected timeout, after which the push is considered failed.
  Duration? timeout;

  PushResponse? _received;
  bool _sent = false;
  bool _awaitingReply = false;
  Timer? _timeoutTimer;
  String? _ref;
  PhoenixChannelEvent? _replyEvent;

  Completer<PushResponse> _responseCompleter;

  /// A future that will yield the response to the original message.
  Future<PushResponse> get future async {
    final response = await _responseCompleter.future;
    if (response.isTimeout) {
      throw ChannelTimeoutException(response);
    }
    return response;
  }

  /// Indicates whether the push has been sent.
  bool get sent => _sent;

  /// The unique identifier of the message used throughout its lifecycle.
  String get ref => _ref ??= _channel.socket.nextRef;

  void _resetRef() {
    _ref = null;
    _replyEvent = null;
  }

  /// The event name of the expected reply coming from the Phoenix backend.
  PhoenixChannelEvent get replyEvent =>
      _replyEvent ??= PhoenixChannelEvent.replyFor(ref);

  /// Returns whether the given status was received from the backend as
  /// a reply.
  bool hasReceived(String status) => _received?.status == status;

  /// Send the push message.
  ///
  /// This also schedules the timeout to be triggered in the future.
  Future<void> send() async {
    if (_received is PushResponse && _received!.isTimeout) {
      _logger.warning('Trying to send push $ref after timeout');
      return;
    }
    _logger.finer('Sending out push for $ref');
    _sent = true;
    _awaitingReply = false;

    startTimeout();
    try {
      await _channel.socket.sendMessage(Message(
        event: event!,
        topic: _channel.topic,
        payload: payload!(),
        ref: ref,
        joinRef: _channel.joinRef,
      ));
      // ignore: avoid_catches_without_on_clauses
    } catch (err, stacktrace) {
      _logger.warning(
        'Caught error for push $ref',
        err,
        stacktrace,
      );
      _receiveResponse(err);
    }
  }

  /// Retry to send the push message.
  ///
  /// This is usually done automatically by the managing [PhoenixChannel]
  /// after a reconnection.
  Future<void> resend(Duration? newTimeout) async {
    timeout = newTimeout ?? timeout;
    if (_sent) {
      reset();
    }
    await send();
  }

  /// Associate a callback to be called if and when a reply with the given
  /// status is received.
  void onReply(
    String status,
    void Function(PushResponse) callback,
  ) {
    _receivers[status].add(callback);
  }

  /// Schedule a timeout to be triggered if no reply occurs
  /// within the expected time frame.
  void startTimeout() {
    if (!_awaitingReply) {
      _channel
          .onPushReply(replyEvent)
          .then<void>(_receiveResponse)
          .catchError(_receiveResponse);
      _awaitingReply = true;
    }

    _timeoutTimer ??= Timer(timeout!, () {
      _timeoutTimer = null;
      _logger.warning('Push $ref timed out');
      _channel.trigger(Message.timeoutFor(ref));
    });
  }

  /// Cancel the scheduled timeout for this push.
  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  /// Reset the scheduled timeout for this push.
  void reset() {
    cancelTimeout();
    _received = null;
    _resetRef();
    _sent = false;
  }

  /// Trigger the appropriate waiters and future associated for this push,
  /// given the provided response.
  ///
  /// This will only trigger the waiters associated with the response's status,
  /// e.g. 'ok' or 'error'.
  void trigger(PushResponse response) {
    _received = response;

    if (_responseCompleter.isCompleted) {
      _logger
        ..warning('Push being completed more than once')
        ..warning(
          () => '  event: $replyEvent, status: ${response.status}',
        )
        ..finer(
          () => '  response: ${response.response}',
        );

      return;
    } else {
      _logger.finer(
        () => 'Completing for $replyEvent with response ${response.response}',
      );
      _responseCompleter.complete(response);
    }

    _logger.finer(() {
      if (_receivers[response.status].isNotEmpty) {
        return 'Triggering ${_receivers[response.status].length} callbacks';
      }
      return 'Not triggering any callbacks';
    });

    final receivers = _receivers[response.status].toList();
    clearReceivers();
    for (final cb in receivers) {
      cb(response);
    }
  }

  /// Dispose the set of waiters associated with this push.
  void clearReceivers() {
    _receivers.clear();
  }

  // Remove existing waiters and reset completer
  void cleanUp() {
    if (_sent) {
      clearReceivers();
      _responseCompleter = Completer();
    }
  }

  void _receiveResponse(dynamic response) {
    cancelTimeout();
    if (response is Message) {
      if (response.event == replyEvent) {
        trigger(PushResponse.fromMessage(response));
      }
    } else {
      if (!_responseCompleter.isCompleted) {
        _responseCompleter.completeError(response);
        clearReceivers();
      }
    }
  }
}
