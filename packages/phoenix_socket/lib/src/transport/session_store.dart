/// Storage compatible with Phoenix JavaScript's fallback history.
abstract interface class PhoenixSocketSessionStore {
  String? getItem(String key);
  void setItem(String key, String value);
  void removeItem(String key);
}
