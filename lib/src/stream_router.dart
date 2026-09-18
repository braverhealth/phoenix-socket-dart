// Copyright 2013 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';

import 'package:phoenix_socket/src/utils/iterable_extensions.dart';

/// Splits a [Stream] of events into multiple Streams based on a set of
/// predicates.
///
/// Using StreamRouter differs from [Stream.where] because events are only sent
/// to one Stream. If more than one predicate matches the event, the event is
/// sent to the stream created by the earlier call to [route]. Events not
/// matched by a call to [route] are sent to the [defaultStream].
///
/// Example:
///
///    var router = PhoenixStreamRouter(window.onClick);
///    var onRightClick = router.route((e) => e.button == 2);
///    var onAltClick = router.route((e) => e.altKey);
///    var onOtherClick router.defaultStream;
class PhoenixStreamRouter<T> {
  /// Create a new StreamRouter that listens to the [incoming] stream.
  PhoenixStreamRouter(Stream<T> incoming) : _incoming = incoming {
    _subscription = _incoming.listen(_handle, onDone: close);
  }

  final Stream<T> _incoming;
  late StreamSubscription<T> _subscription;

  final List<Route<T>> _routes = <Route<T>>[];
  bool _closed = false;
  Future<void>? _closeFuture;
  final StreamController<T> _defaultController =
      StreamController<T>.broadcast();

  /// Events that match [predicate] are sent to the stream created by this
  /// method, and not sent to any other router streams.
  Stream<T> route(Predicate<T> predicate) {
    if (_closed) throw StateError('Cannot route a closed stream');
    final controller = StreamController<T>.broadcast();
    final route = Route<T>(predicate, controller);
    _routes.add(route);
    return controller.stream;
  }

  Stream<T> get defaultStream => _defaultController.stream;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    await _subscription.cancel();
    await Future.wait([
      _defaultController.close(),
      ..._routes.map((route) => route.controller.close()),
    ]);
    _routes.clear();
  }

  void _handle(T event) {
    if (_closed) return;
    final route = _routes.firstWhereOrNull((r) => r.predicate(event));
    ((route != null) ? route.controller : _defaultController).add(event);
  }
}

typedef Predicate<T> = bool Function(T event);

class Route<T> {
  Route(this.predicate, this.controller);

  final Predicate<T> predicate;
  final StreamController<T> controller;
}
