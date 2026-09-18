import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Starts only this checkout's backend, on an OS-assigned loopback port.
Future<void> main(List<String> arguments) async {
  final root = File.fromUri(Platform.script).parent.parent;
  final scratch = await Directory.systemTemp.createTemp('phoenix-socket-e2e-');
  final backend = await Process.start(
    'mix',
    ['run', 'test/e2e_server.exs'],
    workingDirectory: '${root.path}/example/backend',
    environment: {
      'MIX_ENV': 'test',
      'PHOENIX_E2E': '1',
      'ERL_CRASH_DUMP': '${scratch.path}/erl_crash.dump',
    },
  );
  final ready = Completer<int>();
  final backendExit = backend.exitCode;
  final output = <String>[];
  void record(String line) {
    output.add(line);
    if (output.length > 80) output.removeAt(0);
    final port = RegExp(r'^PHOENIX_E2E_PORT=(\d+)$').firstMatch(line);
    if (port != null && !ready.isCompleted) {
      ready.complete(int.parse(port.group(1)!));
    }
  }

  final stdoutSubscription = backend.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(record);
  final stderrSubscription = backend.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(record);
  unawaited(backendExit.then((code) {
    if (!ready.isCompleted) {
      ready.completeError(StateError('Backend exited with $code'));
    }
  }));
  Process? tests;
  final signals = <StreamSubscription<ProcessSignal>>[];
  if (!Platform.isWindows) {
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      signals.add(signal.watch().listen((_) {
        tests?.kill();
        backend.kill();
      }));
    }
  }

  try {
    final port = await ready.future.timeout(const Duration(minutes: 3));
    stdout.writeln(
        'Embedded Phoenix backend: 127.0.0.1:$port (pid ${backend.pid})');
    tests = await Process.start(
      Platform.resolvedExecutable,
      ['test', 'test/e2e', '--reporter', 'expanded', ...arguments],
      workingDirectory: root.path,
      environment: {'PHOENIX_E2E_URL': 'ws://127.0.0.1:$port/socket/websocket'},
    );
    await Future.wait([
      stdout.addStream(tests.stdout),
      stderr.addStream(tests.stderr),
    ]);
    exitCode = await tests.exitCode;
  } catch (error) {
    stderr.writeln(error);
    stderr.writeln(output.join('\n'));
    exitCode = 1;
  } finally {
    // The child script exits on this input; no process-name or port-wide kills.
    try {
      backend.stdin.writeln('stop');
      await backend.stdin.close();
    } on Object {
      // The backend may already have exited after an error or signal.
    }
    try {
      await backendExit.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      backend.kill();
      try {
        await backendExit.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        backend.kill(ProcessSignal.sigkill);
        await backendExit;
      }
    }
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
    for (final subscription in signals) {
      await subscription.cancel();
    }
    // Keep any crash artifact for diagnosis; remove an empty scratch directory.
    if (await scratch.list().isEmpty) await scratch.delete();
  }
}
