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
  final Map<String, Future<dynamic>> _pendingStartPairings = {};
  final Map<String, Future<dynamic>> _pendingEndpointPairings = {};

  JsonRpcRiftClient(this._transport);

  bool get isConnected => _isConnected;

  late final _peerDiscoveredController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPeerDiscovered =>
      _peerDiscoveredController.stream;

  late final _peerLostController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPeerLost => _peerLostController.stream;

  late final _trustChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onTrustChanged =>
      _trustChangedController.stream;

  late final _pairingRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPairingRequest =>
      _pairingRequestController.stream;

  late final _pairingCompleteController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onPairingComplete =>
      _pairingCompleteController.stream;

  late final _securityEventController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSecurityEvent =>
      _securityEventController.stream;

  late final _clipboardOfferController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onClipboardOffer =>
      _clipboardOfferController.stream;

  late final _clipboardExpiredController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onClipboardExpired =>
      _clipboardExpiredController.stream;

  late final _operationTransitionController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onOperationTransition =>
      _operationTransitionController.stream;

  late final _connectionChangedController =
      StreamController<bool>.broadcast();
  Stream<bool> get onConnectionChanged => _connectionChangedController.stream;

  late final _operationTransitionController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onOperationTransition =>
      _operationTransitionController.stream;

  Map<String, dynamic>? _asMap(json_rpc.Parameters params) {
    if (params.value is! Map) return null;
    return _canonicalizeMap(Map<String, dynamic>.from(params.value as Map));
  }

  Map<String, dynamic>? _asTrustChangeMap(json_rpc.Parameters params) {
    final payload = _asMap(params);
    if (payload == null) {
      return null;
    }

    final normalized = Map<String, dynamic>.from(payload);
    for (final key in const ['previousState', 'newState']) {
      final value = normalized[key];
      if (value is String) {
        normalized[key] = _canonicalizeTrustState(value);
      }
    }
    return normalized;
  }

  bool _hasString(Map<String, dynamic> m, String key) =>
      m[key] is String && (m[key] as String).isNotEmpty;

  // Cross-implementation IPC: daemon-cs serializes PascalCase property names by
  // default, while daemon-dart uses lowerCamelCase. Canonicalize to the IPC spec
  // (lowerCamelCase) so UI code can be uniform.
  static const Map<String, String> _keyAliases = {
    'DeviceId': 'deviceId',
    'Fingerprint': 'fingerprint',
    'PeerFingerprint': 'peerFingerprint',
    'ExpiresInMs': 'expiresInMs',
    'ImplementationId': 'implementationId',
    'ProtocolVersion': 'protocolVersion',
    'Capabilities': 'capabilities',
    'Name': 'name',
    'Version': 'version',
    'Peers': 'peers',
    'TrustState': 'trustState',
    'DisplayName': 'displayName',
    'Address': 'address',
    'Port': 'port',
    'TxtRecord': 'txtRecord',
    'IsDiscovering': 'isDiscovering',
    'Started': 'started',
    'Stopped': 'stopped',
    'MinV': 'minV',
    'MaxV': 'maxV',
    'Did': 'did',
    'Fp': 'fp',
    'PreviousState': 'previousState',
    'NewState': 'newState',
    'NextState': 'nextState',
    'Reason': 'reason',
    'Status': 'status',
    'Presence': 'presence',
    'PairedAt': 'pairedAt',
    'LastSeenAt': 'lastSeenAt',
    'TrustedDeviceId': 'trustedDeviceId',
    'PersistedAt': 'persistedAt',
    'RevokedAt': 'revokedAt',
    'Revoked': 'revoked',
    'Rejected': 'rejected',
    'Unblocked': 'unblocked',
    'Reset': 'reset',
    'Events': 'events',
    'Total': 'total',
    'EventId': 'eventId',
    'EventType': 'eventType',
    'Severity': 'severity',
    'LocalDeviceId': 'localDeviceId',
    'PeerDeviceId': 'peerDeviceId',
    'OperationId': 'operationId',
    'Timestamp': 'timestamp',
    'Outcome': 'outcome',
    'FailureReason': 'failureReason',
    'Details': 'details',
    'OfferId': 'offerId',
    'OperationType': 'operationType',
    'State': 'state',
    'SourceDeviceId': 'sourceDeviceId',
    'DestinationDeviceId': 'destinationDeviceId',
    'CreatedAt': 'createdAt',
    'UpdatedAt': 'updatedAt',
    'Transitions': 'transitions',
    'From': 'from',
    'To': 'to',
    'At': 'at',
    'Operations': 'operations',
    'ContentType': 'contentType',
    'ByteSize': 'byteSize',
    'Sha256': 'sha256',
    'ExpiresAt': 'expiresAt',
    'ContentBase64': 'contentBase64',
    'Verified': 'verified',
    'Offers': 'offers',
    'BroadcastTo': 'broadcastTo',
  };

  static Map<String, dynamic> _canonicalizeMap(Map<String, dynamic> input) {
    final out = <String, dynamic>{};
    input.forEach((k, v) {
      final key = _keyAliases[k] ?? k;
      final value = _canonicalizeValue(v);
      out[key] = _canonicalizeFieldValue(key, value);
    });
    return out;
  }

  static dynamic _canonicalizeValue(dynamic v) {
    if (v is Map) {
      return _canonicalizeMap(Map<String, dynamic>.from(v));
    }
    if (v is List) {
      return v.map(_canonicalizeValue).toList(growable: false);
    }
    return v;
  }

  static dynamic _canonicalizeResult(dynamic result) {
    if (result is Map<String, dynamic>) return _canonicalizeMap(result);
    if (result is Map) {
      return _canonicalizeMap(Map<String, dynamic>.from(result));
    }
    return result;
  }

  static dynamic _canonicalizeFieldValue(String key, dynamic value) {
    if (value is! String) {
      return value;
    }

    switch (key) {
      case 'trustState':
        return _canonicalizeTrustState(value);
      case 'state':
      case 'from':
      case 'to':
      case 'previousState':
      case 'newState':
      case 'nextState':
        return value;
      case 'severity':
      case 'outcome':
        return value.toLowerCase();
      default:
        return value;
    }
  }

  static String _canonicalizeTrustState(String value) {
    switch (value.toLowerCase()) {
      case 'pairingpending':
      case 'pairing_pending':
        return 'pairing_pending';
      case 'trusted':
        return 'trusted';
      case 'blocked':
        return 'blocked';
      case 'revoked':
        return 'revoked';
      case 'discovered':
        return 'discovered';
      default:
        return value.toLowerCase();
    }
  }

  static String formatDisplayError(Object error) {
    final raw = error.toString();
    final normalized = raw.replaceFirst(RegExp(r'^Exception:\s*'), '');
    final withoutJsonRpc =
        normalized.replaceFirst(RegExp(r'^JSON-RPC error -?\d+:\s*'), '');

    if (withoutJsonRpc.contains('Not connected to daemon')) {
      return 'Daemon not connected.';
    }
    if (withoutJsonRpc.contains('Failed to establish a secure session')) {
      return 'Could not establish a secure session with this device. Make sure both devices are reachable on the same local network, then try again.';
    }
    if (withoutJsonRpc.contains('Peer not found')) {
      return 'This device is no longer available.';
    }
    if (withoutJsonRpc.contains('blocked or revoked')) {
      return 'This device cannot be paired until its trust state is reset.';
    }
    if (withoutJsonRpc.contains('No pending pairing exists')) {
      return 'There is no pending pairing request for this device.';
    }
    if (withoutJsonRpc.contains('Fingerprint mismatch')) {
      return 'Fingerprint verification failed.';
    }
    if (withoutJsonRpc.contains('Connection failed. Tried:')) {
      return 'Could not connect to the local daemon.';
    }

    return withoutJsonRpc;
  }

  void _emitIfValid(
    String method,
    Map<String, dynamic>? payload,
    StreamController<Map<String, dynamic>> controller, {
    required List<String> requiredStringKeys,
  }) {
    if (payload == null) {
      _log.warning('$method notification ignored: payload is not an object');
      return;
    }
    for (final k in requiredStringKeys) {
      if (!_hasString(payload, k)) {
        _log.warning(
            '$method notification ignored: missing/invalid "$k": $payload');
        return;
      }
    }
    controller.add(payload);
  }

  void _setConnectionState(bool isConnected) {
    if (_isConnected == isConnected) {
      return;
    }

    _isConnected = isConnected;
    _connectionChangedController.add(isConnected);
  }

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

      _client!.registerMethod('rift.onPeerDiscovered',
          (json_rpc.Parameters params) {
        // Spec: { deviceId?, instanceId, address, port, txtRecord }. We require
        // instanceId to track peers across discovery lifecycle.
        _emitIfValid(
          'rift.onPeerDiscovered',
          _asMap(params),
          _peerDiscoveredController,
          requiredStringKeys: const ['instanceId'],
        );
      });
      _client!.registerMethod('rift.onPeerLost', (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onPeerLost',
          _asMap(params),
          _peerLostController,
          requiredStringKeys: const ['instanceId'],
        );
      });
      _client!.registerMethod('rift.onTrustChanged',
          (json_rpc.Parameters params) {
        // Spec: { deviceId, previousState, newState, reason? }
        _emitIfValid(
          'rift.onTrustChanged',
          _asTrustChangeMap(params),
          _trustChangedController,
          requiredStringKeys: const ['deviceId', 'newState'],
        );
      });
      _client!.registerMethod('rift.onPairingRequest',
          (json_rpc.Parameters params) {
        // Spec: { deviceId, fingerprint, displayName?, expiresInMs }
        _emitIfValid(
          'rift.onPairingRequest',
          _asMap(params),
          _pairingRequestController,
          requiredStringKeys: const ['deviceId', 'fingerprint'],
        );
      });
      _client!.registerMethod('rift.onPairingComplete',
          (json_rpc.Parameters params) {
        // Spec: { deviceId, fingerprint, persistedAt }
        _emitIfValid(
          'rift.onPairingComplete',
          _asMap(params),
          _pairingCompleteController,
          requiredStringKeys: const ['deviceId', 'fingerprint'],
        );
      });
      _client!.registerMethod('rift.onOperationTransition',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onOperationTransition',
          _asMap(params),
          _operationTransitionController,
          requiredStringKeys: const ['operationId', 'status'],
        );
      });
      _client!.registerMethod('rift.onSecurityEvent',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onSecurityEvent',
          _asMap(params),
          _securityEventController,
          requiredStringKeys: const ['eventId', 'eventType', 'severity'],
        );
      });
      _client!.registerMethod('rift.onClipboardOffer',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onClipboardOffer',
          _asMap(params),
          _clipboardOfferController,
          requiredStringKeys: const [
            'offerId',
            'sourceDeviceId',
            'contentType',
            'sha256',
          ],
        );
      });
      _client!.registerMethod('rift.onClipboardExpired',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onClipboardExpired',
          _asMap(params),
          _clipboardExpiredController,
          requiredStringKeys: const ['offerId'],
        );
      });
      _client!.registerMethod('rift.onOperationTransition',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onOperationTransition',
          _asMap(params),
          _operationTransitionController,
          requiredStringKeys: const [
            'operationId',
            'operationType',
            'previousState',
            'nextState',
          ],
        );
      });
      // Start listening to the RPC channel
      unawaited(_client!.listen().then((_) {
        _log.warning('RPC Connection closed');
        unawaited(_handleDisconnect());
      }).catchError((e) {
        _log.severe('RPC Connection error: $e');
        unawaited(_handleDisconnect());
      }));

      _setConnectionState(true);
      _reconnectAttempts = 0;
      _log.info('Connected to daemon successfully');
    } catch (e) {
      _log.severe('Failed to connect: $e');
      _setConnectionState(false);
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

    _setConnectionState(false);
    _client = null;

    // Fire and forget closures to prevent hanging in async tests
    unawaited(_outController?.close());
    _outController = null;

    try {
      await _transport.disconnect();
    } catch (e) {
      _log.warning('Error during disconnect: $e');
    }

    // Exponential Backoff Reconnect (infinite retries, capped delay)
    final delaySeconds = (1 << _reconnectAttempts).clamp(1, 5);
    final delay = Duration(seconds: delaySeconds);
    
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
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    _setConnectionState(false);
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
    await _pairingCompleteController.close();
    await _operationTransitionController.close();
    await _securityEventController.close();
    await _clipboardOfferController.close();
    await _clipboardExpiredController.close();
    await _operationTransitionController.close();
    await _connectionChangedController.close();
  }

  Future<dynamic> getDeviceInfo() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.getDeviceInfo');
    return _canonicalizeResult(r);
  }

  Future<dynamic> listDiscoveredPeers() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.listDiscoveredPeers');
    return _canonicalizeResult(r);
  }

  Future<dynamic> listTrustedPeers() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.listTrustedPeers');
    return _canonicalizeResult(r);
  }

  Future<dynamic> listOperations({
    int? limit,
    int? offset,
  }) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final params = <String, dynamic>{};
    if (limit != null) params['limit'] = limit;
    if (offset != null) params['offset'] = offset;
    final r = await _client!.sendRequest('rift.listOperations', params);
    return _canonicalizeResult(r);
  }

  Future<dynamic> queryEventLog({
    List<String>? eventTypes,
    List<String>? severities,
    String? peerDeviceId,
    String? since,
    int limit = 100,
    int offset = 0,
  }) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final params = <String, dynamic>{
      'limit': limit,
      'offset': offset,
    };
    if (eventTypes != null && eventTypes.isNotEmpty) {
      params['eventTypes'] = eventTypes;
    }
    if (severities != null && severities.isNotEmpty) {
      params['severities'] = severities;
    }
    if (peerDeviceId != null && peerDeviceId.isNotEmpty) {
      params['peerDeviceId'] = peerDeviceId;
    }
    if (since != null && since.isNotEmpty) {
      params['since'] = since;
    }
    final r = await _client!.sendRequest('rift.queryEventLog', params);
    return _canonicalizeResult(r);
  }

  Future<dynamic> startDiscovery() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.startDiscovery');
    return _canonicalizeResult(r);
  }

  Future<dynamic> stopDiscovery() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.stopDiscovery');
    return _canonicalizeResult(r);
  }

  Future<dynamic> startPairing(String deviceId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final pending = _pendingStartPairings[deviceId];
    if (pending != null) {
      _log.info('Joining in-flight startPairing request for $deviceId');
      return pending;
    }

    final future = _client!
        .sendRequest('rift.startPairing', {'deviceId': deviceId}).then(
      _canonicalizeResult,
    );
    _pendingStartPairings[deviceId] = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingStartPairings[deviceId], future)) {
        _pendingStartPairings.remove(deviceId);
      }
    }
  }

  Future<dynamic> startPairingByEndpoint(String address, int port) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final key = '$address:$port';
    final pending = _pendingEndpointPairings[key];
    if (pending != null) {
      _log.info('Joining in-flight startPairingByEndpoint request for $key');
      return pending;
    }

    final future = _client!
        .sendRequest('rift.startPairingByEndpoint', {
          'address': address,
          'port': port,
        }).then(_canonicalizeResult);
    _pendingEndpointPairings[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingEndpointPairings[key], future)) {
        _pendingEndpointPairings.remove(key);
      }
    }
  }

  Future<dynamic> approvePairing(String deviceId, String fingerprint) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.approvePairing', {
      'deviceId': deviceId,
      'fingerprint': fingerprint,
    });
    return _canonicalizeResult(r);
  }

  Future<dynamic> rejectPairing(String deviceId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!
        .sendRequest('rift.rejectPairing', {'deviceId': deviceId});
    return _canonicalizeResult(r);
  }

  Future<dynamic> revokeTrust(String deviceId, String reason) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.revokeTrust', {
      'deviceId': deviceId,
      'reason': reason,
    });
    return _canonicalizeResult(r);
  }

  Future<dynamic> unblockPeer(String deviceId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r =
        await _client!.sendRequest('rift.unblockPeer', {'deviceId': deviceId});
    return _canonicalizeResult(r);
  }

  Future<dynamic> resetRevokedPeer(String deviceId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!
        .sendRequest('rift.resetRevokedPeer', {'deviceId': deviceId});
    return _canonicalizeResult(r);
  }

  Future<dynamic> notifyClipboardChange({
    required String contentType,
    required int byteSize,
    required String sha256,
    required String contentBase64,
  }) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.notifyClipboardChange', {
      'contentType': contentType,
      'byteSize': byteSize,
      'sha256': sha256,
      'contentBase64': contentBase64,
    });
    return _canonicalizeResult(r);
  }

  Future<dynamic> listClipboardOffers() async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.listClipboardOffers');
    return _canonicalizeResult(r);
  }

  Future<dynamic> fetchClipboardContent(String offerId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest(
      'rift.fetchClipboardContent',
      {'offerId': offerId},
    );
    return _canonicalizeResult(r);
  }

  Future<dynamic> listOperations({int limit = 50, int offset = 0}) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.listOperations', {
      'limit': limit,
      'offset': offset,
    });
    return _canonicalizeResult(r);
  }

  Future<dynamic> getOperation(String operationId) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest('rift.getOperation', {
      'operationId': operationId,
    });
    return _canonicalizeResult(r);
  }

  Future<dynamic> invokeRpc(String method, [dynamic parameters]) async {
    if (!_isConnected || _client == null) {
      throw StateError('Not connected to daemon');
    }
    final r = await _client!.sendRequest(method, parameters);
    return _canonicalizeResult(r);
  }
}
