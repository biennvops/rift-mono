import 'dart:async';

class PeerWriteGate {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.catchError((_) {});
    return next;
  }
}
