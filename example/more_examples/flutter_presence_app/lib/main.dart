import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Phoenix Presence Demo',
        theme: ThemeData(primarySwatch: Colors.blue),
        home: const PresencePage(),
      );
}

class PresencePage extends StatefulWidget {
  const PresencePage({super.key});

  @override
  State<PresencePage> createState() => _PresencePageState();
}

class _PresencePageState extends State<PresencePage> {
  late final PhoenixSocket _socket;
  late final PhoenixChannel _channel;
  late final PhoenixPresence<UserMeta> _presence;
  late final StreamSubscription<PresenceError> _errors;

  @override
  void initState() {
    super.initState();
    _socket = PhoenixSocket(
      'ws://localhost:4001/socket/websocket',
      socketOptions: PhoenixSocketOptions(
        params: {'user_id': 'example user 1'},
      ),
    );
    _channel = _socket.addChannel(topic: 'presence:lobby');
    // Attach before joining so the initial state cannot be missed.
    _presence = PhoenixPresence<UserMeta>(
      channel: _channel,
      decodeMeta: UserMeta.fromJson,
    );
    _errors = _presence.errors.listen((error) {
      debugPrint('Presence synchronization failed: $error');
    });
    // Joining before connecting lets the channel handle subsequent rejoins.
    _channel.join();
    unawaited(_socket.connect());
  }

  @override
  void dispose() {
    unawaited(_errors.cancel());
    unawaited(_presence.dispose());
    _socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Presence Example')),
        body: StreamBuilder<PresenceSnapshot<UserMeta>>(
          stream: _presence.snapshots,
          initialData: _presence.snapshot,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            if (state.status == PresenceSyncStatus.awaitingState) {
              return const Center(child: CircularProgressIndicator());
            }
            final users = state.presences.values.toList()
              ..sort((a, b) => a.key.compareTo(b.key));
            return Column(
              children: [
                if (!state.isSynchronized)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                        'Connection interrupted. Showing last known presence.'),
                  ),
                Expanded(
                  child: users.isEmpty
                      ? const Center(child: Text('Nobody is present.'))
                      : ListView.builder(
                          itemCount: users.length,
                          itemBuilder: (context, index) {
                            final user = users[index];
                            final times = user.metas
                                .map((meta) => meta.value.onlineAt)
                                .toList()
                              ..sort();
                            return ListTile(
                              title: Text(user.key),
                              subtitle: Text(
                                'Devices: ${user.metas.length}'
                                '${times.isEmpty ? '' : ', latest online: ${times.last}'}',
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      );
}

/// Immutable application metadata, separate from Phoenix protocol references.
class UserMeta {
  const UserMeta(this.onlineAt);

  factory UserMeta.fromJson(Map<String, Object?> json) {
    // The included Phoenix backend publishes Unix seconds as a string.
    final seconds = int.parse(json['online_at'] as String);
    return UserMeta(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
  }

  final DateTime onlineAt;
}
