import 'package:phoenix_browser_comparison/adapter_contract.dart';
import 'package:phoenix_browser_comparison/adapter_new.dart';
import 'package:phoenix_browser_comparison/workloads.dart';
import 'package:test/test.dart';

void main() {
  for (final family in families) {
    test('$family preserves content through every supported codec', () {
      final data = Workload(family, 4096);
      expect(data.jsonBytes.length, greaterThan(0));
      for (final mode in modes) {
        if (mode == 'binary_raw' && family != 'bytes') continue;
        final adapter = createAdapter(mode, data);
        final incoming = inboundFrame(mode, data, adapter);
        final decoded = adapter.decode(incoming);
        expect(digest(canonicalDecoded(decoded, mode, data)), data.fingerprint,
            reason: mode);
      }
    });
  }
}
