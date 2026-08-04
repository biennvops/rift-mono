import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:collection';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:stream_channel/stream_channel.dart';

import 'android_root_discovery_bridge.dart';
import 'ipc_transport.dart';
import 'android_daemon_isolate_entrypoint.dart';
import 'native_tls_api.dart';

/// Android transport that spawns the Dart daemon in a background isolate and
/// connects to its JSON-RPC bridge using SendPort/ReceivePort.
///
/// This is the real IPC binding described in `spec/doc/ipc.md` for Android.
class AndroidDaemonIsolateTransport implements IpcTransport {
  static const _identityChannel = MethodChannel('rift/android/identity');

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
  NativeTlsProxyHost? _tlsProxyHost;
  AndroidRootDiscoveryBridge? _discoveryBridge;
  Future<AndroidRootDiscoveryBridge>? _discoveryBridgeFuture;
  StreamSubscription<AndroidDiscoveredPeer>? _discoveryAddedSub;
  StreamSubscription<AndroidDiscoveredPeer>? _discoveryLostSub;
  StreamSubscription<AndroidDiscoveredPeer>? _reverseTcpPingSub;
  int _nextSyntheticId = 1000000;
  int _nextBootstrapRequestId = -1;
  String? _daemonDeviceId;
  int? _daemonAdvertisedPort;
  String? _daemonFingerprintPrefix;
  final Map<Object, Completer<Map<String, dynamic>>> _bootstrapRequests =
      HashMap<Object, Completer<Map<String, dynamic>>>();

