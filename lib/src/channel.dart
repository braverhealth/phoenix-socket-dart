import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';

import 'events.dart';
import 'exceptions.dart';
import 'message.dart';
import 'push.dart';
import 'socket.dart';

/// The different states a channel can be.
enum PhoenixChannelState {
  /// The channel is closed, after a normal leave.
  closed,

  /// The channel is errored.
  errored,

  /// The channel is joined and functional.
  joined,

  /// The channel is waiting for a reply to its 'join'
  /// request.
  joining,

  /// The channel is waiting for a reply to its 'leave'
  /// request.
  leaving,
}

/// A set of States where an error triggered by the parent
/// socket do not end up triggering an error on the channel.
const statesIgnoringErrors = {
  PhoenixChannelState.errored,
  PhoenixChannelState.leaving,
  PhoenixChannelState.closed,
};

/// Bi-directional and isolated communication channel shared between
/// differents clients through a common Phoenix server.
class PhoenixChannel {
  /// Build a PhoenixChannel from a [PhoenixSocket].
  PhoenixChannel.fromSocket(
    this.socket, {
    required this.topic,
    Map<String, dynamic>? parameters,
    Duration? timeout,
  })  : _controller = StreamController.broadcast(),
        _waiters = {},
        parameters = parameters ?? {},
        _timeout = timeout ?? socket.defaultTimeout {
    _joinPush = _prepareJoin();
    _logger = Logger('phoenix_socket.channel.$loggerName');
    _subscriptions
      ..add(_controller.stream.listen(_onMessage))
      ..addAll(_subscribeToSocketStreams(socket));
  }

  /// Parameters passed to the backend at join time.
  final Map<String, dynamic> parameters;

  /// The [PhoenixSocket] through which this channel is established.
  final PhoenixSocket socket;

  final StreamController<Message> _controller;
  final Map<PhoenixChannelEvent, Completer<Message>> _waiters;
  final List<StreamSubscription> _subscriptions = [];

  /// The name of the topic to which this channel will bind.
  final String topic;

  Duration _timeout;
  PhoenixChannelState _state = PhoenixChannelState.closed;
  Timer? _rejoinTimer;
  bool _joinedOnce = false;
  String? _reference;
  late Push _joinPush;
  Push? _leavePush;
  late Logger _logger;

  /// A list of push to be sent out once the channel is joined.
  final List<Push> pushBuffer = [];

  /// Stream of all messages coming through this channel from the backend.
  Stream<Message> get messages => _controller.stream.where(
        (message) => !message.event.isReply || message.event.isChannelReply,
      );

  /// Unique identifier of the 'join' push message.
  String get joinRef => _joinPush.ref;

  Push? get leavePush => _leavePush;

  /// State of the channel.
  PhoenixChannelState get state => _state;

  /// Whether the channel can send messages.
  bool get canPush =>
      socket.isConnected && _state == PhoenixChannelState.joined;

  String? _loggerName;

  /// The name of the logger associated to this channel.
  String get loggerName => _loggerName ??= topic.replaceAll(
      RegExp(
        r'[:,*&?!@#$%]',
      ),
      '_');

  /// This channel's unique numeric reference.
  String get reference => _reference ??= socket.nextRef;

  /// Returns a future that will complete (or throw) when the provided
  /// reply arrives (or throws).
  Future<Message> onPushReply(PhoenixChannelEvent replyEvent) {
    if (_waiters.containsKey(replyEvent)) {
      _logger.finer(
        () => 'Removing previous waiter for $replyEvent',
      );
      _waiters.remove(replyEvent);
    }
    _logger.finer(
      () => 'Hooking on channel $topic for reply to $replyEvent',
    );
    final completer = Completer<Message>();
    _waiters[replyEvent] = completer;
    completer.future.whenComplete(() => _waiters.remove(replyEvent));
    return completer.future;
  }

  /// Close this channel.
  ///
  /// As a side effect, this method also remove this channel from
  /// the encompassing [PhoenixSocket].
  void close() {
    if (_state == PhoenixChannelState.closed) {
      return;
    }
    _state = PhoenixChannelState.closed;

    for (final push in pushBuffer) {
      push.cancelTimeout();
    }
    for (final sub in _subscriptions) {
      sub.cancel();
    }

    _joinPush.cancelTimeout();

    _controller.close();
    _waiters.clear();
    socket.removeChannel(this);
  }

  /// Trigger the reception of a message.
  void trigger(Message message) {
    if (!_controller.isClosed) {
      _controller.add(message);
    }
  }

  /// Trigger an error on this channel.
  void triggerError(PhoenixException error) {
    _logger.fine('Receiving error on channel', error);
    if (!statesIgnoringErrors.contains(_state)) {
      if (error.message != null) {
        trigger(error.message!);
      }

      _logger.warning('Got error on channel', error);

      for (final waiter in _waiters.values) {
        waiter.completeError(error);
      }
      _waiters.clear();

      final prevState = _state;
      _state = PhoenixChannelState.errored;
      if (prevState == PhoenixChannelState.joining) {
        _joinPush.reset();
      }

      if (socket.isConnected) {
        _startRejoinTimer();
      }
    }
  }

  /// Leave this channel.
  Push leave({Duration? timeout}) {
    _joinPush.cancelTimeout();
    _rejoinTimer?.cancel();

    final prevState = _state;
    _state = PhoenixChannelState.leaving;

    final currentLeavePush = _leavePush ??= Push(
      this,
      event: PhoenixChannelEvent.leave,
      payload: () => {},
      timeout: timeout ?? _timeout,
    );

    if (!socket.isConnected || prevState != PhoenixChannelState.joined) {
      currentLeavePush.trigger(PushResponse(status: 'ok'));
    } else {
      void onClose(PushResponse reply) {
        _onClose(reply);
        close();
      }

      currentLeavePush
        ..onReply('ok', onClose)
        ..onReply('timeout', onClose)
        ..send();
    }

    return currentLeavePush;
  }

