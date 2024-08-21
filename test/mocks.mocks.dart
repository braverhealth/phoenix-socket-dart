// Mocks generated by Mockito 5.4.4 from annotations
// in phoenix_socket/test/mocks.dart.
// Do not manually edit this file.

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:async' as _i9;

import 'package:async/async.dart' as _i12;
import 'package:mockito/mockito.dart' as _i1;
import 'package:mockito/src/dummies.dart' as _i8;
import 'package:phoenix_socket/phoenix_socket.dart' as _i5;
import 'package:phoenix_socket/src/events.dart' as _i10;
import 'package:phoenix_socket/src/exceptions.dart' as _i11;
import 'package:phoenix_socket/src/message.dart' as _i3;
import 'package:phoenix_socket/src/push.dart' as _i4;
import 'package:phoenix_socket/src/socket.dart' as _i2;
import 'package:phoenix_socket/src/socket_connection.dart' as _i14;
import 'package:stream_channel/stream_channel.dart' as _i7;
import 'package:web_socket_channel/web_socket_channel.dart' as _i6;

import 'mocks.dart' as _i13;

// ignore_for_file: type=lint
// ignore_for_file: avoid_redundant_argument_values
// ignore_for_file: avoid_setters_without_getters
// ignore_for_file: comment_references
// ignore_for_file: deprecated_member_use
// ignore_for_file: deprecated_member_use_from_same_package
// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member
// ignore_for_file: prefer_const_constructors
// ignore_for_file: unnecessary_parenthesis
// ignore_for_file: camel_case_types
// ignore_for_file: subtype_of_sealed_class

