import 'package:http/http.dart';

Future<void> stopBackend() {
  return get(Uri.parse('http://localhost:4002/stop')).then((response) {
    if (response.statusCode != 200) {
      throw Exception('Failed to stop backend');
    }
  });
}

Future<void> restartBackend() {
  return get(Uri.parse('http://localhost:4002/start')).then((response) {
    if (response.statusCode != 200) {
      throw Exception('Failed to start backend');
    }
  });
}

Future<void> stopThenRestartBackend(
    [Duration delay = const Duration(milliseconds: 200)]) {
  return get(Uri.parse('http://localhost:4002/stop')).then((response) {
    if (response.statusCode != 200) {
      throw Exception('Failed to stop backend');
    }
    Future.delayed(delay).then((_) => restartBackend());
  });
}
