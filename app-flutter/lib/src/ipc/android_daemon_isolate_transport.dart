import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:stream_channel/stream_channel.dart';

import 'android_root_discovery_bridge.dart';
import 'ipc_transport.dart';
import 'android_daemon_isolate_entrypoint.dart';
import 'native_tls_api.dart';

typedef AndroidDaemonIsolateSpawner = Future<void Function()> Function(
  Map<String, dynamic> message, {
  required SendPort onError,
  required SendPort onExit,
});

typedef AndroidDiscoveryBridgeFactory = AndroidDiscoveryBridge Function({
  required int port,
  required String deviceIdHint,
  String? fingerprintPrefix,
});

@visibleForTesting
class AndroidDaemonBootstrap {
  const AndroidDaemonBootstrap({
    required this.storagePath,
    required this.identityKey,
    required this.rootIsolateToken,
    this.localDisplayName,
  });

  final String storagePath;
  final Uint8List identityKey;
  final Object rootIsolateToken;
  final String? localDisplayName;
}

@visibleForTesting
class AndroidDaemonTlsProxy {
  AndroidDaemonTlsProxy({
    required this.requestPort,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  final SendPort requestPort;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

@visibleForTesting
class AndroidDaemonTransportBindings {
  const AndroidDaemonTransportBindings({
    required this.loadBootstrap,
    required this.startTlsProxy,
    required this.spawnIsolate,
    required this.createDiscoveryBridge,
  });

  final Future<AndroidDaemonBootstrap> Function() loadBootstrap;
  final AndroidDaemonTlsProxy Function() startTlsProxy;
  final AndroidDaemonIsolateSpawner spawnIsolate;
  final AndroidDiscoveryBridgeFactory createDiscoveryBridge;
}

/// Android transport that spawns the Dart daemon in a background isolate and
/// connects to its JSON-RPC bridge using SendPort/ReceivePort.
///
/// This is the real IPC binding described in `spec/doc/ipc.md` for Android.
class AndroidDaemonIsolateTransport implements IpcTransport {
  static const _identityChannel = MethodChannel('rift/android/identity');
  static const _defaultDaemonReadyTimeout = Duration(seconds: 30);

  AndroidDaemonIsolateTransport({
    @visibleForTesting AndroidDaemonTransportBindings? bindings,
    @visibleForTesting Duration daemonReadyTimeout = _defaultDaemonReadyTimeout,
  })  : _bindings = bindings ?? _productionBindings,
        _daemonReadyTimeout = daemonReadyTimeout;

  static final AndroidDaemonTransportBindings _productionBindings =
      AndroidDaemonTransportBindings(
    loadBootstrap: _loadProductionBootstrap,
    startTlsProxy: _startProductionTlsProxy,
    spawnIsolate: _spawnProductionIsolate,
    createDiscoveryBridge: ({
      required int port,
      required String deviceIdHint,
      String? fingerprintPrefix,
    }) =>
        AndroidRootDiscoveryBridge(
      port: port,
      deviceIdHint: deviceIdHint,
      fingerprintPrefix: fingerprintPrefix,
    ),
  );

  final AndroidDaemonTransportBindings _bindings;
  final Duration _daemonReadyTimeout;
  _AndroidDaemonConnection? _activeAttempt;
  _AndroidDaemonConnection? _connection;
  Future<StreamChannel<String>>? _connectFuture;
  Future<void>? _disconnectFuture;
  bool _disconnecting = false;
  int _nextAttemptId = 0;
  int _nextSyntheticId = 1000000;
  int _nextBootstrapRequestId = -1;

  static Future<AndroidDaemonBootstrap> _loadProductionBootstrap() async {
    final storageDir = await getApplicationSupportDirectory();
    final storagePath = storageDir.path;
    final identityKey = await _identityChannel.invokeMethod<Uint8List>(
      'loadOrCreate',
      {'legacyPath': '$storagePath/identity.key'},
    );
    if (identityKey == null) {
      throw StateError('Android identity keystore returned no identity key.');
    }
    final nativeDeviceInfo =
        await _identityChannel.invokeMethod<Map<Object?, Object?>>(
      'getDeviceInfo',
    );
    final token = ServicesBinding.rootIsolateToken;
    if (token == null) {
      throw StateError(
        'RootIsolateToken is null; cannot start Android daemon isolate',
      );
    }
    return AndroidDaemonBootstrap(
      storagePath: storagePath,
      identityKey: identityKey,
      rootIsolateToken: token,
      localDisplayName: nativeDeviceInfo?['displayName']?.toString(),
    );
  }

  static AndroidDaemonTlsProxy _startProductionTlsProxy() {
    final host = NativeTlsProxyHost()..start();
    return AndroidDaemonTlsProxy(
      requestPort: host.requestPort,
      dispose: host.dispose,
    );
  }

  static Future<void Function()> _spawnProductionIsolate(
    Map<String, dynamic> message, {
    required SendPort onError,
    required SendPort onExit,
  }) async {
    final isolate = await Isolate.spawn(
      androidDaemonIsolateEntrypoint,
      message,
      onError: onError,
      onExit: onExit,
      errorsAreFatal: true,
    );
    return () => isolate.kill(priority: Isolate.immediate);
  }

  @override
  Future<StreamChannel<String>> connect() async {
    final disconnecting = _disconnectFuture;
    if (_disconnecting && disconnecting != null) {
      await disconnecting;
    }

    final current = _connection;
    if (current != null && !current.isShuttingDown) {
      return current.channel;
    }
    final pending = _connectFuture;
    if (pending != null) {
      return pending;
    }

    final attempt = _AndroidDaemonConnection(++_nextAttemptId);
    _activeAttempt = attempt;
    final future = _connectAttempt(attempt);
    _connectFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_connectFuture, future)) {
        _connectFuture = null;
      }
    }
  }

