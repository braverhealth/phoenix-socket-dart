import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:vm_service/vm_service_io.dart';

/// Run with `dart --observe=0 --no-pause-isolates-on-exit run
/// tool/allocation_benchmark.dart`. Allocation counters come from dedicated
/// worker isolates; the VM service driver is excluded from those isolates.
Future<void> main(List<String> args, [SendPort? readyPort]) async {
  if (readyPort != null) {
    _worker((readyPort, args[0], int.parse(args[1])));
    return;
  }
  final info = await Service.getInfo();
  final uri = info.serverUri;
  if (uri == null) throw StateError('Run this benchmark with --observe=0');
  final service = await vmServiceConnectUri(
      uri.replace(scheme: 'ws', path: '${uri.path}ws').toString());
  try {
    for (final kind
        in args.contains('--json-only') ? ['json'] : ['json', 'binary']) {
      for (final size in [1024, 100 * 1024, 2 * 1024 * 1024]) {
        final ready = ReceivePort();
        final worker = await Isolate.spawnUri(
            Platform.script, [kind, size.toString()], ready.sendPort);
        try {
          final commands = await ready.first as SendPort;
          ready.close();
          final id = Service.getIsolateId(worker)!;
          await service.getAllocationProfile(id, reset: true, gc: true);
          final classes =
              (await service.getClassList(id)).classes!.where((type) {
            final name = type.name ?? '';
            return name.contains('String') ||
                name.contains('Uint8') ||
                name.contains('List') ||
                name == '_Map' ||
                name == 'Message' ||
                name == '_Closure';
          }).toList();
          for (final type in classes) {
            await service.setTraceClassAllocation(id, type.id!, true);
          }
          await service.clearCpuSamples(id);
          final done = ReceivePort();
          final iterations = size > 1024 * 1024 ? 20 : 200;
          commands.send([done.sendPort, iterations]);
          final checksum = await done.first;
          done.close();
          final profile = await service.getAllocationProfile(id, gc: true);
          final counts = <String, int>{};
          for (final type in classes) {
            final samples =
                await service.getAllocationTraces(id, classId: type.id!);
            if ((samples.sampleCount ?? 0) > 0) {
              counts[type.name!] = samples.sampleCount!;
            }
          }
          print(jsonEncode({
            'codec': kind,
            'payload_bytes': size,
            'iterations': iterations,
            'sampled_allocations_per_exchange':
                counts.values.fold<int>(0, (sum, count) => sum + count) /
                    iterations,
            'sampled_allocations_by_class': counts,
            'retained_heap_bytes': profile.memoryUsage?.heapUsage,
            'retained_external_bytes': profile.memoryUsage?.externalUsage,
            'checksum': checksum
          }));
        } finally {
          worker.kill(priority: Isolate.immediate);
        }
      }
    }
  } finally {
    await service.dispose();
  }
}

void _worker((SendPort, String, int) setup) {
  final (ready, kind, size) = setup;
  const codec = MessageSerializer();
  final Object body = kind == 'json'
      ? <String, dynamic>{'data': List.filled(size, 'x').join()}
      : Uint8List(size);
  final message = Message(
      joinRef: '1',
      ref: '2',
      topic: 'room',
      event: PhoenixChannelEvent.custom('update'),
      payload: body as dynamic);
  final Object inbound = kind == 'json'
      ? codec.encode(message)
      : Uint8List.fromList(
          [2, 4, 6, ...utf8.encode('roomupdate'), ...body as Uint8List]);
  int exchange() {
    final Object encoded = codec.encode(message);
    final length =
        encoded is String ? encoded.length : (encoded as Uint8List).length;
    return length + codec.decode(inbound).topic!.length;
  }

  for (var i = 0; i < 20; i++) {
    exchange();
  }
  final commands = ReceivePort();
  commands.listen((dynamic command) {
    final done = command[0] as SendPort;
    final iterations = command[1] as int;
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      checksum += exchange();
    }
    done.send(checksum);
  });
  ready.send(commands.sendPort);
}
