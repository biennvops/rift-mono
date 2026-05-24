import 'dart:async';
import 'dart:io';

/// Simple IPC abstraction for a Week-2 "spike".
/// - On Windows this returns a NamedPipeStub (simulated).
/// - On other platforms it returns an in-memory channel (isolate/channel spike).
abstract class IPC {
  Future<void> send(String message);
  Stream<String> get messages;

  /// Factory: picks a simple implementation based on platform.
  static IPC create() {
    if (Platform.isWindows) {
      return NamedPipeStub();
    } else {
      return InMemoryChannel();
    }
  }
}

/// Simulated named-pipe implementation for the spike.
/// This does NOT create a system named pipe; it prefixes messages so tests
/// can verify Windows-specific behaviour later.
class NamedPipeStub implements IPC {
  final _ctrl = StreamController<String>.broadcast();

  @override
  Stream<String> get messages => _ctrl.stream;

  @override
  Future<void> send(String message) async {
    // simulate latency
    await Future.delayed(Duration(milliseconds: 10));
    _ctrl.add('namedpipe:$message');
  }

  void dispose() => _ctrl.close();
}

/// Simple in-memory channel used for spike/testing.
class InMemoryChannel implements IPC {
  final _ctrl = StreamController<String>.broadcast();

  @override
  Stream<String> get messages => _ctrl.stream;

  @override
  Future<void> send(String message) async {
    // immediate delivery
    _ctrl.add(message);
  }

  void dispose() => _ctrl.close();
}
