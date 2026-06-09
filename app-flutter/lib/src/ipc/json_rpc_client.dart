import 'dart:async';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';

class JsonRpcRiftClient {
  final IpcTransport _transport;
  final _log = Logger('JsonRpcRiftClient');

  json_rpc.Client? _client;
  bool _isConnected = false;

  JsonRpcRiftClient(this._transport);

  bool get isConnected => _isConnected;

  Future<void> connect() async {
    if (_isConnected) return;

    _log.info('Connecting to daemon...');
    try {
      final channel = await _transport.connect();

      // Wrap channel to log raw payload (Risk Mitigation: behavior mismatch)
      _outController = StreamController<String>(sync: true);
      _outController!.stream.listen((event) {
        _log.fine('SEND: $event');
        channel.sink.add(event);
      },
          onDone: () => channel.sink.close(),
          onError: (e) => channel.sink.addError(e));

      final loggingChannel = StreamChannel<String>(
        channel.stream.map((event) {
          _log.fine('RECV: $event');
          return event;
        }),
        _outController!.sink,
      );

      _client = json_rpc.Client(loggingChannel);

      // Start listening to the RPC channel
      unawaited(_client!.listen().then((_) {
        _log.warning('RPC Connection closed');
        unawaited(_handleDisconnect());
      }).catchError((e) {
        _log.severe('RPC Connection error: $e');
        unawaited(_handleDisconnect());
      }));

      _isConnected = true;
      _reconnectAttempts = 0;
      _log.info('Connected to daemon successfully');
    } catch (e) {
      _log.severe('Failed to connect: $e');
      _isConnected = false;
      rethrow;
    }
  }

  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  StreamController<String>? _outController;

  bool _isReconnecting = false;

  Future<void> _handleDisconnect() async {
    if (_isReconnecting) return;
    _isReconnecting = true;
    
    _isConnected = false;
    _client = null;
    
    // Fire and forget closures to prevent hanging in async tests
    unawaited(_outController?.close());
    _outController = null;
    
    try {
      await _transport.disconnect();
    } catch (e) {
      _log.warning('Error during disconnect: $e');
    }

    // Exponential Backoff Reconnect
    if (_reconnectAttempts < 5) {
      final delay = Duration(seconds: 1 << _reconnectAttempts);
      _log.info(
          'Reconnecting in ${delay.inSeconds} seconds (Attempt ${_reconnectAttempts + 1})...');
      _reconnectTimer = Timer(delay, () {
        _reconnectAttempts++;
        connect().catchError((e) {
          _log.severe('Reconnect failed: $e');
        }).whenComplete(() {
          _isReconnecting = false;
        });
      });
    } else {
      _log.severe('Max reconnect attempts reached. Giving up.');
      _isReconnecting = false;
    }
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    _isConnected = false;
    _isReconnecting = false;
    await _client?.close();
    _client = null;
    await _outController?.close();
    _outController = null;
    await _transport.disconnect();
  }

  Future<dynamic> getDeviceInfo() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.getDeviceInfo');
  }
}
