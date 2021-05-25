import 'package:logging/logging.dart';
import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print(
      '[${record.loggerName}] ${record.level.name} ${record.time}: '
      '${record.message}',
    );
  });
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phoenix Presence Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MyHomePage(title: 'Phoenix Presence Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _socketOptions =
      PhoenixSocketOptions(params: {'user_id': 'example user 1'});
  late PhoenixSocket _socket;
  late PhoenixChannel _channel;
  late PhoenixPresence _presence;
  var _responses = [];

  @override
  void initState() {
    // In case of difficulties to connect to the server:
    // - Try replacing 'localhost' by the ip address of the server where the example Phoenix backend server is running
    // - For testing only!!! Make sure non-secure HTTP connection are allowed in the android manifest at
    // android\app\src\main\AndroidManifest.xml:
    //   ...<application
    //       ...
    //       android:usesCleartextTraffic="true">
    //       <activity...
    _socket = PhoenixSocket('ws://localhost:4001/socket/websocket',
        socketOptions: _socketOptions);
    _channel = _socket.addChannel(topic: 'presence:lobby');
    _presence = PhoenixPresence(channel: _channel);

    _socket.closeStream.listen((event) {
      // Temporary fix until https://github.com/braverhealth/phoenix-socket-dart/issues/34 is resolved.
      _socket.close();
    });
    _socket.openStream.listen((event) {
      _channel.join();
    });

    _presence.onSync = () => setState(() {});

    _socket.connect();
    super.initState();
  }

  @override
  void dispose() {
    _presence.dispose();
    _channel.close();
    _socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _responses =
        _presence.list(_presence.state, (String id, Presence presence) {
      final metas = presence.metas;
      var count = metas.length;

      // Optional step, cast [PhoenixPresenceMeta] to [MyCustomPhoenixPresenceMeta]
      // for ease of use with custom fields.
      final myMetas = metas.map((m) => MyCustomPhoenixPresenceMeta(m)).toList();

      // Sort latest connection to the end of the metas list.
      myMetas.sort((a, b) => a.onlineAt.compareTo(b.onlineAt));
      final latestOnline = myMetas.last.onlineAt;

      final response =
          '$id (count: $count, latest online at: ${latestOnline.hour}:${latestOnline.minute}:${latestOnline.second})';
      return response;
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Presence Example')),
      body: Container(
        child: ListView.builder(
          itemCount: _responses.length,
          itemBuilder: (BuildContext context, int index) {
            return ListTile(
              title: Text(_responses[index]),
            );
          },
        ),
      ),
    );
  }
}

/// Optionally, you can extends the PhoenixPresenceMeta class with your custom meta fields
/// so they are easily accessible from your code.
/// Below is an example with a custom [online_at] field in the metas from the server which indicates
/// the connection time in millisecondsSinceEpoch.
class MyCustomPhoenixPresenceMeta extends PhoenixPresenceMeta {
  /// The time at which the [Presence] event happened in the local time zone.
  DateTime get onlineAt => _onlineAt;

  MyCustomPhoenixPresenceMeta._fromJson(Map<String, dynamic> meta)
      : _onlineAt =
            DateTime.fromMillisecondsSinceEpoch(int.parse(meta['online_at'])),
        super.fromJson(meta);

  factory MyCustomPhoenixPresenceMeta(PhoenixPresenceMeta meta) {
    return MyCustomPhoenixPresenceMeta._fromJson(meta.data);
  }

  final DateTime _onlineAt;

  @override
  MyCustomPhoenixPresenceMeta clone() {
    return MyCustomPhoenixPresenceMeta(super.clone());
  }
}
