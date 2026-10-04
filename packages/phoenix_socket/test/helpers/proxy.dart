import 'dart:convert';

import 'package:http/http.dart';

const toxiproxy = 'http://localhost:8474';

Future<void> prepareProxy() {
  return post(
    Uri.parse('$toxiproxy/proxies'),
    body: jsonEncode(
      {
        'name': 'backend',
        'listen': '0.0.0.0:4004',
        'upstream': 'backend:4001',
        'enabled': true,
      },
    ),
  );
}

Future<void> haltProxy() {
  return patch(
    Uri.parse('$toxiproxy/proxies/backend'),
    body: jsonEncode(
      {'enabled': false},
    ),
  );
}

Future<void> resumeProxy() {
  return patch(
    Uri.parse('$toxiproxy/proxies/backend'),
    body: jsonEncode(
      {'enabled': true},
    ),
  );
}

Future<void> resetPeer({bool enable = true}) {
  return enable
      ? post(
          Uri.parse('$toxiproxy/proxies/backend/toxics'),
          body: jsonEncode(
            {'name': 'reset-peer', 'type': 'reset_peer'},
          ),
        )
      : delete(
          Uri.parse('$toxiproxy/proxies/backend/toxics/reset-peer'),
        );
}

Future<void> destroyProxy() {
  return delete(Uri.parse('$toxiproxy/proxies/backend'));
}

Future<void> haltThenResumeProxy([
  Duration delay = const Duration(milliseconds: 500),
]) {
  return haltProxy().then((response) {
    return Future.delayed(delay).then((_) async {
      await resumeProxy();
    });
  });
}

Future<void> resetPeerThenResumeProxy([
  Duration delay = const Duration(milliseconds: 500),
]) {
  return resetPeer().then((response) {
    return Future.delayed(delay).then((_) async {
      await resetPeer(enable: false);
    });
  });
}
