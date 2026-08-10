import 'dart:async';
import 'dart:convert';

import 'package:daemon_dart/daemon_dart.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:stream_channel/stream_channel.dart';

import 'ipc_transport.dart';
import 'android_native_peer_transport.dart';

abstract class InProcessDaemon {
  Future<void> start();
  Future<void> stop();
  Future<Map<String, dynamic>> handleJsonRpcRequest(
    Map<String, dynamic> request,
  );
}

class RiftInProcessDaemon implements InProcessDaemon {
  static const _identityChannel = MethodChannel('rift/ios/identity');

  final String _storagePath;
  final void Function(Map<String, dynamic>) _onIpcEvent;
  RiftDaemon? _daemon;

  RiftInProcessDaemon({
    required String storagePath,
    required void Function(Map<String, dynamic>) onIpcEvent,
  })  : _storagePath = storagePath,
        _onIpcEvent = onIpcEvent;

  static Future<Uint8List> _loadIdentityKey(String storagePath) async {
    final key = await _identityChannel.invokeMethod<Uint8List>(
      'loadOrCreate',
      {'legacyPath': '$storagePath/identity.key'},
    );
    if (key == null) {
      throw StateError('iOS Keychain returned no identity key.');
    }
    return key;
  }

  static Future<String?> _loadDisplayName() async {
    final info = await _identityChannel.invokeMethod<Map<Object?, Object?>>(
      'getDeviceInfo',
    );
    return info?['displayName']?.toString();
  }

  @override
  Future<void> start() async {
    final daemon = RiftDaemon(
      storagePath: _storagePath,
      identityPrivateKeyProvider: () => _loadIdentityKey(_storagePath),
      localDisplayName: await _loadDisplayName(),
      onIpcEvent: _onIpcEvent,
      peerTransportFactory: (identityManager, port) =>
          AndroidNativePeerTransport(identityManager, port: port),
    );
    _daemon = daemon;
    await daemon.start();
  }

  @override
  Future<void> stop() async {
    await _daemon?.stop();
    _daemon = null;
  }

  @override
  Future<Map<String, dynamic>> handleJsonRpcRequest(
    Map<String, dynamic> request,
  ) {
    final daemon = _daemon;
    if (daemon == null) {
      throw StateError('iOS in-process daemon is not started.');
    }
    return daemon.handleJsonRpcRequest(request);
  }
}

class InProcessDaemonTransport implements IpcTransport {
  final Future<String> Function() _storagePathProvider;
  final InProcessDaemon Function(
    String storagePath,
    void Function(Map<String, dynamic>) onIpcEvent,
  ) _daemonFactory;

  InProcessDaemon? _daemon;
  StreamController<String>? _incoming;
  StreamController<String>? _outgoing;
  StreamSubscription<String>? _outgoingSubscription;
  Future<StreamChannel<String>>? _connecting;
  final List<String> _pendingDaemonEvents = [];

  InProcessDaemonTransport({
    Future<String> Function()? storagePathProvider,
    InProcessDaemon Function(
      String storagePath,
      void Function(Map<String, dynamic>) onIpcEvent,
    )? daemonFactory,
  })  : _storagePathProvider =
            storagePathProvider ?? _defaultStoragePathProvider,
        _daemonFactory = daemonFactory ?? _defaultDaemonFactory;

  static Future<String> _defaultStoragePathProvider() async {
    final directory = await getApplicationSupportDirectory();
    return directory.path;
  }

  static InProcessDaemon _defaultDaemonFactory(
    String storagePath,
    void Function(Map<String, dynamic>) onIpcEvent,
  ) {
    return RiftInProcessDaemon(
      storagePath: storagePath,
      onIpcEvent: onIpcEvent,
    );
  }

  @override
  Future<StreamChannel<String>> connect() {
    if (_daemon != null && _incoming != null && _outgoing != null) {
      return Future.value(
        StreamChannel<String>(_incoming!.stream, _outgoing!.sink),
      );
    }

    return _connecting ??= _connect();
  }

  Future<StreamChannel<String>> _connect() async {
    try {
      final storagePath = await _storagePathProvider();
      _incoming = StreamController<String>.broadcast(
        onListen: _flushPendingDaemonEvents,
      );
      _outgoing = StreamController<String>.broadcast();
      _daemon = _daemonFactory(storagePath, _handleDaemonEvent);
      await _daemon!.start();

      _outgoingSubscription = _outgoing!.stream.listen(
        (message) {
          unawaited(_handleClientMessage(message));
        },
        onDone: () {
          _outgoingSubscription = null;
          unawaited(disconnect());
        },
      );

      return StreamChannel<String>(_incoming!.stream, _outgoing!.sink);
    } catch (_) {
      try {
        await _daemon?.stop();
      } catch (_) {}
      await _outgoing?.close();
      await _incoming?.close();
      _daemon = null;
      _outgoing = null;
      _incoming = null;
      _pendingDaemonEvents.clear();
      rethrow;
    } finally {
      _connecting = null;
    }
  }

  void _handleDaemonEvent(Map<String, dynamic> event) {
    final message = jsonEncode(event);
    final incoming = _incoming;
    if (incoming == null) {
      return;
    }
    if (!incoming.hasListener) {
      _pendingDaemonEvents.add(message);
      return;
    }
    incoming.add(message);
  }

  void _flushPendingDaemonEvents() {
    final incoming = _incoming;
    if (incoming == null) {
      return;
    }
    for (final message in _pendingDaemonEvents) {
      incoming.add(message);
    }
    _pendingDaemonEvents.clear();
  }

  Future<void> _handleClientMessage(String message) async {
    final incoming = _incoming;
    final daemon = _daemon;
    if (incoming == null || daemon == null) {
      return;
    }

    Object? id;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map) {
        incoming.add(
          jsonEncode(RiftDaemon.jsonRpcError(null, -32600, 'Invalid Request')),
        );
        return;
      }

      final request = Map<String, dynamic>.from(decoded);
      id = request['id'];
      final result = await daemon.handleJsonRpcRequest(request);
      incoming.add(jsonEncode(RiftDaemon.jsonRpcResult(id, result)));
    } on FormatException {
      incoming
          .add(jsonEncode(RiftDaemon.jsonRpcError(id, -32700, 'Parse error')));
    } on UnsupportedError catch (error) {
      incoming.add(
          jsonEncode(RiftDaemon.jsonRpcError(id, -32601, error.toString())));
    } on ArgumentError catch (error) {
      incoming.add(
        jsonEncode(
          RiftDaemon.jsonRpcError(
            id,
            -32602,
            error.message?.toString() ?? error.toString(),
          ),
        ),
      );
    } on RiftException catch (error) {
      incoming.add(
        jsonEncode(RiftDaemon.jsonRpcError(id, error.code, error.message)),
      );
    } catch (error) {
      incoming.add(
          jsonEncode(RiftDaemon.jsonRpcError(id, -32603, error.toString())));
    }
  }

  @override
  Future<void> disconnect() async {
    await _outgoingSubscription?.cancel();
    _outgoingSubscription = null;
    await _daemon?.stop();
    _daemon = null;
    await _outgoing?.close();
    await _incoming?.close();
    _outgoing = null;
    _incoming = null;
    _pendingDaemonEvents.clear();
  }
}
