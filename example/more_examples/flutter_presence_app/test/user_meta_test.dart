import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/main.dart';

void main() {
  test('online_at from the example backend is Unix seconds', () {
    final meta = UserMeta.fromJson({'online_at': '1700000000'});
    expect(meta.onlineAt.millisecondsSinceEpoch, 1700000000000);
  });

  test('invalid timestamps fail decoding instead of displaying misleading data',
      () {
    expect(() => UserMeta.fromJson({'online_at': 'invalid'}),
        throwsFormatException);
  });
}
