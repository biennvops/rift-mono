import 'dart:async';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';

class JsonRpcRiftClient {
  final IpcTransport _transport;
  final _log = Logger('JsonRpcRiftClient');

  json_rpc.Peer? _client;
  bool _isConnected = false;

  JsonRpcRiftClient(this._transport);

  bool get isConnected => _isConnected;

  late final _peerDiscoveredController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPeerDiscovered => _peerDiscoveredController.stream;

  late final _peerLostController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPeerLost => _peerLostController.stream;

  late final _trustChangedController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onTrustChanged => _trustChangedController.stream;

  late final _pairingRequestController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPairingRequest => _pairingRequestController.stream;

  late final _pairingApprovedController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPairingApproved => _pairingApprovedController.stream;

  late final _pairingCompleteController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPairingComplete => _pairingCompleteController.stream;

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

      _client = json_rpc.Peer(loggingChannel);

      _client!.registerMethod('rift.onPeerDiscovered', (json_rpc.Parameters params) {
        if (params.value is Map) {
          _peerDiscoveredController.add(Map<String, dynamic>.from(params.value as Map));
        }
      });
      _client!.registerMethod('rift.onPeerLost', (json_rpc.Parameters params) {
        if (params.value is Map) {
          _peerLostController.add(Map<String, dynamic>.from(params.value as Map));
        }
      });
      _client!.registerMethod('rift.onTrustChanged', (json_rpc.Parameters params) {
        if (params.value is Map) {
          _trustChangedController.add(Map<String, dynamic>.from(params.value as Map));
        }
      });
      _client!.registerMethod('rift.onPairingRequest', (json_rpc.Parameters params) {
        if (params.value is Map) {
          _pairingRequestController.add(Map<String, dynamic>.from(params.value as Map));
        }
      });
      _client!.registerMethod('rift.onPairingApproved', (json_rpc.Parameters params) {
        if (params.value is Map) {
          _pairingApprovedController.add(Map<String, dynamic>.from(params.value as Map));
        }
      });
      _client!.registerMethod('rift.onPairingComplete', (json_rpc.Parameters params) {
        if (params.value is Map) {
          _pairingCompleteController.add(Map<String, dynamic>.from(params.value as Map));
        }
      });
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

  Future<void> dispose() async {
    await disconnect();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _trustChangedController.close();
    await _pairingRequestController.close();
    await _pairingApprovedController.close();
    await _pairingCompleteController.close();
  }

  Future<dynamic> getDeviceInfo() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.getDeviceInfo');
  }

  Future<dynamic> listDiscoveredPeers() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.listDiscoveredPeers');
  }

  Future<dynamic> listTrustedPeers() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.listTrustedPeers');
  }

  Future<dynamic> startDiscovery() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.startDiscovery');
  }

  Future<dynamic> stopDiscovery() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.stopDiscovery');
  }

  Future<dynamic> startPairing(String deviceId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.startPairing', {'deviceId': deviceId});
  }

  Future<dynamic> approvePairing(String deviceId, String fingerprint) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.approvePairing', {
      'deviceId': deviceId,
      'fingerprint': fingerprint,
    });
  }

  Future<dynamic> rejectPairing(String deviceId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.rejectPairing', {'deviceId': deviceId});
  }

  Future<dynamic> revokeTrust(String deviceId, String reason) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.revokeTrust', {
      'deviceId': deviceId,
      'reason': reason,
    });
  }

  Future<dynamic> unblockPeer(String deviceId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    return _client!.sendRequest('rift.unblockPeer', {'deviceId': deviceId});
  }
}
