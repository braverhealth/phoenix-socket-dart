import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../events.dart';
import '../exceptions.dart';
import '../message.dart';
import '../socket_options.dart';
import 'event.dart';
import 'state.dart';

final Logger _logger = Logger('phoenix_socket.ConnectionManager');

Future<Uri> _buildMountPoint(
  Uri serverUri,
  PhoenixSocketOptions options,
) async {
  final params = await options.getParams();
  final queryParams = serverUri.queryParameters.entries.toList()
    ..addAll(params.entries.toList());
  return serverUri.replace(
    queryParameters: Map.fromEntries(queryParams),
  );
}

class ConnectionManager {
  ConnectionManager({
    required String serverUri,
    WebSocketChannel Function(Uri uri)? webSocketChannelFactory,
  })  : _uri = Uri.parse(serverUri),
        _webSocketChannelFactory =
            webSocketChannelFactory ?? WebSocketChannel.connect {
    _openStream =
        _stateStreamController.stream.whereType<PhoenixSocketOpenEvent>();

    _closeStream =
        _stateStreamController.stream.whereType<PhoenixSocketCloseEvent>();

    _errorStream =
        _stateStreamController.stream.whereType<PhoenixSocketErrorEvent>();

    _eventSubject.stream.asyncMap(_handleEvent).listen((result) {
      final (event, newState) = result;
      if (newState == null) {
        _logger.fine('Ignored event $event');
        return;
      }

      final previousState = currentState;
      onState(event, previousState, newState);
    });
  }

  final Uri _uri;
  Uri? _lastConnectionUri;

  String get endpoint => _uri.toString();
  Uri get mountPoint => _lastConnectionUri ?? _uri;

  PhoenixSocketOptions? _options;

  final WebSocketChannel Function(Uri uri) _webSocketChannelFactory;
  final StreamController<ConnectionEvent> _eventSubject = StreamController();

  final StreamController<Message> _receiveStreamController =
      StreamController.broadcast();

  final BehaviorSubject<ConnectionState> _state =
      BehaviorSubject.seeded(DisconnectedState());

  final BehaviorSubject<PhoenixSocketEvent> _stateStreamController =
      BehaviorSubject();

  ConnectionState get currentState => _state.value;

  ValueStream<ConnectionState> get stateStream => _state.stream;

  late Stream<PhoenixSocketOpenEvent> _openStream;
  late Stream<PhoenixSocketCloseEvent> _closeStream;
  late Stream<PhoenixSocketErrorEvent> _errorStream;

  Stream<Message> get messageStream => _receiveStreamController.stream;
  Stream<Message> get topicStream => _receiveStreamController.stream
      .where((m) => m.topic != null && m.topic!.isNotEmpty);

  /// Stream of [PhoenixSocketOpenEvent] being produced whenever
  /// the connection is open.
  Stream<PhoenixSocketOpenEvent> get openStream => _openStream;

  /// Stream of [PhoenixSocketCloseEvent] being produced whenever
  /// the connection closes.
  Stream<PhoenixSocketCloseEvent> get closeStream => _closeStream;

  /// Stream of [PhoenixSocketErrorEvent] being produced in
  /// the lifetime of the [PhoenixSocket].
  Stream<PhoenixSocketErrorEvent> get errorStream => _errorStream;

  String get nextRef => switch (currentState) {
        ConnectedState(:final nextRef) ||
        ConnectingState(:final nextRef) ||
        ReconnectingState(:final nextRef) =>
          '$nextRef',
        _ => '0',
      };

  Future<void> connect(PhoenixSocketOptions options) async {
    late Completer returnedCompleter;

    switch (currentState) {
      case DisconnectedState():
        returnedCompleter = Completer();
        _add(
          Connect(
            options: options,
            completer: returnedCompleter,
          ),
        );

      case ConnectingState(:final completer) ||
            ReconnectingState(:final completer):
        returnedCompleter = completer;

      case ConnectedState():
        return Future.value();
    }

    return returnedCompleter.future;
  }

  Future<Message> waitForMessage(Message message) {
    final completer = Completer<Message>();
    _add(
      WaitFor(
        messageRef: message.ref!,
        completer: completer,
      ),
    );
    return completer.future;
  }

  void sendMessage(Message message) {
    _add(Send(
      message: message,
    ));
  }

