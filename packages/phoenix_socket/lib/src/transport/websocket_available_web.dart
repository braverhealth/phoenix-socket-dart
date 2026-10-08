import 'dart:js_interop';

@JS('globalThis.WebSocket')
external JSAny? get _webSocket;

bool webSocketAvailable() => _webSocket != null;