  @override
  Future<StreamChannel<String>> connect() async {
    if (_rpcPort != null && _incoming != null && _outgoing != null) {
      return StreamChannel<String>(_incoming!.stream, _outgoing!.sink);
    }

    final storageDir = await getApplicationSupportDirectory();
    final storagePath = storageDir.path;

    // Load the identity seed on the root isolate (platform channels are
    // unavailable in the daemon isolate). The seed is wrapped by an Android
    // Keystore AES key; a legacy plaintext identity.key is migrated once.
    final identityKey = await _identityChannel.invokeMethod<Uint8List>(
      'loadOrCreate',
      {'legacyPath': '$storagePath/identity.key'},
    );
    if (identityKey == null) {
      throw StateError('Android identity keystore returned no identity key.');
    }

    _uiReceive = ReceivePort();
    _incoming = StreamController<String>.broadcast();
    _errorPort = ReceivePort();
    _exitPort = ReceivePort();

    // Spawn daemon isolate. It will send notifications/responses back via
    // `_uiReceive`, and report `rpcPort` inside the `rift.daemonReady` message.
    final token = ServicesBinding.rootIsolateToken;
    if (token == null) {
      throw StateError(
          'RootIsolateToken is null; cannot start Android daemon isolate');
    }

    // TLS platform-channel calls must run on the root isolate: replies to a
    // dead daemon isolate's binary messenger response handle abort the engine.
    _tlsProxyHost?.dispose();
    _tlsProxyHost = NativeTlsProxyHost()..start();

    _daemonIsolate = await Isolate.spawn(
      androidDaemonIsolateEntrypoint,
      <String, dynamic>{
        'storagePath': storagePath,
        'sendPort': _uiReceive!.sendPort,
        'rootIsolateToken': token,
        'tlsProxyPort': _tlsProxyHost!.requestPort,
        'identityKey': identityKey,
        // Keep discovery on the root isolate so MethodChannel-based plugins
        // like `nsd` never run inside the daemon isolate.
        'enableDiscovery': false,
        'enableTransport': true,
        // Use stable port in release (discovery), but allow the daemon to fall
        // back if the port is unavailable.
        'port': 11112,
      },
      onError: _errorPort!.sendPort,
      onExit: _exitPort!.sendPort,
      errorsAreFatal: true,
    );

    final ready = Completer<SendPort>();

    _errorSub = _errorPort!.listen((msg) {
      // Standard isolate error: [error, stack]
      final err = msg is List && msg.length >= 2
          ? StateError('Daemon isolate error: ${msg[0]}\n${msg[1]}')
          : StateError('Daemon isolate error: $msg');
      _incoming?.addError(err);
      if (!ready.isCompleted) ready.completeError(err);
    });
    _exitSub = _exitPort!.listen((_) {
      final err = StateError('Daemon isolate exited');
      _incoming?.addError(err);
      if (!ready.isCompleted) ready.completeError(err);
    });

    // Single listener for the lifetime of the ReceivePort.
    _uiSub = _uiReceive!.listen((message) {
      // Isolate error listener delivers [error, stack] as a List.
      if (message is List && message.length >= 2) {
        final err =
            StateError('Daemon isolate error: ${message[0]}\n${message[1]}');
        _incoming?.addError(err);
        if (!ready.isCompleted) ready.completeError(err);
        return;
      }

      if (message is Map) {
        final responseId = message['id'];
        if (responseId != null &&
            _bootstrapRequests.containsKey(responseId) &&
            message['jsonrpc'] == '2.0') {
          final completer = _bootstrapRequests.remove(responseId)!;
          if (message['error'] is Map) {
            final error = Map<String, dynamic>.from(message['error'] as Map);
            completer.completeError(
              StateError(
                'Daemon bootstrap RPC failed: ${error['message'] ?? error}',
              ),
            );
          } else {
            final result = message['result'];
            if (result is Map<String, dynamic>) {
              completer.complete(result);
            } else if (result is Map) {
              completer.complete(Map<String, dynamic>.from(result));
            } else {
              completer.complete({'value': result});
            }
          }
          return;
        }

        if (message['jsonrpc'] == '2.0' &&
            message['method'] == 'rift.daemonReady') {
          final params = message['params'];
          if (params is Map && params['rpcPort'] is SendPort) {
            final port = params['rpcPort'] as SendPort;
            _rpcPort = port;
            final deviceId = params['deviceId'];
            final advertisedPort = params['advertisedPort'];
            _daemonDeviceId = deviceId is String ? deviceId : null;
            _daemonAdvertisedPort =
                advertisedPort is int ? advertisedPort : null;
            _daemonFingerprintPrefix = params['fingerprintPrefix'] is String
                ? params['fingerprintPrefix'] as String
                : null;
            if (!ready.isCompleted) ready.complete(port);
            unawaited(() async {
              try {
                await _ensureDiscoveryBridge();
              } catch (error) {
                final err =
                    StateError('Android discovery bootstrap failed: $error');
                _incoming?.addError(err);
              }
            }());
          }
          return;
        }

        _incoming?.add(jsonEncode(message));

        if (message['jsonrpc'] == '2.0' &&
            message['method'] == 'rift.daemonError') {
          final params = message['params'];
          final err = StateError('Daemon error: ${params['error']}');
          _incoming?.addError(err);
          _incoming?.close();
          if (!ready.isCompleted) ready.completeError(err);
          return;
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
      onTimeout: () => throw TimeoutException(
          'Timed out waiting for rift.daemonReady/rpcPort'),
    );

    // Outgoing: JSON string -> Map.
    _outgoing!.stream.listen((json) {
      final port = _rpcPort;
      if (port == null) return;
      final decoded = jsonDecode(json);
      if (decoded is Map &&
          _interceptDiscoveryRpc(Map<String, dynamic>.from(decoded))) {
        return;
      }
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

  Future<void> _attachDiscoveryBridge(AndroidRootDiscoveryBridge bridge) async {
    _discoveryBridge = bridge;

    await _discoveryAddedSub?.cancel();
    await _discoveryLostSub?.cancel();
    await _reverseTcpPingSub?.cancel();

    _discoveryAddedSub = bridge.onPeerDiscovered.listen((peer) {
      _incoming?.add(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'rift.onPeerDiscovered',
        'params': peer.toIpcMap(),
      }));
      _syncDiscoverySnapshotToDaemon();
    });
    _discoveryLostSub = bridge.onPeerLost.listen((peer) {
      _incoming?.add(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'rift.onPeerLost',
        'params': {
          if (peer.deviceIdHint != null) 'deviceId': peer.deviceIdHint,
          'instanceId': peer.instanceId,
        },
      }));
      _syncDiscoverySnapshotToDaemon();
    });

    _reverseTcpPingSub = bridge.onReverseTcpPingRequested.listen((peer) {
      final port = _rpcPort;
      if (port == null) return;
      // Send a ping command to the daemon isolate to establish a TCP connection
      // with the Linux machine. This completely bypasses the Hotspot UDP block!
      port.send({
        'jsonrpc': '2.0',
        'method': 'rift.pingEndpoint',
        'params': {
          'address': peer.address,
          'port': peer.port,
        },
      });
    });

    _syncDiscoverySnapshotToDaemon();
  }

  Future<void> _bootstrapRootDiscovery() async {
    if (_rpcPort == null || _discoveryBridge != null) return;

    final deviceId = _daemonDeviceId;
    final advertisedPort = _daemonAdvertisedPort;
    if (deviceId == null || advertisedPort == null) {
      throw StateError(
        'Android discovery metadata is incomplete. Wait for daemon startup to finish, then try again.',
      );
    }

    final bridge = AndroidRootDiscoveryBridge(
      port: advertisedPort,
      deviceIdHint: deviceId,
      fingerprintPrefix: _daemonFingerprintPrefix,
    );
    await bridge.ensureAdvertising();
    await _attachDiscoveryBridge(bridge);
    if (await _shouldAutoStartDiscovery()) {
      await bridge.startDiscovery();
      _syncDiscoverySnapshotToDaemon();
    }
  }

  Future<bool> _shouldAutoStartDiscovery() async {
    final trusted = await _invokeDaemonBootstrapRpc('rift.listTrustedPeers');
    return (trusted['peers'] as List?)?.isNotEmpty == true;
  }

  Future<Map<String, dynamic>> _invokeDaemonBootstrapRpc(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final port = _rpcPort;
    if (port == null) {
      throw StateError(
          'Daemon bootstrap RPC requested before rpcPort was ready');
    }

    final id = 'transport-bootstrap-${_nextBootstrapRequestId--}';
    final completer = Completer<Map<String, dynamic>>();
    _bootstrapRequests[id] = completer;
    port.send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });

    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } finally {
      _bootstrapRequests.remove(id);
    }
  }

  Future<AndroidRootDiscoveryBridge> _ensureDiscoveryBridge() {
    final existing = _discoveryBridge;
    if (existing != null) {
      return Future.value(existing);
    }

    final pending = _discoveryBridgeFuture;
    if (pending != null) {
      return pending;
    }

    final future = _bootstrapDiscoveryBridge();
    _discoveryBridgeFuture = future;
    return future.whenComplete(() {
      if (identical(_discoveryBridgeFuture, future)) {
        _discoveryBridgeFuture = null;
      }
    });
  }

  Future<AndroidRootDiscoveryBridge> _bootstrapDiscoveryBridge() async {
    if (_daemonDeviceId == null || _daemonAdvertisedPort == null) {
      throw StateError(
        'Android discovery is not ready yet. Wait a moment for the daemon to finish startup, then try again.',
      );
    }

    await _bootstrapRootDiscovery();
    final bridge = _discoveryBridge;
    if (bridge == null) {
      throw StateError(
        'Android discovery bridge failed to initialize. Restart the app and try discovery again.',
      );
    }

    return bridge;
  }

  bool _interceptDiscoveryRpc(Map<String, dynamic> decoded) {
    final method = decoded['method'];
    final id = decoded['id'];
    if (method is! String || id == null) {
      return false;
    }

    switch (method) {
      case 'rift.listDiscoveredPeers':
        _emitSyntheticResult(id, {
          'peers': _discoveryBridge?.listPeersForIpc() ?? const [],
          'isDiscovering': _discoveryBridge?.isDiscovering == true,
        });
        return true;
      case 'rift.startDiscovery':
        _handleSyntheticDiscoveryRequest(
          id: id,
          action: () async {
            final bridge = await _ensureDiscoveryBridge();
            await bridge.startDiscovery();
            _syncDiscoverySnapshotToDaemon();
            return {'started': true};
          },
        );
        return true;
      case 'rift.stopDiscovery':
        _handleSyntheticDiscoveryRequest(
          id: id,
          action: () async {
            final bridge = await _ensureDiscoveryBridge();
            await bridge.stopDiscovery();
            _syncDiscoverySnapshotToDaemon();
            return {'stopped': true};
          },
        );
        return true;
      default:
        return false;
    }
  }

  void _handleSyntheticDiscoveryRequest({
    required Object id,
    required Future<Map<String, dynamic>> Function() action,
  }) {
    action().then((result) {
      _emitSyntheticResult(id, result);
    }).catchError((Object error, StackTrace stackTrace) {
      debugPrint(
        '[Android Discovery] Synthetic discovery RPC failed: $error\n$stackTrace',
      );
      _emitSyntheticError(id, -32603, error.toString());
    });
  }

  void _emitSyntheticResult(Object id, Map<String, dynamic> result) {
    _incoming?.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }));
  }

  void _emitSyntheticError(Object id, int code, String message) {
    _incoming?.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': code,
        'message': message,
      },
    }));
  }

  void _syncDiscoverySnapshotToDaemon() {
    final port = _rpcPort;
    final bridge = _discoveryBridge;
    if (port == null || bridge == null) return;
    port.send({
      'internal': 'android.discoverySnapshot',
      'isDiscovering': bridge.isDiscovering,
      'peers': bridge.listPeersForDaemonControl(),
      'syncId': _nextSyntheticId++,
    });
  }

  Stream<String> get rawIncoming =>
      _incoming?.stream ?? const Stream<String>.empty();

  Future<void> sendRaw(String message) async {
    final outgoing = _outgoing;
    if (outgoing == null) {
      throw StateError('Android daemon is not connected');
    }
    outgoing.add(message);
  }

  @override
  Future<void> disconnect() async {
    await _tlsProxyHost?.dispose();
    _tlsProxyHost = null;
    await _discoveryAddedSub?.cancel();
    _discoveryAddedSub = null;
    await _discoveryLostSub?.cancel();
    _discoveryLostSub = null;
    await _discoveryBridge?.dispose();
    _discoveryBridge = null;
    _discoveryBridgeFuture = null;

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
    _daemonDeviceId = null;
    _daemonAdvertisedPort = null;
    _daemonFingerprintPrefix = null;

    _daemonIsolate?.kill(priority: Isolate.immediate);
    _daemonIsolate = null;
  }
}
