import 'adapter_contract.dart';
import 'adapter_json.dart';
import 'workloads.dart';

CodecAdapter createAdapter(String mode, Workload data) {
  if (mode != 'json') throw UnsupportedError('alpha has no binary codecs');
  return createJsonAdapter(data);
}
