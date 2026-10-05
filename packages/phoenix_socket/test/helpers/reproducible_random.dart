import 'dart:typed_data';

/// Xorshift32 keeps the same corpus across native Dart, JavaScript and SDKs.
class ReproducibleRandom {
  ReproducibleRandom(int seed) : _state = seed == 0 ? 1 : seed.toUnsigned(32);
  int _state;

  int nextInt(int maximum) {
    var value = _state;
    value = (value ^ (value << 13)).toUnsigned(32);
    value = (value ^ (value >>> 17)).toUnsigned(32);
    _state = (value ^ (value << 5)).toUnsigned(32);
    return _state % maximum;
  }

  Uint8List bytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => nextInt(256)));

  String text(int maximumLength) {
    const alphabet = ['a', 'z', '0', 'é', '漢', '🙂', '\n', '"', '\\'];
    return List.generate(nextInt(maximumLength + 1),
        (_) => alphabet[nextInt(alphabet.length)]).join();
  }

  Object? value({int depth = 0, bool binary = false}) {
    switch (nextInt(depth >= 4
        ? 5
        : binary
            ? 8
            : 7)) {
      case 0:
        return null;
      case 1:
        return nextInt(2) == 0;
      case 2:
        return nextInt(0x7fffffff) - 0x3fffffff;
      case 3:
        return (nextInt(200000) - 100000) / 16.0;
      case 4:
        return text(40);
      case 5:
        return List.generate(
            nextInt(6), (_) => value(depth: depth + 1, binary: binary));
      case 6:
        return <String, dynamic>{
          for (var i = 0; i < nextInt(6); i++)
            'key$i': value(depth: depth + 1, binary: binary)
        };
      default:
        return bytes(nextInt(257));
    }
  }

  void shuffle<T>(List<T> values) {
    for (var i = values.length - 1; i > 0; i--) {
      final other = nextInt(i + 1);
      final value = values[i];
      values[i] = values[other];
      values[other] = value;
    }
  }
}