  Future<StreamChannel<String>> _connectAttempt(
    _AndroidDaemonConnection attempt,
  ) async {
    debugPrint(
      '[Android Daemon Transport] daemon isolate spawn attempt=${attempt.id}',
    );
    try {
      final bootstrap = await _bindings.loadBootstrap();
      _throwIfAttemptInvalid(attempt);

      attempt.uiReceive = ReceivePort();
      attempt.incoming = StreamController<String>.broadcast();
      attempt.outgoing = StreamController<String>.broadcast();
      attempt.errorPort = ReceivePort();
      attempt.exitPort = ReceivePort();
      _listenToAttempt(attempt);

      attempt.tlsProxy = _bindings.startTlsProxy();
      _throwIfAttemptInvalid(attempt);

      final killIsolate = await _bindings.spawnIsolate(
        <String, dynamic>{
          'storagePath': bootstrap.storagePath,
          'sendPort': attempt.uiReceive!.sendPort,
          'rootIsolateToken': bootstrap.rootIsolateToken,
          'tlsProxyPort': attempt.tlsProxy!.requestPort,
          'identityKey': bootstrap.identityKey,
          if (bootstrap.localDisplayName != null)
            'localDisplayName': bootstrap.localDisplayName,
          'enableDiscovery': false,
          'enableTransport': true,
          'port': 11112,
        },
        onError: attempt.errorPort!.sendPort,
        onExit: attempt.exitPort!.sendPort,
      );
      attempt.ownDaemonIsolate(killIsolate);
      _throwIfAttemptInvalid(attempt);

      await Future.any<SendPort>([
        attempt.ready.future,
        attempt.cancelled.future.then<SendPort>((_) {
          throw StateError(
            'Android daemon connection attempt ${attempt.id} was cancelled',
          );
        }),
      ]).timeout(
        _daemonReadyTimeout,
        onTimeout: () => throw TimeoutException(
          'Timed out waiting for rift.daemonReady/rpcPort',
        ),
      );
      _throwIfAttemptInvalid(attempt);

      attempt.outgoingSub = attempt.outgoing!.stream.listen((json) {
        final port = attempt.rpcPort;
        if (port == null || attempt.isShuttingDown) return;
        final decoded = jsonDecode(json);
        if (decoded is Map &&
            _interceptDiscoveryRpc(
              attempt,
              Map<String, dynamic>.from(decoded),
            )) {
          return;
        }
        if (decoded is Map<String, dynamic>) {
          port.send(decoded);
        } else if (decoded is Map) {
          port.send(Map<String, dynamic>.from(decoded));
        }
      });
      _throwIfAttemptInvalid(attempt);

      if (_connection != null) {
        throw StateError(
          'Cannot commit Android daemon attempt ${attempt.id}: another connection is owned',
        );
      }
      _connection = attempt;
      if (identical(_activeAttempt, attempt)) {
        _activeAttempt = null;
      }
      debugPrint(
        '[Android Daemon Transport] daemon isolate ready attempt=${attempt.id}',
      );
      unawaited(_startDiscoveryBootstrap(attempt));
      return attempt.channel;
    } catch (error, stackTrace) {
      debugPrint(
        '[Android Daemon Transport] daemon isolate startup failed '
        'attempt=${attempt.id}: $error',
      );
      debugPrint(
        '[Android Daemon Transport] rolling back daemon isolate '
        'attempt=${attempt.id}',
      );
      await attempt.dispose();
      if (identical(_activeAttempt, attempt)) {
        _activeAttempt = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _listenToAttempt(_AndroidDaemonConnection attempt) {
    attempt.errorSub = attempt.errorPort!.listen((message) {
      if (attempt.isShuttingDown) return;
      final error = message is List && message.length >= 2
          ? StateError(
              'Daemon isolate error: ${message[0]}\n${message[1]}',
            )
          : StateError('Daemon isolate error: $message');
      attempt.addIncomingError(error);
      if (!attempt.ready.isCompleted) {
        attempt.ready.completeError(error);
      }
    });
    attempt.exitSub = attempt.exitPort!.listen((_) {
      attempt.markIsolateExited();
      if (attempt.isShuttingDown) return;
      final error = StateError('Daemon isolate exited');
      attempt.addIncomingError(error);
      if (!attempt.ready.isCompleted) {
        attempt.ready.completeError(error);
      }
    });
    attempt.uiSub = attempt.uiReceive!.listen(
      (message) => _handleDaemonMessage(attempt, message),
      onDone: attempt.closeIncoming,
      onError: attempt.addIncomingError,
    );
  }

  void _handleDaemonMessage(
    _AndroidDaemonConnection attempt,
    dynamic message,
  ) {
    if (attempt.isShuttingDown) return;
    if (message is List && message.length >= 2) {
      final error = StateError(
        'Daemon isolate error: ${message[0]}\n${message[1]}',
      );
      attempt.addIncomingError(error);
      if (!attempt.ready.isCompleted) {
        attempt.ready.completeError(error);
      }
      return;
    }
    if (message is! Map) return;

    final responseId = message['id'];
    if (responseId != null &&
        attempt.bootstrapRequests.containsKey(responseId) &&
        message['jsonrpc'] == '2.0') {
      final completer = attempt.bootstrapRequests.remove(responseId)!;
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
        attempt.rpcPort = params['rpcPort'] as SendPort;
        attempt.daemonDeviceId =
            params['deviceId'] is String ? params['deviceId'] as String : null;
        attempt.daemonAdvertisedPort = params['advertisedPort'] is int
            ? params['advertisedPort'] as int
            : null;
        attempt.daemonFingerprintPrefix = params['fingerprintPrefix'] is String
            ? params['fingerprintPrefix'] as String
            : null;
        if (!attempt.ready.isCompleted) {
          attempt.ready.complete(attempt.rpcPort!);
        }
      }
      return;
    }

    attempt.addIncoming(jsonEncode(message));
    if (message['jsonrpc'] == '2.0' &&
        message['method'] == 'rift.daemonError') {
      final params = message['params'];
      final detail = params is Map ? params['error'] : params;
      final error = StateError('Daemon error: $detail');
      attempt.addIncomingError(error);
      attempt.closeIncoming();
      if (!attempt.ready.isCompleted) {
        attempt.ready.completeError(error);
      }
    }
  }

  void _throwIfAttemptInvalid(_AndroidDaemonConnection attempt) {
    if (!identical(_activeAttempt, attempt) || attempt.isShuttingDown) {
      throw StateError(
        'Android daemon connection attempt ${attempt.id} is no longer current',
      );
    }
  }

  Future<void> _startDiscoveryBootstrap(
    _AndroidDaemonConnection connection,
  ) async {
    try {
      await _ensureDiscoveryBridge(connection);
    } catch (error) {
      if (_ownsConnection(connection)) {
        connection.addIncomingError(
          StateError('Android discovery bootstrap failed: $error'),
        );
      }
    }
  }

  bool _ownsConnection(_AndroidDaemonConnection connection) =>
      identical(_connection, connection) && !connection.isShuttingDown;

  @visibleForTesting
  bool get hasOwnedDaemonIsolate =>
      _activeAttempt?.hasOwnedDaemonIsolate == true ||
      _connection?.hasOwnedDaemonIsolate == true;

  void _attachDiscoveryBridge(
    _AndroidDaemonConnection connection,
    AndroidDiscoveryBridge bridge,
  ) {
    if (!_ownsConnection(connection)) {
      throw StateError(
          'Android daemon transport disconnected during discovery');
    }
    connection.discoveryBridge = bridge;
    connection.discoveryAddedSub = bridge.onPeerDiscovered.listen((peer) {
      connection.addIncoming(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'rift.onPeerDiscovered',
        'params': peer.toIpcMap(),
      }));
      _syncDiscoverySnapshotToDaemon(connection);
    });
    connection.discoveryLostSub = bridge.onPeerLost.listen((peer) {
      connection.addIncoming(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'rift.onPeerLost',
        'params': {
          if (peer.deviceIdHint != null) 'deviceId': peer.deviceIdHint,
          'instanceId': peer.instanceId,
        },
      }));
      _syncDiscoverySnapshotToDaemon(connection);
    });
    connection.discoveryRetrySub =
        bridge.onReverseTcpPingRequested.listen((peer) {
      final port = connection.rpcPort;
      final deviceId = peer.deviceIdHint;
      if (port == null || deviceId == null || !_ownsConnection(connection)) {
        return;
      }
      port.send({
        'internal': 'android.prefetchPeer',
        'deviceId': deviceId,
      });
    });
    _syncDiscoverySnapshotToDaemon(connection);
  }

  Future<void> _bootstrapRootDiscovery(
    _AndroidDaemonConnection connection,
  ) async {
    if (connection.rpcPort == null || connection.discoveryBridge != null) {
      return;
    }

    final deviceId = connection.daemonDeviceId;
    final advertisedPort = connection.daemonAdvertisedPort;
    if (deviceId == null || advertisedPort == null) {
      throw StateError(
        'Android discovery metadata is incomplete. Wait for daemon startup to finish, then try again.',
      );
    }

    final bridge = _bindings.createDiscoveryBridge(
      port: advertisedPort,
      deviceIdHint: deviceId,
      fingerprintPrefix: connection.daemonFingerprintPrefix,
    );
    await bridge.ensureAdvertising();
    if (!_ownsConnection(connection)) {
      await bridge.dispose();
      throw StateError(
          'Android daemon transport disconnected during discovery');
    }
    _attachDiscoveryBridge(connection, bridge);
    if (await _shouldAutoStartDiscovery(connection)) {
      if (_ownsConnection(connection)) {
        await bridge.startDiscovery();
        _syncDiscoverySnapshotToDaemon(connection);
      }
    }
  }

  Future<bool> _shouldAutoStartDiscovery(
    _AndroidDaemonConnection connection,
  ) async {
    final trusted = await _invokeDaemonBootstrapRpc(
      connection,
      'rift.listTrustedPeers',
    );
    return (trusted['peers'] as List?)?.isNotEmpty == true;
  }

  Future<Map<String, dynamic>> _invokeDaemonBootstrapRpc(
    _AndroidDaemonConnection connection,
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final port = connection.rpcPort;
    if (port == null || !_ownsConnection(connection)) {
      throw StateError(
        'Daemon bootstrap RPC requested while transport is disconnected',
      );
    }

    final id = 'transport-bootstrap-${_nextBootstrapRequestId--}';
    final completer = Completer<Map<String, dynamic>>();
    connection.bootstrapRequests[id] = completer;
    port.send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });

    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } finally {
      connection.bootstrapRequests.remove(id);
    }
  }

  @visibleForTesting
  Future<Map<String, dynamic>> invokeDaemonBootstrapRpcForTesting(
    String method,
  ) {
    final connection = _connection;
    if (connection == null) {
      throw StateError('Android daemon is not connected');
    }
    return _invokeDaemonBootstrapRpc(connection, method);
  }

  Future<AndroidDiscoveryBridge> _ensureDiscoveryBridge(
    _AndroidDaemonConnection connection,
  ) {
    if (!_ownsConnection(connection)) {
      throw StateError('Android daemon is not connected');
    }
    final existing = connection.discoveryBridge;
    if (existing != null) {
      return Future.value(existing);
    }

    final pending = connection.discoveryBridgeFuture;
    if (pending != null) {
      return pending;
    }

    final future = _bootstrapDiscoveryBridge(connection);
    connection.discoveryBridgeFuture = future;
    return future.whenComplete(() {
      if (identical(connection.discoveryBridgeFuture, future)) {
        connection.discoveryBridgeFuture = null;
      }
    });
  }

  Future<AndroidDiscoveryBridge> _bootstrapDiscoveryBridge(
    _AndroidDaemonConnection connection,
  ) async {
    if (connection.daemonDeviceId == null ||
        connection.daemonAdvertisedPort == null) {
      throw StateError(
        'Android discovery is not ready yet. Wait a moment for the daemon to finish startup, then try again.',
      );
    }

    await _bootstrapRootDiscovery(connection);
    final bridge = connection.discoveryBridge;
    if (bridge == null || !_ownsConnection(connection)) {
      throw StateError(
        'Android discovery bridge failed to initialize. Restart the app and try discovery again.',
      );
    }

    return bridge;
  }

  bool _interceptDiscoveryRpc(
    _AndroidDaemonConnection connection,
    Map<String, dynamic> decoded,
  ) {
    final method = decoded['method'];
    final id = decoded['id'];
    if (method is! String || id == null) {
      return false;
    }

    switch (method) {
      case 'rift.listDiscoveredPeers':
        _emitSyntheticResult(connection, id, {
          'peers': connection.discoveryBridge?.listPeersForIpc() ?? const [],
          'isDiscovering': connection.discoveryBridge?.isDiscovering == true,
        });
        return true;
      case 'rift.startDiscovery':
        _handleSyntheticDiscoveryRequest(
          connection: connection,
          id: id,
          action: () async {
            final bridge = await _ensureDiscoveryBridge(connection);
            await bridge.startDiscovery();
            _syncDiscoverySnapshotToDaemon(connection);
            return {'started': true};
          },
        );
        return true;
      case 'rift.stopDiscovery':
        _handleSyntheticDiscoveryRequest(
          connection: connection,
          id: id,
          action: () async {
            final bridge = await _ensureDiscoveryBridge(connection);
            await bridge.stopDiscovery();
            _syncDiscoverySnapshotToDaemon(connection);
            return {'stopped': true};
          },
        );
        return true;
      default:
        return false;
    }
  }

  void _handleSyntheticDiscoveryRequest({
    required _AndroidDaemonConnection connection,
    required Object id,
    required Future<Map<String, dynamic>> Function() action,
  }) {
    action().then((result) {
      _emitSyntheticResult(connection, id, result);
    }).catchError((Object error, StackTrace stackTrace) {
      debugPrint(
        '[Android Discovery] Synthetic discovery RPC failed: $error\n$stackTrace',
      );
      _emitSyntheticError(connection, id, -32603, error.toString());
    });
  }

  void _emitSyntheticResult(
    _AndroidDaemonConnection connection,
    Object id,
    Map<String, dynamic> result,
  ) {
    connection.addIncoming(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }));
  }

  void _emitSyntheticError(
    _AndroidDaemonConnection connection,
    Object id,
    int code,
    String message,
  ) {
    connection.addIncoming(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': code,
        'message': message,
      },
    }));
  }

  void _syncDiscoverySnapshotToDaemon(
    _AndroidDaemonConnection connection,
  ) {
    final port = connection.rpcPort;
    final bridge = connection.discoveryBridge;
    if (port == null || bridge == null || !_ownsConnection(connection)) return;
    port.send({
      'internal': 'android.discoverySnapshot',
      'isDiscovering': bridge.isDiscovering,
      'peers': bridge.listPeersForDaemonControl(),
      'syncId': _nextSyntheticId++,
    });
  }

  Stream<String> get rawIncoming =>
      _connection?.incoming?.stream ?? const Stream<String>.empty();

  Future<void> sendRaw(String message) async {
    final connection = _connection;
    final outgoing = connection?.outgoing;
    if (connection == null || outgoing == null || connection.isShuttingDown) {
      throw StateError('Android daemon is not connected');
    }
    outgoing.add(message);
  }

  @override
  Future<void> disconnect() {
    final pending = _disconnectFuture;
    if (pending != null) {
      return pending;
    }

    _disconnecting = true;
    final attempt = _activeAttempt;
    final connection = _connection;
    final pendingConnect = _connectFuture;
    attempt?.beginShutdown();
    connection?.beginShutdown();
    if (identical(_activeAttempt, attempt)) {
      _activeAttempt = null;
    }
    if (identical(_connection, connection)) {
      _connection = null;
    }

    final future = _finishDisconnect(
      attempt: attempt,
      connection: connection,
      pendingConnect: pendingConnect,
    );
    _disconnectFuture = future;
    unawaited(future.whenComplete(() {
      if (identical(_disconnectFuture, future)) {
        _disconnectFuture = null;
        _disconnecting = false;
      }
    }));
    return future;
  }

  Future<void> _finishDisconnect({
    required _AndroidDaemonConnection? attempt,
    required _AndroidDaemonConnection? connection,
    required Future<StreamChannel<String>>? pendingConnect,
  }) async {
    if (pendingConnect != null) {
      try {
        await pendingConnect;
      } catch (_) {}
    }
    await attempt?.dispose();
    if (!identical(connection, attempt)) {
      await connection?.dispose();
    }
  }
}

