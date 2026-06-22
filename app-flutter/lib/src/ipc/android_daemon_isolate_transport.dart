import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:daemon_dart/daemon_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:stream_channel/stream_channel.dart';

import 'ipc_transport.dart';

/// Android transport that spawns the Dart daemon in a background isolate and
/// connects to its JSON-RPC bridge using SendPort/ReceivePort.
///
/// This is the real IPC binding described in `spec/doc/ipc.md` for Android.
class AndroidDaemonIsolateTransport implements IpcTransport {
  Isolate? _daemonIsolate;
  ReceivePort? _uiReceive;
  SendPort? _rpcPort;
  StreamSubscription? _uiSub;

  StreamController<String>? _incoming;
  StreamController<String>? _outgoing;

  @override
  Future<StreamChannel<String>> connect() async {
    if (_rpcPort != null && _incoming != null && _outgoing != null) {
      return StreamChannel<String>(_incoming!.stream, _outgoing!.sink);
    }

    final storageDir = await getApplicationSupportDirectory();
    final storagePath = storageDir.path;

    _uiReceive = ReceivePort();
    _incoming = StreamController<String>();

    // Spawn daemon isolate. It will send notifications/responses back via
    // `_uiReceive`, and report `rpcPort` inside the `rift.daemonReady` message.
    _daemonIsolate = await Isolate.spawn(
      RiftDaemon.isolateEntryPoint,
      <String, dynamic>{
        'storagePath': storagePath,
        'sendPort': _uiReceive!.sendPort,
      },
    );

    // Single listener for the lifetime of the ReceivePort.
    final ready = Completer<SendPort>();
    _uiSub = _uiReceive!.listen((message) {
      // Isolate error listener delivers [error, stack] as a List.
      if (message is List && message.length >= 2) {
        _incoming?.addError(StateError('Daemon isolate error: ${message[0]}\n${message[1]}'));
        return;
      }

      if (message is Map) {
        _incoming?.add(jsonEncode(message));

        if (message['jsonrpc'] == '2.0' && message['method'] == 'rift.daemonReady') {
          final params = message['params'];
          if (params is Map && params['rpcPort'] is SendPort) {
            final port = params['rpcPort'] as SendPort;
            _rpcPort = port;
            if (!ready.isCompleted) ready.complete(port);
          }
        }

        if (message['jsonrpc'] == '2.0' && message['method'] == 'rift.daemonError') {
          final params = message['params'];
          _incoming?.addError(StateError('Daemon error: ${params is Map ? params['error'] : params}'));
        }
      }
    }, onDone: () {
      _incoming?.close();
    }, onError: (e, st) {
      _incoming?.addError(e, st);
    });

    _outgoing = StreamController<String>();
    // Wait for rift.daemonReady to learn rpcPort (nsd init can be slow).
    await ready.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('Timed out waiting for rift.daemonReady/rpcPort'),
    );

    // Outgoing: JSON string -> Map.
    _outgoing!.stream.listen((json) {
      final port = _rpcPort;
      if (port == null) return;
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        port.send(decoded);
      } else if (decoded is Map) {
        port.send(Map<String, dynamic>.from(decoded));
      } else {
        // Ignore malformed outbound messages rather than crashing the isolate.
      }
    });

    return StreamChannel<String>(_incoming!.stream, _outgoing!.sink);
  }

  @override
  Future<void> disconnect() async {
    await _incoming?.close();
    await _outgoing?.close();
    _incoming = null;
    _outgoing = null;

    await _uiSub?.cancel();
    _uiSub = null;

    _uiReceive?.close();
    _uiReceive = null;

    _rpcPort = null;

    _daemonIsolate?.kill(priority: Isolate.immediate);
    _daemonIsolate = null;
  }
}