  Null _waitForMessage(
    String messageRef, {
    required Completer<Message> completer,
  }) {
    switch (currentState) {
      case ConnectedState(:final pendingMessages):
        final existingFuture = pendingMessages[messageRef];
        if (existingFuture == null) {
          pendingMessages[messageRef] = completer;
        } else {
          completer.complete(existingFuture.future);
        }
        break;

      case ConnectingState(:final queuedMessages) ||
            ReconnectingState(:final queuedMessages):
        for (final (i, (queuedMessage, existingCompleter))
            in queuedMessages.indexed) {
          if (queuedMessage.ref == messageRef) {
            if (existingCompleter != null) {
              completer.complete(existingCompleter.future);
            } else {
              queuedMessages
                  .replaceRange(i, i + 1, [(queuedMessage, completer)]);
            }
            break;
          }
        }

        if (!completer.isCompleted) {
          completer.completeError(
            ArgumentError(
              "Message hasn't been sent using this socket.",
            ),
          );
        }
        break;

      default:
        completer.completeError(
          StateError(
            "Socket is closed so there is no message to wait for.",
          ),
        );
    }
    return null;
  }

  Null _sendMessage(
    Message message, {
    required Completer<Message>? completer,
    ConnectionState? state,
  }) {
    switch (state ?? currentState) {
      case ConnectedState(channel: final channel, :final pendingMessages):
        channel.sink.add(
          _options!.serializer.encode(message),
        );
        if (completer != null) {
          pendingMessages[message.ref!] = completer;
        }
        break;

      case ConnectingState(:final queuedMessages) ||
            ReconnectingState(:final queuedMessages):
        final completer = Completer<Message>();
        queuedMessages.add((message, completer));
        break;

      default:
        completer?.completeError(
          PhoenixException(
            message: 'Cannot send message while disconnected',
            socketClosed: PhoenixSocketCloseEvent(),
          ),
        );
    }
    return null;
  }

  void close({
    int? code,
    String? reason,
  }) {
    final oldState = currentState;
    if (currentState case ConnectedState(channel: final channel)) {
      onState(
        ChannelClosed(
          code: code,
          reason: reason,
          channel: channel,
        ),
        oldState,
        DisconnectedState(),
      );
      channel.sink.close(code, reason);
    } else {
      onState(
        ChannelClosed(
          code: code,
          reason: reason,
          channel: null,
        ),
        oldState,
        DisconnectedState(),
      );
    }

    final pendingCompleters = switch (oldState) {
      ConnectedState(:final pendingMessages) =>
        pendingMessages.entries.map((pair) => pair.value),
      ConnectingState(:final queuedMessages) ||
      ReconnectingState(:final queuedMessages) =>
        queuedMessages.map((pair) => pair.$2),
      _ => Iterable<Completer>.empty(),
    };

    for (final completer in pendingCompleters) {
      completer?.completeError(
        SocketClosedError(
          message: 'ConnectionManager was closed',
          socketClosed: PhoenixSocketCloseEvent(
            reason: reason,
            code: code,
          ),
        ),
      );
    }
  }

  void dispose() {
    close();

    _receiveStreamController.close();
    _stateStreamController.close();
    _eventSubject.close();
    _state.close();
  }

  bool isDisposed() => _state.isClosed;

  void onEvent(ConnectionEvent event) {
    _logger.fine(() => 'Handling event $event');
  }

  @mustCallSuper
  void onState(
    ConnectionEvent? event,
    ConnectionState previous,
    ConnectionState next,
  ) {
    _logger.fine(() => 'Moving to state $next');
    _state.add(next);

    switch (next) {
      case ConnectedState():
        _stateStreamController.add(
          PhoenixSocketOpenEvent(),
        );

      case DisconnectedState():
        if (event case ChannelError(:final error)) {
          _stateStreamController.add(
            PhoenixSocketCloseEvent(
              reason: error.toString(),
            ),
          );
        } else if (event case ChannelClosed(:final code)) {
          _stateStreamController.add(
            PhoenixSocketCloseEvent(code: code),
          );
        }

      case _:
        if (event case ChannelError(:final error, :final stackTrace)) {
          _stateStreamController.add(
            PhoenixSocketErrorEvent(
              error: error,
              stacktrace: stackTrace,
            ),
          );
        }
    }
  }

  Future<(ConnectionEvent, ConnectionState?)> _handleEvent(
    ConnectionEvent event,
  ) async {
    onEvent(event);

    return (
      event,
      switch (event) {
        Connect(options: final options, :final completer) =>
          await _connect(options, completer),
        Disconnect(:final code, :final reason) => await _disconnect(
            PhoenixSocketCloseEvent(
              reason: reason,
              code: code,
            ),
          ),
        ChannelClosed(channel: final channel) => await _channelClosed(channel),
        ChannelError(:final channel, :final error, :final stackTrace) =>
          await _channelError(channel, error, stackTrace),
        ChannelReady(channel: final channel) => await _channelReady(channel),
        ReceiveMessage(:final payload, :final channel) =>
          _receiveMessage(channel, payload),
        Send(:final message) => _sendMessage(message, completer: null),
        WaitFor(:final messageRef, :final completer) =>
          _waitForMessage(messageRef, completer: completer),
      },
    );
  }