class _AndroidDaemonConnection {
  _AndroidDaemonConnection(this.id);

  final int id;
  final Completer<SendPort> ready = Completer<SendPort>();
  final Completer<void> cancelled = Completer<void>();
  final Completer<void> isolateExited = Completer<void>();
  final Map<Object, Completer<Map<String, dynamic>>> bootstrapRequests =
      HashMap<Object, Completer<Map<String, dynamic>>>();

  ReceivePort? uiReceive;
  SendPort? rpcPort;
  StreamSubscription<dynamic>? uiSub;
  ReceivePort? errorPort;
  StreamSubscription<dynamic>? errorSub;
  ReceivePort? exitPort;
  StreamSubscription<dynamic>? exitSub;
  StreamController<String>? incoming;
  StreamController<String>? outgoing;
  StreamSubscription<String>? outgoingSub;
  AndroidDaemonTlsProxy? tlsProxy;
  AndroidDiscoveryBridge? discoveryBridge;
  Future<AndroidDiscoveryBridge>? discoveryBridgeFuture;
  StreamSubscription<AndroidDiscoveredPeer>? discoveryAddedSub;
  StreamSubscription<AndroidDiscoveredPeer>? discoveryLostSub;
  StreamSubscription<AndroidDiscoveredPeer>? discoveryRetrySub;
  String? daemonDeviceId;
  int? daemonAdvertisedPort;
  String? daemonFingerprintPrefix;

