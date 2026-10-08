import 'package:web/web.dart' as web;

import 'session_store.dart';

PhoenixSocketSessionStore? defaultSessionStore() {
  try {
    return _BrowserSessionStore(web.window.sessionStorage);
  } on Object {
    // Storage can be denied in embedded or private browsing contexts.
    return null;
  }
}

class _BrowserSessionStore implements PhoenixSocketSessionStore {
  _BrowserSessionStore(this.storage);

  final web.Storage storage;

  @override
  String? getItem(String key) => storage.getItem(key);
  @override
  void setItem(String key, String value) => storage.setItem(key, value);
  @override
  void removeItem(String key) => storage.removeItem(key);
}
