import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool _connected = false;
  int _counter = 0;
  late PhoenixSocket _socket;
  PhoenixChannel? _channel;

  _MyHomePageState() {
    _socket = PhoenixSocket('ws://localhost:4000/socket/websocket')..connect();
    _socket.closeStream.listen((event) {
      setState(() => _connected = false);
    });
    _socket.openStream.listen((event) {
      setState(() => _connected = true);
      if (_channel == null) {
        setState(() {
          _channel = _socket.addChannel(topic: 'room:math');
          _channel?.join();
        });
      }
    });
  }

  void _incrementCounter() => _channel?.push('sum', {'times': 1});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _channel != null && _connected ? "Connected" : "Disconnected",
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              'You have pushed the button this many times:',
            ),
            StreamBuilder(
              stream: _channel?.messages,
              initialData: Message(
                event: PhoenixChannelEvent.join,
                joinRef: '',
                payload: {'times': 0},
                ref: '',
                topic: '',
              ),
              builder:
                  (BuildContext context, AsyncSnapshot<Message?> snapshot) {
                if (!snapshot.hasData) {
                  return Container();
                }
                // only modify widget with events from the `sum` channel
                if (snapshot.data?.event.value == 'sum') {
                  var times = snapshot.data?.payload?['times'];
                  if (times != null) {
                    _counter = times;
                  }
                }
                return Container(
                  child: Text(
                    '$_counter',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                );
              },
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: Icon(Icons.add),
      ),
    );
  }
}