  void Function()? _killIsolate;
  bool _isolateKilled = false;
  bool _isShuttingDown = false;
  Future<void>? _disposeFuture;

  bool get isShuttingDown => _isShuttingDown;
  bool get hasOwnedDaemonIsolate =>
      _killIsolate != null && !isolateExited.isCompleted;

  StreamChannel<String> get channel => StreamChannel<String>(
        incoming!.stream,
        outgoing!.sink,
      );

  void ownDaemonIsolate(void Function() killIsolate) {
    if (_killIsolate != null) {
      throw StateError('Daemon isolate attempt $id already owns a child');
    }
    _killIsolate = killIsolate;
    if (_isShuttingDown) {
      _killOwnedIsolate();
    }
  }

  void markIsolateExited() {
    if (isolateExited.isCompleted) return;
    isolateExited.complete();
    debugPrint(
      _isolateKilled
          ? '[Android Daemon Transport] daemon isolate killed attempt=$id'
          : '[Android Daemon Transport] daemon isolate exited attempt=$id',
    );
  }

  void beginShutdown() {
    if (!_isShuttingDown) {
      _isShuttingDown = true;
      if (!cancelled.isCompleted) {
        cancelled.complete();
      }
    }
    rpcPort = null;
    _killOwnedIsolate();
  }

