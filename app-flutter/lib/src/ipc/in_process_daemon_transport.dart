import 'dart:async';
import 'dart:convert';

import 'package:daemon_dart/daemon_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:stream_channel/stream_channel.dart';

import 'ipc_transport.dart';

abstract class InProcessDaemon {
  Future<void> start();
  Future<void> stop();
  Future<Map<String, dynamic>> handleJsonRpcRequest(
    Map<String, dynamic> request,
  );
}

class RiftInProcessDaemon implements InProcessDaemon {
  final RiftDaemon _daemon;

  RiftInProcessDaemon._(this._daemon);

  factory RiftInProcessDaemon({
    required String storagePath,
    required void Function(Map<String, dynamic>) onIpcEvent,
  }) {
    return RiftInProcessDaemon._(
      RiftDaemon(
        storagePath: storagePath,
        onIpcEvent: onIpcEvent,
      ),
    );
  }

  @override
  Future<void> start() => _daemon.start();

  @override
  Future<void> stop() => _daemon.stop();

  @override
  Future<Map<String, dynamic>> handleJsonRpcRequest(
    Map<String, dynamic> request,
  ) =>
      _daemon.handleJsonRpcRequest(request);
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
  Future<StreamChannel<String>> connect() async {
    if (_incoming != null && _outgoing != null) {
      return StreamChannel<String>(_incoming!.stream, _outgoing!.sink);
    }

    final storagePath = await _storagePathProvider();
    _incoming = StreamController<String>.broadcast();
    _outgoing = StreamController<String>();
    _daemon = _daemonFactory(storagePath, _handleDaemonEvent);
    await _daemon!.start();

    _outgoingSubscription = _outgoing!.stream.listen(
      (message) {
        unawaited(_handleClientMessage(message));
      },
      onDone: () {
        unawaited(disconnect());
      },
    );

    return StreamChannel<String>(_incoming!.stream, _outgoing!.sink);
  }

  void _handleDaemonEvent(Map<String, dynamic> event) {
    _incoming?.add(jsonEncode(event));
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
  }
}
