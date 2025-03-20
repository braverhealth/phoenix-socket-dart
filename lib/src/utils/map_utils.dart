/// Utility functions for handling map operations.
class MapUtils {
  /// Recursively converts all keys in a map to strings and handles nested maps and lists.
  ///
  /// [input] is the map to be converted.
  /// Returns a new map with all keys converted to strings and nested structures handled.
  static Map<String, dynamic> deepConvertToStringDynamic(
      Map<dynamic, dynamic> input) {
    return input.map((key, value) {
      if (value is Map) {
        return MapEntry(key.toString(), deepConvertToStringDynamic(value));
      } else if (value is List) {
        return MapEntry(
            key.toString(),
            value.map((element) {
              if (element is Map) {
                return deepConvertToStringDynamic(element);
              } else {
                return element;
              }
            }).toList());
      } else {
        return MapEntry(key.toString(), value);
      }
    });
  }
}