  void _killOwnedIsolate() {
    final killIsolate = _killIsolate;
    if (killIsolate == null || _isolateKilled) return;
    _isolateKilled = true;
    try {
      killIsolate();
    } catch (error) {
      debugPrint(
        '[Android Daemon Transport] failed to kill daemon isolate '
        'attempt=$id: $error',
      );
    }
    debugPrint(
      '[Android Daemon Transport] daemon isolate kill requested attempt=$id',
    );
  }

  void addIncoming(String message) {
    final controller = incoming;
    if (!_isShuttingDown && controller != null && !controller.isClosed) {
      controller.add(message);
    }
  }

  void addIncomingError(Object error, [StackTrace? stackTrace]) {
    final controller = incoming;
    if (!_isShuttingDown && controller != null && !controller.isClosed) {
      if (stackTrace == null) {
        controller.addError(error);
      } else {
        controller.addError(error, stackTrace);
      }
    }
  }

  void closeIncoming() {
    final controller = incoming;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    beginShutdown();
    final disconnectedError = StateError(
      'Android daemon transport disconnected (attempt=$id)',
    );
    for (final completer in bootstrapRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(disconnectedError);
      }
    }
    bootstrapRequests.clear();

    Future<void> clean(
      String resource,
      Future<void> Function() action,
    ) async {
      try {
        await action();
      } catch (error) {
        debugPrint(
          '[Android Daemon Transport] cleanup failed '
          'attempt=$id resource=$resource: $error',
        );
      }
    }