class _FakePhoenixSocket_0 extends _i1.SmartFake implements _i2.PhoenixSocket {
  _FakePhoenixSocket_0(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeMessage_1 extends _i1.SmartFake implements _i3.Message {
  _FakeMessage_1(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakePush_2 extends _i1.SmartFake implements _i4.Push {
  _FakePush_2(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeDuration_3 extends _i1.SmartFake implements Duration {
  _FakeDuration_3(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakePhoenixChannel_4 extends _i1.SmartFake
    implements _i5.PhoenixChannel {
  _FakePhoenixChannel_4(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeWebSocketSink_5 extends _i1.SmartFake implements _i6.WebSocketSink {
  _FakeWebSocketSink_5(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeStreamChannel_6<T> extends _i1.SmartFake
    implements _i7.StreamChannel<T> {
  _FakeStreamChannel_6(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeMessageSerializer_7 extends _i1.SmartFake
    implements _i5.MessageSerializer {
  _FakeMessageSerializer_7(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

/// A class which mocks [PhoenixChannel].
///
/// See the documentation for Mockito's code generation for more information.
class MockPhoenixChannel extends _i1.Mock implements _i5.PhoenixChannel {
  @override
  Map<String, dynamic> get parameters => (super.noSuchMethod(
        Invocation.getter(#parameters),
        returnValue: <String, dynamic>{},
        returnValueForMissingStub: <String, dynamic>{},
      ) as Map<String, dynamic>);

  @override
  _i2.PhoenixSocket get socket => (super.noSuchMethod(
        Invocation.getter(#socket),
        returnValue: _FakePhoenixSocket_0(
          this,
          Invocation.getter(#socket),
        ),
        returnValueForMissingStub: _FakePhoenixSocket_0(
          this,
          Invocation.getter(#socket),
        ),
      ) as _i2.PhoenixSocket);

  @override
  String get topic => (super.noSuchMethod(
        Invocation.getter(#topic),
        returnValue: _i8.dummyValue<String>(
          this,
          Invocation.getter(#topic),
        ),
        returnValueForMissingStub: _i8.dummyValue<String>(
          this,
          Invocation.getter(#topic),
        ),
      ) as String);

  @override
  List<_i4.Push> get pushBuffer => (super.noSuchMethod(
        Invocation.getter(#pushBuffer),
        returnValue: <_i4.Push>[],
        returnValueForMissingStub: <_i4.Push>[],
      ) as List<_i4.Push>);

  @override
  _i9.Stream<_i3.Message> get messages => (super.noSuchMethod(
        Invocation.getter(#messages),
        returnValue: _i9.Stream<_i3.Message>.empty(),
        returnValueForMissingStub: _i9.Stream<_i3.Message>.empty(),
      ) as _i9.Stream<_i3.Message>);

  @override
  String get joinRef => (super.noSuchMethod(
        Invocation.getter(#joinRef),
        returnValue: _i8.dummyValue<String>(
          this,
          Invocation.getter(#joinRef),
        ),
        returnValueForMissingStub: _i8.dummyValue<String>(
          this,
          Invocation.getter(#joinRef),
        ),
      ) as String);

  @override
  _i5.PhoenixChannelState get state => (super.noSuchMethod(
        Invocation.getter(#state),
        returnValue: _i5.PhoenixChannelState.closed,
        returnValueForMissingStub: _i5.PhoenixChannelState.closed,
      ) as _i5.PhoenixChannelState);

  @override
  bool get canPush => (super.noSuchMethod(
        Invocation.getter(#canPush),
        returnValue: false,
        returnValueForMissingStub: false,
      ) as bool);

  @override
  String get loggerName => (super.noSuchMethod(
        Invocation.getter(#loggerName),
        returnValue: _i8.dummyValue<String>(
          this,
          Invocation.getter(#loggerName),
        ),
        returnValueForMissingStub: _i8.dummyValue<String>(
          this,
          Invocation.getter(#loggerName),
        ),
      ) as String);

  @override
  String get reference => (super.noSuchMethod(
        Invocation.getter(#reference),
        returnValue: _i8.dummyValue<String>(
          this,
          Invocation.getter(#reference),
        ),
        returnValueForMissingStub: _i8.dummyValue<String>(
          this,
          Invocation.getter(#reference),
        ),
      ) as String);

  @override
  _i9.Future<_i3.Message> onPushReply(_i10.PhoenixChannelEvent? replyEvent) =>
      (super.noSuchMethod(
        Invocation.method(
          #onPushReply,
          [replyEvent],
        ),
        returnValue: _i9.Future<_i3.Message>.value(_FakeMessage_1(
          this,
          Invocation.method(
            #onPushReply,
            [replyEvent],
          ),
        )),
        returnValueForMissingStub: _i9.Future<_i3.Message>.value(_FakeMessage_1(
          this,
          Invocation.method(
            #onPushReply,
            [replyEvent],
          ),
        )),
      ) as _i9.Future<_i3.Message>);

  @override
  void close() => super.noSuchMethod(
        Invocation.method(
          #close,
          [],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void trigger(_i3.Message? message) => super.noSuchMethod(
        Invocation.method(
          #trigger,
          [message],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void triggerError(_i11.PhoenixException? error) => super.noSuchMethod(
        Invocation.method(
          #triggerError,
          [error],
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i4.Push leave({Duration? timeout}) => (super.noSuchMethod(
        Invocation.method(
          #leave,
          [],
          {#timeout: timeout},
        ),
        returnValue: _FakePush_2(
          this,
          Invocation.method(
            #leave,
            [],
            {#timeout: timeout},
          ),
        ),
        returnValueForMissingStub: _FakePush_2(
          this,
          Invocation.method(
            #leave,
            [],
            {#timeout: timeout},
          ),
        ),
      ) as _i4.Push);

  @override
  _i4.Push join([Duration? newTimeout]) => (super.noSuchMethod(
        Invocation.method(
          #join,
          [newTimeout],
        ),
        returnValue: _FakePush_2(
          this,
          Invocation.method(
            #join,
            [newTimeout],
          ),
        ),
        returnValueForMissingStub: _FakePush_2(
          this,
          Invocation.method(
            #join,
            [newTimeout],
          ),
        ),
      ) as _i4.Push);

  @override
  _i4.Push push(
    String? eventName,
    Map<String, dynamic>? payload, [
    Duration? newTimeout,
  ]) =>
      (super.noSuchMethod(
        Invocation.method(
          #push,
          [
            eventName,
            payload,
            newTimeout,
          ],
        ),
        returnValue: _FakePush_2(
          this,
          Invocation.method(
            #push,
            [
              eventName,
              payload,
              newTimeout,
            ],
          ),
        ),
        returnValueForMissingStub: _FakePush_2(
          this,
          Invocation.method(
            #push,
            [
              eventName,
              payload,
              newTimeout,
            ],
          ),
        ),
      ) as _i4.Push);

  @override
  _i4.Push pushEvent(
    _i10.PhoenixChannelEvent? event,
    Map<String, dynamic>? payload, [
    Duration? newTimeout,
  ]) =>
      (super.noSuchMethod(
        Invocation.method(
          #pushEvent,
          [
            event,
            payload,
            newTimeout,
          ],
        ),
        returnValue: _FakePush_2(
          this,
          Invocation.method(
            #pushEvent,
            [
              event,
              payload,
              newTimeout,
            ],
          ),
        ),
        returnValueForMissingStub: _FakePush_2(
          this,
          Invocation.method(
            #pushEvent,
            [
              event,
              payload,
              newTimeout,
            ],
          ),
        ),
      ) as _i4.Push);
}

/// A class which mocks [PhoenixSocket].
///
/// See the documentation for Mockito's code generation for more information.
class MockPhoenixSocket extends _i1.Mock implements _i2.PhoenixSocket {
  @override
  Map<String, _i5.PhoenixChannel> get channels => (super.noSuchMethod(
        Invocation.getter(#channels),
        returnValue: <String, _i5.PhoenixChannel>{},
        returnValueForMissingStub: <String, _i5.PhoenixChannel>{},
      ) as Map<String, _i5.PhoenixChannel>);

  @override
  set channels(Map<String, _i5.PhoenixChannel>? _channels) =>
      super.noSuchMethod(
        Invocation.setter(
          #channels,
          _channels,
        ),
        returnValueForMissingStub: null,
      );

  @override
  Duration get defaultTimeout => (super.noSuchMethod(
        Invocation.getter(#defaultTimeout),
        returnValue: _FakeDuration_3(
          this,
          Invocation.getter(#defaultTimeout),
        ),
        returnValueForMissingStub: _FakeDuration_3(
          this,
          Invocation.getter(#defaultTimeout),
        ),
      ) as Duration);

  @override
  _i9.Stream<_i10.PhoenixSocketOpenEvent> get openStream => (super.noSuchMethod(
        Invocation.getter(#openStream),
        returnValue: _i9.Stream<_i10.PhoenixSocketOpenEvent>.empty(),
        returnValueForMissingStub:
            _i9.Stream<_i10.PhoenixSocketOpenEvent>.empty(),
      ) as _i9.Stream<_i10.PhoenixSocketOpenEvent>);

  @override
  _i9.Stream<_i10.PhoenixSocketCloseEvent> get closeStream =>
      (super.noSuchMethod(
        Invocation.getter(#closeStream),
        returnValue: _i9.Stream<_i10.PhoenixSocketCloseEvent>.empty(),
        returnValueForMissingStub:
            _i9.Stream<_i10.PhoenixSocketCloseEvent>.empty(),
      ) as _i9.Stream<_i10.PhoenixSocketCloseEvent>);

  @override
  _i9.Stream<_i10.PhoenixSocketErrorEvent> get errorStream =>
      (super.noSuchMethod(
        Invocation.getter(#errorStream),
        returnValue: _i9.Stream<_i10.PhoenixSocketErrorEvent>.empty(),
        returnValueForMissingStub:
            _i9.Stream<_i10.PhoenixSocketErrorEvent>.empty(),
      ) as _i9.Stream<_i10.PhoenixSocketErrorEvent>);

  @override
  _i9.Stream<_i3.Message> get messageStream => (super.noSuchMethod(
        Invocation.getter(#messageStream),
        returnValue: _i9.Stream<_i3.Message>.empty(),
        returnValueForMissingStub: _i9.Stream<_i3.Message>.empty(),
      ) as _i9.Stream<_i3.Message>);

  @override
  String get nextRef => (super.noSuchMethod(
        Invocation.getter(#nextRef),
        returnValue: _i8.dummyValue<String>(
          this,
          Invocation.getter(#nextRef),
        ),
        returnValueForMissingStub: _i8.dummyValue<String>(
          this,
          Invocation.getter(#nextRef),
        ),
      ) as String);

  @override
  bool get isOpen => (super.noSuchMethod(
        Invocation.getter(#isOpen),
        returnValue: false,
        returnValueForMissingStub: false,
      ) as bool);

  @override
  _i9.Stream<_i3.Message> streamForTopic(String? topic) => (super.noSuchMethod(
        Invocation.method(
          #streamForTopic,
          [topic],
        ),
        returnValue: _i9.Stream<_i3.Message>.empty(),
        returnValueForMissingStub: _i9.Stream<_i3.Message>.empty(),
      ) as _i9.Stream<_i3.Message>);

  @override
  _i9.Future<void> connect({bool? immediately = false}) => (super.noSuchMethod(
        Invocation.method(
          #connect,
          [],
          {#immediately: immediately},
        ),
        returnValue: _i9.Future<void>.value(),
        returnValueForMissingStub: _i9.Future<void>.value(),
      ) as _i9.Future<void>);

  @override
  void close([
    int? code,
    String? reason,
    dynamic reconnect = false,
  ]) =>
      super.noSuchMethod(
        Invocation.method(
          #close,
          [
            code,
            reason,
            reconnect,
          ],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void dispose() => super.noSuchMethod(
        Invocation.method(
          #dispose,
          [],
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i9.Future<_i3.Message> sendMessage(_i3.Message? message) =>
      (super.noSuchMethod(
        Invocation.method(
          #sendMessage,
          [message],
        ),
        returnValue: _i9.Future<_i3.Message>.value(_FakeMessage_1(
          this,
          Invocation.method(
            #sendMessage,
            [message],
          ),
        )),
        returnValueForMissingStub: _i9.Future<_i3.Message>.value(_FakeMessage_1(
          this,
          Invocation.method(
            #sendMessage,
            [message],
          ),
        )),
      ) as _i9.Future<_i3.Message>);

  @override
  _i5.PhoenixChannel addChannel({
    required String? topic,
    Map<String, dynamic>? parameters,
    Duration? timeout,
  }) =>
      (super.noSuchMethod(
        Invocation.method(
          #addChannel,
          [],
          {
            #topic: topic,
            #parameters: parameters,
            #timeout: timeout,
          },
        ),
        returnValue: _FakePhoenixChannel_4(
          this,
          Invocation.method(
            #addChannel,
            [],
            {
              #topic: topic,
              #parameters: parameters,
              #timeout: timeout,
            },
          ),
        ),
        returnValueForMissingStub: _FakePhoenixChannel_4(
          this,
          Invocation.method(
            #addChannel,
            [],
            {
              #topic: topic,
              #parameters: parameters,
              #timeout: timeout,
            },
          ),
        ),
      ) as _i5.PhoenixChannel);

  @override
  void removeChannel(_i5.PhoenixChannel? channel) => super.noSuchMethod(
        Invocation.method(
          #removeChannel,
          [channel],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void onSocketDataCallback(String? message) => super.noSuchMethod(
        Invocation.method(
          #onSocketDataCallback,
          [message],
        ),
        returnValueForMissingStub: null,
      );
}

/// A class which mocks [WebSocketChannel].
///
/// See the documentation for Mockito's code generation for more information.
class MockWebSocketChannel extends _i1.Mock implements _i6.WebSocketChannel {
  @override
  _i9.Future<void> get ready => (super.noSuchMethod(
        Invocation.getter(#ready),
        returnValue: _i9.Future<void>.value(),
        returnValueForMissingStub: _i9.Future<void>.value(),
      ) as _i9.Future<void>);

  @override
  _i9.Stream<dynamic> get stream => (super.noSuchMethod(
        Invocation.getter(#stream),
        returnValue: _i9.Stream<dynamic>.empty(),
        returnValueForMissingStub: _i9.Stream<dynamic>.empty(),
      ) as _i9.Stream<dynamic>);

  @override
  _i6.WebSocketSink get sink => (super.noSuchMethod(
        Invocation.getter(#sink),
        returnValue: _FakeWebSocketSink_5(
          this,
          Invocation.getter(#sink),
        ),
        returnValueForMissingStub: _FakeWebSocketSink_5(
          this,
          Invocation.getter(#sink),
        ),
      ) as _i6.WebSocketSink);

  @override
  void pipe(_i7.StreamChannel<dynamic>? other) => super.noSuchMethod(
        Invocation.method(
          #pipe,
          [other],
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i7.StreamChannel<S> transform<S>(
          _i7.StreamChannelTransformer<S, dynamic>? transformer) =>
      (super.noSuchMethod(
        Invocation.method(
          #transform,
          [transformer],
        ),
        returnValue: _FakeStreamChannel_6<S>(
          this,
          Invocation.method(
            #transform,
            [transformer],
          ),
        ),
        returnValueForMissingStub: _FakeStreamChannel_6<S>(
          this,
          Invocation.method(
            #transform,
            [transformer],
          ),
        ),
      ) as _i7.StreamChannel<S>);

  @override
  _i7.StreamChannel<dynamic> transformStream(
          _i9.StreamTransformer<dynamic, dynamic>? transformer) =>
      (super.noSuchMethod(
        Invocation.method(
          #transformStream,
          [transformer],
        ),
        returnValue: _FakeStreamChannel_6<dynamic>(
          this,
          Invocation.method(
            #transformStream,
            [transformer],
          ),
        ),
        returnValueForMissingStub: _FakeStreamChannel_6<dynamic>(
          this,
          Invocation.method(
            #transformStream,
            [transformer],
          ),
        ),
      ) as _i7.StreamChannel<dynamic>);

  @override
  _i7.StreamChannel<dynamic> transformSink(
          _i12.StreamSinkTransformer<dynamic, dynamic>? transformer) =>
      (super.noSuchMethod(
        Invocation.method(
          #transformSink,
          [transformer],
        ),
        returnValue: _FakeStreamChannel_6<dynamic>(
          this,
          Invocation.method(
            #transformSink,
            [transformer],
          ),
        ),
        returnValueForMissingStub: _FakeStreamChannel_6<dynamic>(
          this,
          Invocation.method(
            #transformSink,
            [transformer],
          ),
        ),
      ) as _i7.StreamChannel<dynamic>);

  @override
  _i7.StreamChannel<dynamic> changeStream(
          _i9.Stream<dynamic> Function(_i9.Stream<dynamic>)? change) =>
      (super.noSuchMethod(
        Invocation.method(
          #changeStream,
          [change],
        ),
        returnValue: _FakeStreamChannel_6<dynamic>(
          this,
          Invocation.method(
            #changeStream,
            [change],
          ),
        ),
        returnValueForMissingStub: _FakeStreamChannel_6<dynamic>(
          this,
          Invocation.method(
            #changeStream,
            [change],
          ),
        ),
      ) as _i7.StreamChannel<dynamic>);

  @override
  _i7.StreamChannel<dynamic> changeSink(
          _i9.StreamSink<dynamic> Function(_i9.StreamSink<dynamic>)? change) =>
      (super.noSuchMethod(
        Invocation.method(
          #changeSink,
          [change],
        ),
        returnValue: _FakeStreamChannel_6<dynamic>(
          this,
          Invocation.method(
            #changeSink,
            [change],
          ),
        ),
        returnValueForMissingStub: _FakeStreamChannel_6<dynamic>(
          this,
          Invocation.method(
            #changeSink,
            [change],
          ),
        ),
      ) as _i7.StreamChannel<dynamic>);

  @override
  _i7.StreamChannel<S> cast<S>() => (super.noSuchMethod(
        Invocation.method(
          #cast,
          [],
        ),
        returnValue: _FakeStreamChannel_6<S>(
          this,
          Invocation.method(
            #cast,
            [],
          ),
        ),
        returnValueForMissingStub: _FakeStreamChannel_6<S>(
          this,
          Invocation.method(
            #cast,
            [],
          ),
        ),
      ) as _i7.StreamChannel<S>);
}

/// A class which mocks [WebSocketSink].
///
/// See the documentation for Mockito's code generation for more information.
class MockWebSocketSink extends _i1.Mock implements _i6.WebSocketSink {
  @override
  _i9.Future<dynamic> get done => (super.noSuchMethod(
        Invocation.getter(#done),
        returnValue: _i9.Future<dynamic>.value(),
        returnValueForMissingStub: _i9.Future<dynamic>.value(),
      ) as _i9.Future<dynamic>);

  @override
  _i9.Future<dynamic> close([
    int? closeCode,
    String? closeReason,
  ]) =>
      (super.noSuchMethod(
        Invocation.method(
          #close,
          [
            closeCode,
            closeReason,
          ],
        ),
        returnValue: _i9.Future<dynamic>.value(),
        returnValueForMissingStub: _i9.Future<dynamic>.value(),
      ) as _i9.Future<dynamic>);

  @override
  void add(dynamic data) => super.noSuchMethod(
        Invocation.method(
          #add,
          [data],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void addError(
    Object? error, [
    StackTrace? stackTrace,
  ]) =>
      super.noSuchMethod(
        Invocation.method(
          #addError,
          [
            error,
            stackTrace,
          ],
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i9.Future<dynamic> addStream(_i9.Stream<dynamic>? stream) =>
      (super.noSuchMethod(
        Invocation.method(
          #addStream,
          [stream],
        ),
        returnValue: _i9.Future<dynamic>.value(),
        returnValueForMissingStub: _i9.Future<dynamic>.value(),
      ) as _i9.Future<dynamic>);
}

/// A class which mocks [PhoenixSocketOptions].
///
/// See the documentation for Mockito's code generation for more information.
class MockPhoenixSocketOptions extends _i1.Mock
    implements _i5.PhoenixSocketOptions {
  @override
  _i5.MessageSerializer get serializer => (super.noSuchMethod(
        Invocation.getter(#serializer),
        returnValue: _FakeMessageSerializer_7(
          this,
          Invocation.getter(#serializer),
        ),
        returnValueForMissingStub: _FakeMessageSerializer_7(
          this,
          Invocation.getter(#serializer),
        ),
      ) as _i5.MessageSerializer);

  @override
  List<Duration> get reconnectDelays => (super.noSuchMethod(
        Invocation.getter(#reconnectDelays),
        returnValue: <Duration>[],
        returnValueForMissingStub: <Duration>[],
      ) as List<Duration>);

  @override
  Duration get timeout => (super.noSuchMethod(
        Invocation.getter(#timeout),
        returnValue: _FakeDuration_3(
          this,
          Invocation.getter(#timeout),
        ),
        returnValueForMissingStub: _FakeDuration_3(
          this,
          Invocation.getter(#timeout),
        ),
      ) as Duration);

  @override
  Duration get heartbeat => (super.noSuchMethod(
        Invocation.getter(#heartbeat),
        returnValue: _FakeDuration_3(
          this,
          Invocation.getter(#heartbeat),
        ),
        returnValueForMissingStub: _FakeDuration_3(
          this,
          Invocation.getter(#heartbeat),
        ),
      ) as Duration);

  @override
  _i9.Future<Map<String, String>> getParams() => (super.noSuchMethod(
        Invocation.method(
          #getParams,
          [],
        ),
        returnValue: _i9.Future<Map<String, String>>.value(<String, String>{}),
        returnValueForMissingStub:
            _i9.Future<Map<String, String>>.value(<String, String>{}),
      ) as _i9.Future<Map<String, String>>);
}

/// A class which mocks [OnMessage_MockBase].
///
/// See the documentation for Mockito's code generation for more information.
class MockOnMessage extends _i1.Mock implements _i13.OnMessage_MockBase {
  @override
  void call(String? message) => super.noSuchMethod(
        Invocation.method(
          #call,
          [message],
        ),
        returnValueForMissingStub: null,
      );
}

/// A class which mocks [OnError_MockBase].
///
/// See the documentation for Mockito's code generation for more information.
class MockOnError extends _i1.Mock implements _i13.OnError_MockBase {
  @override
  void call(
    Object? error, [
    StackTrace? stackTrace,
  ]) =>
      super.noSuchMethod(
        Invocation.method(
          #call,
          [
            error,
            stackTrace,
          ],
        ),
        returnValueForMissingStub: null,
      );
}

/// A class which mocks [OnStateChange_MockBase].
///
/// See the documentation for Mockito's code generation for more information.
class MockOnStateChange extends _i1.Mock
    implements _i13.OnStateChange_MockBase {
  @override
  void call(_i14.WebSocketConnectionState? state) => super.noSuchMethod(
        Invocation.method(
          #call,
          [state],
        ),
        returnValueForMissingStub: null,
      );
}