  /// Join this channel using the associated [PhoenixSocket].
  Push join([Duration? newTimeout]) {
    assert(!_joinedOnce);

    if (newTimeout != null) {
      _timeout = newTimeout;
    }

    _joinedOnce = true;
    if (socket.isConnected) {
      _attemptJoin();
    } else {
      _state = PhoenixChannelState.errored;
    }

    return _joinPush;
  }

  /// Push a message to the Phoenix server.
  Push push(
    /// The name of the message's event.
    ///
    /// This can be any string, as long as it matches with something
    /// expected on the backend implementation.
    String eventName,

    /// The message payload.
    ///
    /// This needs to be a JSON encodable object.
    Map<String, dynamic> payload, [
    /// Manually set timeout value for this push.
    ///
    /// If not provided, the default timeout will be used.
    Duration? newTimeout,
  ]) =>
      pushEvent(
        PhoenixChannelEvent.custom(eventName),
        payload,
        newTimeout,
      );

  /// Push a message with a valid [PhoenixChannelEvent] name.
  ///
  /// This variant is used internally for channel joining/leaving. Prefer
  /// using [push] instead.
  Push pushEvent(
    PhoenixChannelEvent event,
    Map<String, dynamic> payload, [
    Duration? newTimeout,
  ]) {
    assert(_joinedOnce);

    final pushEvent = Push(
      this,
      event: event,
      payload: () => payload,
      timeout: newTimeout ?? _timeout,
    );

    if (canPush) {
      pushEvent.send();
    } else {
      if (_state == PhoenixChannelState.closed) {
        throw ChannelClosedError('Can\'t push event on a closed channel');
      }

      pushBuffer.add(pushEvent);
    }

    return pushEvent;
  }

  List<StreamSubscription> _subscribeToSocketStreams(PhoenixSocket socket) {
    return [
      socket.streamForTopic(topic).where(_isMember).listen(_controller.add),
      socket.errorStream.listen(
        (error) => _rejoinTimer?.cancel(),
      ),
      socket.openStream.listen(
        (event) {
          _rejoinTimer?.cancel();
          if (_state == PhoenixChannelState.errored) {
            _attemptJoin();
          }
        },
      )
    ];
  }

  Push _prepareJoin([Duration? providedTimeout]) {
    final push = Push(
      this,
      event: PhoenixChannelEvent.join,
      payload: () => parameters,
      timeout: providedTimeout ?? _timeout,
    );
    _bindJoinPush(push);
    return push;
  }

  void _bindJoinPush(Push push) {
    push
      ..cleanUp()
      ..onReply('ok', (response) {
        _logger.finer("Join message was ok'ed");
        _state = PhoenixChannelState.joined;
        _rejoinTimer?.cancel();
        for (final push in pushBuffer) {
          push.send();
        }
        pushBuffer.clear();
      })
      ..onReply('error', (response) {
        _logger.warning('Join message got error response: $response');
        _state = PhoenixChannelState.errored;
        if (socket.isConnected) {
          _startRejoinTimer();
        }
      })
      ..onReply('timeout', (response) {
        _logger.warning('Join message timed out');

        Push(
          this,
          event: PhoenixChannelEvent.leave,
          payload: () => {},
          timeout: _timeout,
        ).send();

        _state = PhoenixChannelState.errored;
        _joinPush.reset();
        if (socket.isConnected) {
          _startRejoinTimer();
        }
      });
  }

  void _startRejoinTimer() {
    _rejoinTimer?.cancel();
    _rejoinTimer = Timer(_timeout, () {
      if (socket.isConnected) _attemptJoin();
    });
  }

  void _attemptJoin() {
    if (_state != PhoenixChannelState.leaving) {
      _state = PhoenixChannelState.joining;
      _bindJoinPush(_joinPush);
      unawaited(_joinPush.resend(_timeout));
    }
  }

  bool _isMember(Message message) {
    if (message.joinRef != null &&
        message.joinRef != _joinPush.ref &&
        PhoenixChannelEvent.statuses.contains(message.event)) {
      return false;
    }
    return true;
  }

  void _onMessage(Message message) {
    if (message.event == PhoenixChannelEvent.close) {
      _logger.finer('Closing channel $topic');
      _rejoinTimer?.cancel();
      close();
    } else if (message.event == PhoenixChannelEvent.error) {
      _logger.finer('Erroring channel $topic');
      if (_state == PhoenixChannelState.joining) {
        _joinPush.reset();
      }
      _state = PhoenixChannelState.errored;
      if (socket.isConnected) {
        _rejoinTimer?.cancel();
        _startRejoinTimer();
      }
    } else if (message.event == PhoenixChannelEvent.reply) {
      _controller.add(message.asReplyEvent());
    }

    final waiter = _waiters[message.event];
    if (waiter != null) {
      _logger.finer(
        () => 'Notifying waiter for ${message.event}',
      );
      waiter.complete(message);
    } else {
      _logger.finer(() => 'No waiter to notify for ${message.event}');
    }
  }

  void _onClose(PushResponse response) {
    _logger.finer('Leave message has completed');
    trigger(Message(
      event: PhoenixChannelEvent.close,
      payload: const <String, String>{'ok': 'leave'},
    ));
  }
}