  void _add(ConnectionEvent event) {
    if (!_eventSubject.isClosed) {
      _eventSubject.add(event);
    }
  }

  Future<WebSocketChannel> _createChannel(
    PhoenixSocketOptions? newOptions,
  ) async {
    if (newOptions != null) {
      _options = newOptions;
    }

    final mountPoint = await _buildMountPoint(_uri, _options!);
    _lastConnectionUri = mountPoint;

    final channel = _webSocketChannelFactory(mountPoint);
    try {
      channel.stream.where((message) {
        if (message is WebSocketChannelException) {
          return true;
        }
        return currentState is ConnectedState;
      }).listen(
        (message) {
          _add(
            ReceiveMessage(
              channel: channel,
              payload: message,
            ),
          );
        },
        cancelOnError: false,
        onError: (error, stackTrace) {
          _add(
            ChannelError(
              channel: channel,
              error: error,
              stackTrace: stackTrace,
            ),
          );
        },
        onDone: () {
          _add(
            ChannelClosed(
              channel: channel,
              code: channel.closeCode,
              reason: channel.closeReason,
            ),
          );
        },
      );
    } catch (error, stackTrace) {
      _add(
        ChannelError(
          channel: channel,
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }

    channel.ready.timeout(_options!.timeout).then((_) {
      _add(
        ChannelReady(channel: channel),
      );
    }).catchError((error, stackTrace) {
      _add(
        ChannelError(
          channel: channel,
          error: error,
          stackTrace: stackTrace,
        ),
      );
    });

    return channel;
  }

  Null _receiveMessage(WebSocketChannel channel, dynamic payload) {
    if (payload is String) {
      if (currentState case ConnectedState connectedState
          when connectedState.channel == channel) {
        final message = _options!.serializer.decode(payload);

        if (message.ref != null) {
          if (message.ref == connectedState.pendingHeartbeatRef) {
            connectedState.pendingHeartbeatRef = null;
          }

          connectedState.pendingMessages
            ..[message.ref]?.complete(message)
            ..remove(message.ref);
        }

        if (!_receiveStreamController.isClosed) {
          _receiveStreamController.add(message);
        }
      } else {
        throw ArgumentError('Received a non-string');
      }
    }
    return null;
  }

  Future<ConnectionState?> _connect(
    PhoenixSocketOptions options,
    Completer<void> completer,
  ) async {
    switch (currentState) {
      case DisconnectedState():
        return ConnectingState(
          channel: await _createChannel(options),
          reconnectionAttempts: 0,
          completer: completer,
        );

      case ConnectingState(completer: final existingCompleter) ||
            ReconnectingState(completer: final existingCompleter):
        existingCompleter.future
          ..then((_) {
            if (!completer.isCompleted) {
              completer.complete();
            }
          })
          ..catchError((error, stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          });
        return null;

      case ConnectedState():
        completer.complete();
        _logger.warning(
          () => 'Tried to connect while not being in the DisconnectedState',
        );
        return null;
    }
  }

  Future<ConnectionState?> _channelReady(WebSocketChannel channel) async {
    switch (currentState) {
      case ConnectingState(
                channel: final currentChannel,
                :final currentRef,
                :final queuedMessages,
                :final completer,
              ) ||
              ReconnectingState(
                channel: final currentChannel,
                :final currentRef,
                :final queuedMessages,
                :final completer,
              )
          when currentChannel == channel:
        final state = ConnectedState(
          channel: channel,
          startingRef: currentRef,
        );

        onState(
          ChannelReady(channel: channel),
          currentState,
          state,
        );

        for (final (message, completer) in queuedMessages) {
          _sendMessage(
            message,
            state: state,
            completer: completer,
          );
        }

        completer.complete();
        _scheduleHeartbeat(
          state,
          immediately: true,
        );

        return null;

      case _:
        return null;
    }
  }

  Future<ConnectionState?> _disconnect(
    PhoenixSocketCloseEvent closeEvent, [
    WebSocketChannel? channel,
  ]) async {
    switch (currentState) {
      case ConnectedState(channel: final currentChannel, :final pendingMessages)
          when channel == null || channel == currentChannel:
        currentChannel.sink.close();

        for (final completer in pendingMessages.values) {
          completer.completeError(
            SocketClosedError(
              message: 'Socket was closed'
                  ' (${currentChannel.closeReason}, ${currentChannel.closeCode})',
              socketClosed: closeEvent,
            ),
          );
        }

        if (_options!.shouldAttemptReconnection(0)) {
          final delay = _options!.getReconnectionDelay(0) ?? Duration.zero;
          await Future.delayed(delay);
          return ReconnectingState(
            channel: await _createChannel(_options!),
            completer: Completer(),
          );
        }

        return DisconnectedState();

      case ConnectingState(
                channel: final currentChannel,
                :final currentRef,
                :final queuedMessages,
                :final reconnectionAttempts,
                :final completer,
              ) ||
              ReconnectingState(
                channel: final currentChannel,
                :final currentRef,
                :final queuedMessages,
                :final reconnectionAttempts,
                :final completer,
              )
          when channel == null || channel == currentChannel:
        currentChannel.sink.close();

        if (_options!.shouldAttemptReconnection(reconnectionAttempts)) {
          final delay = _options!.getReconnectionDelay(reconnectionAttempts) ??
              Duration.zero;
          await Future.delayed(delay);

          return ReconnectingState(
            channel: await _createChannel(_options!),
            startingRef: currentRef,
            queuedMessages: queuedMessages,
            reconnectionAttempts: reconnectionAttempts + 1,
            completer: completer,
          );
        }

        completer.completeError(
          SocketClosedError(
            message: 'Maximum connection attempt reached without a'
                ' successful connection',
            socketClosed: closeEvent,
          ),
        );
        return DisconnectedState();

      case DisconnectedState():
        _logger.info(
          () => 'Tried to disconnect while being in the DisconnectedState',
        );
        return null;

      case _:
        return null;
    }
  }

  Future<ConnectionState?> _channelClosed(
    WebSocketChannel? channel,
  ) async {
    return _disconnect(
      PhoenixSocketCloseEvent(
        reason: channel?.closeReason,
        code: channel?.closeCode,
      ),
      channel,
    );
  }

  Future<ConnectionState?> _channelError(
    WebSocketChannel affectedChannel,
    Object error,
    StackTrace stackTrace,
  ) async {
    switch (currentState) {
      case ConnectedState(:final channel) ||
              ConnectingState(:final channel) ||
              ReconnectingState(:final channel)
          when channel == affectedChannel:
        _stateStreamController.add(
          PhoenixSocketErrorEvent(
            error: error,
            stacktrace: stackTrace,
          ),
        );

        if (channel.closeCode != null) {
          return _disconnect(
            PhoenixSocketCloseEvent(
              reason: channel.closeReason,
              code: channel.closeCode,
            ),
            channel,
          );
        }
      case _:
    }
    return null;
  }

  void _scheduleHeartbeat(
    ConnectedState state, {
    bool immediately = false,
  }) {
    if (state.heartbeatTimeout != null) {
      return;
    }

    state.heartbeatTimeout = Timer(
      immediately ? Duration.zero : _options!.heartbeat,
      () {
        state.heartbeatTimeout = null;
        if (currentState == state) {
          _sendHeartbeat(state);
        }
      },
    );
  }

  Future<bool> _sendHeartbeat(ConnectedState state) async {
    try {
      final completer = Completer<Message>();
      _sendMessage(state.heartbeatMessage(), completer: completer);
      await completer.future.timeout(_options!.heartbeatTimeout);
      if (currentState == state) {
        _scheduleHeartbeat(state);
      }
      return true;
    } on TimeoutException catch (err, stackTrace) {
      _logger.severe(
        () => 'Heartbeat message timed out',
        err,
        stackTrace,
      );

      if (state == currentState) {
        _add(
          ChannelClosed(
            channel: state.channel,
            code: normalClosure,
            reason: 'heartbeat timeout',
          ),
        );
      }
      return false;
    } catch (err, stackTrace) {
      if (currentState == state && state.channel.closeCode != null) {
        _add(
          ChannelClosed(
            channel: state.channel,
            code: normalClosure,
            reason: 'heartbeat timeout',
          ),
        );

        _logger.severe(
          () => 'Heartbeat message failed and socket is closed,'
              ' thus issueing a disconnection',
          err,
          stackTrace,
        );

        return false;
      }

      _logger.severe(
        () => 'Heartbeat message failed',
        err,
        stackTrace,
      );
      return false;
    }
  }
}
