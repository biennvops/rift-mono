import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:stream_channel/stream_channel.dart';

import 'ipc_transport.dart';
import 'android_daemon_isolate_entrypoint.dart';

/// Android transport that spawns the Dart daemon in a background isolate and
/// connects to its JSON-RPC bridge using SendPort/ReceivePort.
///
/// This is the real IPC binding described in `spec/doc/ipc.md` for Android.
class AndroidDaemonIsolateTransport implements IpcTransport {
  Isolate? _daemonIsolate;
  ReceivePort? _uiReceive;
  SendPort? _rpcPort;
  StreamSubscription? _uiSub;
  ReceivePort? _errorPort;
  StreamSubscription? _errorSub;
  ReceivePort? _exitPort;
  StreamSubscription? _exitSub;

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
    _errorPort = ReceivePort();
    _exitPort = ReceivePort();

    // Spawn daemon isolate. It will send notifications/responses back via
    // `_uiReceive`, and report `rpcPort` inside the `rift.daemonReady` message.
    final token = ServicesBinding.rootIsolateToken;
    if (token == null) {
      throw StateError('RootIsolateToken is null; cannot start Android daemon isolate');
    }

    _daemonIsolate = await Isolate.spawn(
      androidDaemonIsolateEntrypoint,
      <String, dynamic>{
        'storagePath': storagePath,
        'sendPort': _uiReceive!.sendPort,
        'rootIsolateToken': token,
        // In debug builds, many plugins (including older MethodChannel-based ones)
        // are not isolate-safe and will assert/crash if used off the root isolate.
        // Keep the daemon IPC alive for getDeviceInfo/etc by disabling discovery.
        'enableDiscovery': !kDebugMode,
        'enableTransport': true,
        // Use stable port in release (discovery), but allow the daemon to fall
        // back if the port is unavailable.
        'port': 11112,
      },
      onError: _errorPort!.sendPort,
      onExit: _exitPort!.sendPort,
      errorsAreFatal: true,
    );

    _errorSub = _errorPort!.listen((msg) {
      // Standard isolate error: [error, stack]
      if (msg is List && msg.length >= 2) {
        _incoming?.addError(StateError('Daemon isolate error: ${msg[0]}\n${msg[1]}'));
      } else {
        _incoming?.addError(StateError('Daemon isolate error: $msg'));
      }
    });
    _exitSub = _exitPort!.listen((_) {
      _incoming?.addError(StateError('Daemon isolate exited'));
    });

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

    await _errorSub?.cancel();
    _errorSub = null;
    _errorPort?.close();
    _errorPort = null;

    await _exitSub?.cancel();
    _exitSub = null;
    _exitPort?.close();
    _exitPort = null;

    _rpcPort = null;

    _daemonIsolate?.kill(priority: Isolate.immediate);
    _daemonIsolate = null;
  }
}