    if (_killIsolate != null && !isolateExited.isCompleted) {
      await clean('daemon-isolate-exit', () => isolateExited.future);
    }
    _killIsolate = null;

    await clean('discovery-added-subscription', () async {
      await discoveryAddedSub?.cancel();
      discoveryAddedSub = null;
    });
    await clean('discovery-lost-subscription', () async {
      await discoveryLostSub?.cancel();
      discoveryLostSub = null;
    });
    await clean('discovery-retry-subscription', () async {
      await discoveryRetrySub?.cancel();
      discoveryRetrySub = null;
    });
    final pendingDiscovery = discoveryBridgeFuture;
    if (pendingDiscovery != null) {
      await clean('discovery-bootstrap', () async {
        await pendingDiscovery;
      });
    }
    discoveryBridgeFuture = null;
    await clean('discovery-bridge', () async {
      await discoveryBridge?.dispose();
      discoveryBridge = null;
    });
    await clean('tls-proxy', () async {
      await tlsProxy?.dispose();
      tlsProxy = null;
    });
    await clean('outgoing-subscription', () async {
      await outgoingSub?.cancel();
      outgoingSub = null;
    });
    await clean('ui-subscription', () async {
      await uiSub?.cancel();
      uiSub = null;
    });
    await clean('error-subscription', () async {
      await errorSub?.cancel();
      errorSub = null;
    });
    await clean('exit-subscription', () async {
      await exitSub?.cancel();
      exitSub = null;
    });
    await clean('outgoing-controller', () async {
      final controller = outgoing;
      outgoing = null;
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
    });
    await clean('incoming-controller', () async {
      final controller = incoming;
      incoming = null;
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
    });

    uiReceive?.close();
    uiReceive = null;
    errorPort?.close();
    errorPort = null;
    exitPort?.close();
    exitPort = null;
    daemonDeviceId = null;
    daemonAdvertisedPort = null;
    daemonFingerprintPrefix = null;
  }
}
