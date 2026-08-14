import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
import 'ipc_transport.dart';

class JsonRpcRiftClient {
  final IpcTransport _transport;
  final json_rpc.Peer Function(StreamChannel<String>) _peerFactory;
  final _log = Logger('JsonRpcRiftClient');

  json_rpc.Peer? _client;
  bool _isConnected = false;
  final Map<String, Future<dynamic>> _pendingStartPairings = {};
  final Map<String, Future<dynamic>> _pendingEndpointPairings = {};
  bool? _supportsSendQueue;

  JsonRpcRiftClient(
    this._transport, {
    @visibleForTesting
    json_rpc.Peer Function(StreamChannel<String>)? peerFactory,
  }) : _peerFactory = peerFactory ?? json_rpc.Peer.new;

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

  late final _notificationPostedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onNotificationPosted =>
      _notificationPostedController.stream;

  late final _notificationUpdatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onNotificationUpdated =>
      _notificationUpdatedController.stream;

  late final _notificationRemovedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onNotificationRemoved =>
      _notificationRemovedController.stream;

  late final _notificationActionRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onNotificationActionRequest =>
      _notificationActionRequestController.stream;

  late final _notificationActionResultController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onNotificationActionResult =>
      _notificationActionResultController.stream;

  late final _deviceStatusUpdatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onDeviceStatusUpdated =>
      _deviceStatusUpdatedController.stream;

  late final _mediaPlaybackPostedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onMediaPlaybackPosted =>
      _mediaPlaybackPostedController.stream;

  late final _mediaPlaybackUpdatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onMediaPlaybackUpdated =>
      _mediaPlaybackUpdatedController.stream;

  late final _mediaPlaybackRemovedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onMediaPlaybackRemoved =>
      _mediaPlaybackRemovedController.stream;

  late final _mediaPlaybackActionResultController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onMediaPlaybackActionResult =>
      _mediaPlaybackActionResultController.stream;

  late final _mediaPlaybackActionRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onMediaPlaybackActionRequest =>
      _mediaPlaybackActionRequestController.stream;

  late final _fileOfferController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onFileOffer => _fileOfferController.stream;

  late final _fileTransferProgressController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onFileTransferProgress =>
      _fileTransferProgressController.stream;

  late final _fileTransferReadyToCommitController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onFileTransferReadyToCommit =>
      _fileTransferReadyToCommitController.stream;

  late final _fileTransferCompletedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onFileTransferCompleted =>
      _fileTransferCompletedController.stream;

  late final _fileTransferFailedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onFileTransferFailed =>
      _fileTransferFailedController.stream;

  Stream<Map<String, dynamic>> get onFileProgress => onFileTransferProgress;
  Stream<Map<String, dynamic>> get onFileCompleted => onFileTransferCompleted;
  Stream<Map<String, dynamic>> get onFileFailed => onFileTransferFailed;

  late final _operationTransitionController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onOperationTransition =>
      _operationTransitionController.stream;

  late final _sendQueueChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSendQueueChanged =>
      _sendQueueChangedController.stream;

  late final _sendQueueItemUpdatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSendQueueItemUpdated =>
      _sendQueueItemUpdatedController.stream;

  late final _connectionChangedController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionChanged => _connectionChangedController.stream;

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
    'IdentityProtectionBackend': 'identityProtectionBackend',
    'Capabilities': 'capabilities',
    'Name': 'name',
    'Version': 'version',
    'Peers': 'peers',
    'TrustState': 'trustState',
    'DisplayName': 'displayName',
    'Platform': 'platform',
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
    'Removed': 'removed',
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
    'DeviceStatus': 'deviceStatus',
    'SourceDeviceId': 'sourceDeviceId',
    'SourcePlatform': 'sourcePlatform',
    'BatteryPresent': 'batteryPresent',
    'BatteryPercent': 'batteryPercent',
    'ChargingState': 'chargingState',
    'PowerSource': 'powerSource',
    'LowPowerMode': 'lowPowerMode',
    'ObservedAt': 'observedAt',
    'IsStale': 'isStale',
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
    'TransferId': 'transferId',
    'FileName': 'fileName',
    'MediaType': 'mediaType',
    'ChunkSize': 'chunkSize',
    'ChunkCount': 'chunkCount',
    'DestinationPath': 'destinationPath',
    'Direction': 'direction',
    'BytesTransferred': 'bytesTransferred',
    'Transfers': 'transfers',
    'Commits': 'commits',
    'StagingPath': 'stagingPath',
    'Committed': 'committed',
    'Failed': 'failed',
    'Items': 'items',
    'QueueItemId': 'queueItemId',
    'TargetDeviceId': 'targetDeviceId',
    'CurrentOperationId': 'currentOperationId',
    'LastTransferId': 'lastTransferId',
    'FailureMessage': 'failureMessage',
    'Origin': 'origin',
    'ExpiresAt': 'expiresAt',
    'ContentBase64': 'contentBase64',
    'Verified': 'verified',
    'Offers': 'offers',
    'BroadcastTo': 'broadcastTo',
    'RequestId': 'requestId',
    'Notifications': 'notifications',
    'ObservedApps': 'observedApps',
    'NotificationId': 'notificationId',
    'PackageName': 'packageName',
    'AppName': 'appName',
    'Title': 'title',
    'BodyPreview': 'bodyPreview',
    'PostedAt': 'postedAt',
    'IsDismissible': 'isDismissible',
    'IsOpenable': 'isOpenable',
    'IsRemoved': 'isRemoved',
    'RemovedAt': 'removedAt',
    'Icon': 'icon',
    'Action': 'action',
    'Success': 'success',
    'BlacklistedPackages': 'blacklistedPackages',
    'Mode': 'mode',
    'PackageNames': 'packageNames',
    'Enabled': 'enabled',
    'Policy': 'policy',
    'PlaybackId': 'playbackId',
    'Playbacks': 'playbacks',
    'AppId': 'appId',
    'Artist': 'artist',
    'Album': 'album',
    'Artwork': 'artwork',
    'PlaybackState': 'playbackState',
    'PositionMs': 'positionMs',
    'DurationMs': 'durationMs',
    'CanPlay': 'canPlay',
    'CanPause': 'canPause',
    'CanSkipNext': 'canSkipNext',
    'CanSkipPrevious': 'canSkipPrevious',
    'CanSeek': 'canSeek',
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
    if (withoutJsonRpc.contains('Peer is blocked') ||
        withoutJsonRpc.contains('peer identity is blocked')) {
      return 'This device is blocked and cannot be paired until it is unblocked.';
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
    if (withoutJsonRpc.contains('Failed to reconnect trusted peer')) {
      return 'Could not reconnect to this trusted device. Make sure it is online and reachable on the same local network, then try again.';
    }

    return withoutJsonRpc;
  }

  static bool isMethodNotFoundError(Object error) {
    final raw = error.toString();
    return raw.contains('JSON-RPC error -32601') ||
        raw.toLowerCase().contains('method not found');
  }

  Never _throwNotConnected(String method, [dynamic parameters]) {
    final error = StateError('Not connected to daemon');
    _log.warning('RPC request failed before send: $method params=$parameters');
    debugPrint(
      '[JsonRpcRiftClient] RPC request failed before send: $method params=$parameters error=$error',
    );
    throw error;
  }

  Future<dynamic> _sendRequest(String method, [dynamic parameters]) async {
    final client = _client;
    if (!_isConnected || client == null) {
      _throwNotConnected(method, parameters);
    }

    try {
      final response = await client.sendRequest(method, parameters);
      return _canonicalizeResult(response);
    } catch (error, stackTrace) {
      _log.severe(
        'RPC request failed: $method params=$parameters error=$error',
        error,
        stackTrace,
      );
      debugPrint(
        '[JsonRpcRiftClient] RPC request failed: $method params=$parameters error=$error',
      );
      rethrow;
    }
  }

  void _emitIfValid(
    String method,
    Map<String, dynamic>? payload,
    StreamController<Map<String, dynamic>> controller, {
    required List<String> requiredStringKeys,
  }) {
    if (_disposed || controller.isClosed) {
      return;
    }
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
    // Drop the cached capability probe on any connection transition so a
    // daemon upgrade (or a mid-session feature enablement) can be
    // re-detected on the next supportsSendQueue() call.
    _supportsSendQueue = null;
    if (!_connectionChangedController.isClosed) {
      _connectionChangedController.add(isConnected);
    }
  }

  Future<void> connect() async {
    if (_disposed) {
      throw StateError('JsonRpcRiftClient has been disposed');
    }
    _intentionalDisconnect = false;
    if (_isConnected) return;
    final pending = _connectFuture;
    if (pending != null) {
      return pending;
    }
    if (_reconnectTimer != null) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _isReconnecting = false;
    }

    final epoch = ++_connectionEpoch;
    final future = _connectImpl(epoch);
    _connectFuture = future;
    try {
      await future;
    } finally {
      if (identical(_connectFuture, future)) {
        _connectFuture = null;
      }
    }
  }

  Future<void> _connectImpl(int epoch) async {
    final disconnecting = _transportDisconnectFuture;
    if (disconnecting != null) {
      await disconnecting;
    }
    if (!_canInstallConnection(epoch)) {
      return;
    }

    _log.info('Connecting to daemon (epoch=$epoch)...');
    try {
      final channel = await _transport.connect();
      if (!_canInstallConnection(epoch)) {
        await _disconnectTransport();
        return;
      }

      // Wrap channel to log raw payload (Risk Mitigation: behavior mismatch)
      final outController = StreamController<String>(sync: true);
      outController.stream.listen((event) {
        _log.fine('SEND: $event');
        channel.sink.add(event);
      }, onDone: () => channel.sink.close(), onError: channel.sink.addError);

      final loggingChannel = StreamChannel<String>(
        channel.stream.map((event) {
          _log.fine('RECV: $event');
          return event;
        }),
        outController.sink,
      );

      final peer = _peerFactory(loggingChannel);
      _outController = outController;
      _client = peer;

      peer.registerMethod('rift.onPeerDiscovered',
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
      peer.registerMethod('rift.onPeerLost', (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onPeerLost',
          _asMap(params),
          _peerLostController,
          requiredStringKeys: const ['instanceId'],
        );
      });
      peer.registerMethod('rift.onTrustChanged', (json_rpc.Parameters params) {
        // Spec: { deviceId, previousState, newState, reason? }
        _emitIfValid(
          'rift.onTrustChanged',
          _asTrustChangeMap(params),
          _trustChangedController,
          requiredStringKeys: const ['deviceId', 'newState'],
        );
      });
      peer.registerMethod('rift.onPairingRequest',
          (json_rpc.Parameters params) {
        // Spec: { deviceId, fingerprint, displayName?, expiresInMs }
        _emitIfValid(
          'rift.onPairingRequest',
          _asMap(params),
          _pairingRequestController,
          requiredStringKeys: const ['deviceId', 'fingerprint'],
        );
      });
      peer.registerMethod('rift.onPairingComplete',
          (json_rpc.Parameters params) {
        // Spec: { deviceId, fingerprint, persistedAt }
        _emitIfValid(
          'rift.onPairingComplete',
          _asMap(params),
          _pairingCompleteController,
          requiredStringKeys: const ['deviceId', 'fingerprint'],
        );
      });
      peer.registerMethod('rift.onSecurityEvent', (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onSecurityEvent',
          _asMap(params),
          _securityEventController,
          requiredStringKeys: const ['eventId', 'eventType', 'severity'],
        );
      });
      peer.registerMethod('rift.onClipboardOffer',
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
      peer.registerMethod('rift.onClipboardExpired',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onClipboardExpired',
          _asMap(params),
          _clipboardExpiredController,
          requiredStringKeys: const ['offerId'],
        );
      });
      peer.registerMethod('rift.onNotificationPosted',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onNotificationPosted',
          _asMap(params),
          _notificationPostedController,
          requiredStringKeys: const [
            'notificationId',
            'sourceDeviceId',
            'packageName',
            'appName',
            'postedAt',
          ],
        );
      });
      peer.registerMethod('rift.onNotificationUpdated',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onNotificationUpdated',
          _asMap(params),
          _notificationUpdatedController,
          requiredStringKeys: const [
            'notificationId',
            'sourceDeviceId',
            'packageName',
            'appName',
            'postedAt',
          ],
        );
      });
      peer.registerMethod('rift.onNotificationRemoved',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onNotificationRemoved',
          _asMap(params),
          _notificationRemovedController,
          requiredStringKeys: const ['notificationId', 'sourceDeviceId'],
        );
      });
      peer.registerMethod('rift.onNotificationActionRequest',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onNotificationActionRequest',
          _asMap(params),
          _notificationActionRequestController,
          requiredStringKeys: const [
            'requestId',
            'notificationId',
            'sourceDeviceId',
            'requestingDeviceId',
            'action',
          ],
        );
      });
      peer.registerMethod('rift.onNotificationActionResult',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onNotificationActionResult',
          _asMap(params),
          _notificationActionResultController,
          requiredStringKeys: const [
            'notificationId',
            'sourceDeviceId',
            'action',
            'operationId',
            'state',
          ],
        );
      });
      peer.registerMethod('rift.onDeviceStatusUpdated',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onDeviceStatusUpdated',
          _asMap(params),
          _deviceStatusUpdatedController,
          requiredStringKeys: const ['sourceDeviceId', 'observedAt'],
        );
      });
      peer.registerMethod('rift.onMediaPlaybackPosted',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onMediaPlaybackPosted',
          _asMap(params),
          _mediaPlaybackPostedController,
          requiredStringKeys: const [
            'playbackId',
            'sourceDeviceId',
            'appId',
            'appName',
            'playbackState',
            'updatedAt',
          ],
        );
      });
      peer.registerMethod('rift.onMediaPlaybackUpdated',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onMediaPlaybackUpdated',
          _asMap(params),
          _mediaPlaybackUpdatedController,
          requiredStringKeys: const [
            'playbackId',
            'sourceDeviceId',
            'appId',
            'appName',
            'playbackState',
            'updatedAt',
          ],
        );
      });
      peer.registerMethod('rift.onMediaPlaybackRemoved',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onMediaPlaybackRemoved',
          _asMap(params),
          _mediaPlaybackRemovedController,
          requiredStringKeys: const ['playbackId', 'sourceDeviceId'],
        );
      });
      peer.registerMethod('rift.onMediaPlaybackActionResult',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onMediaPlaybackActionResult',
          _asMap(params),
          _mediaPlaybackActionResultController,
          requiredStringKeys: const [
            'playbackId',
            'action',
            'operationId',
            'state',
          ],
        );
      });
      peer.registerMethod('rift.onMediaPlaybackActionRequest',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onMediaPlaybackActionRequest',
          _asMap(params),
          _mediaPlaybackActionRequestController,
          requiredStringKeys: const [
            'requestId',
            'playbackId',
            'sourceDeviceId',
            'requestingDeviceId',
            'action',
          ],
        );
      });
      peer.registerMethod('rift.onFileOffer', (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onFileOffer',
          _asMap(params),
          _fileOfferController,
          requiredStringKeys: const [
            'transferId',
            'sourceDeviceId',
            'fileName',
            'mediaType',
            'sha256',
          ],
        );
      });
      peer.registerMethod('rift.onFileTransferProgress',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onFileTransferProgress',
          _asMap(params),
          _fileTransferProgressController,
          requiredStringKeys: const [
            'transferId',
            'operationId',
            'peerDeviceId',
            'fileName',
            'state',
          ],
        );
      });
      peer.registerMethod('rift.onFileTransferReadyToCommit',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onFileTransferReadyToCommit',
          _asMap(params),
          _fileTransferReadyToCommitController,
          requiredStringKeys: const [
            'transferId',
            'operationId',
            'peerDeviceId',
            'fileName',
            'sha256',
            'stagingPath',
            'destinationPath',
            'state',
          ],
        );
      });
      peer.registerMethod('rift.onFileTransferCompleted',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onFileTransferCompleted',
          _asMap(params),
          _fileTransferCompletedController,
          requiredStringKeys: const [
            'transferId',
            'operationId',
            'peerDeviceId',
            'fileName',
          ],
        );
      });
      peer.registerMethod('rift.onFileTransferFailed',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onFileTransferFailed',
          _asMap(params),
          _fileTransferFailedController,
          requiredStringKeys: const [
            'transferId',
            'operationId',
            'peerDeviceId',
            'fileName',
            'failureReason',
          ],
        );
      });
      peer.registerMethod('rift.onOperationTransition',
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
      peer.registerMethod('rift.onSendQueueChanged',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onSendQueueChanged',
          _asMap(params),
          _sendQueueChangedController,
          requiredStringKeys: const ['queueItemId'],
        );
      });
      peer.registerMethod('rift.onSendQueueItemUpdated',
          (json_rpc.Parameters params) {
        _emitIfValid(
          'rift.onSendQueueItemUpdated',
          _asMap(params),
          _sendQueueItemUpdatedController,
          requiredStringKeys: const ['queueItemId', 'status'],
        );
      });
      // Start listening to the RPC channel.
      unawaited(
        peer.listen().then<void>(
          (_) {
            _log.warning('RPC connection closed (epoch=$epoch)');
            unawaited(_handlePeerClosed(peer, epoch, outController));
          },
          onError: (Object error, StackTrace stackTrace) {
            _log.severe(
              'RPC connection error (epoch=$epoch): $error',
              error,
              stackTrace,
            );
            unawaited(
              _handlePeerClosed(
                peer,
                epoch,
                outController,
                error: error,
              ),
            );
          },
        ),
      );

      if (!_canInstallConnection(epoch) || !identical(_client, peer)) {
        await peer.close();
        _closeOutputController(outController);
        return;
      }
      _setConnectionState(true);
      _reconnectAttempts = 0;
      _log.info('Connected to daemon successfully (epoch=$epoch)');
    } catch (error) {
      _log.severe('Failed to connect (epoch=$epoch): $error');
      if (_connectionEpoch == epoch && !_disposed) {
        _setConnectionState(false);
      }
      rethrow;
    }
  }

  int _reconnectAttempts = 0;
  int _connectionEpoch = 0;
  Timer? _reconnectTimer;
  Future<void>? _connectFuture;
  Future<void>? _transportDisconnectFuture;
  Future<void>? _disposeFuture;
  StreamController<String>? _outController;
  bool _isReconnecting = false;
  bool _intentionalDisconnect = false;
  bool _disposed = false;

  bool _canInstallConnection(int epoch) =>
      !_disposed && !_intentionalDisconnect && epoch == _connectionEpoch;

  bool _ownsPeer(json_rpc.Peer peer, int epoch) =>
      epoch == _connectionEpoch && identical(_client, peer);

  Future<void> _handlePeerClosed(
    json_rpc.Peer peer,
    int epoch,
    StreamController<String> outController, {
    Object? error,
  }) async {
    if (!_ownsPeer(peer, epoch)) {
      _log.fine('Ignoring stale RPC peer completion (epoch=$epoch)');
      return;
    }
    if (_intentionalDisconnect || _disposed) {
      _log.fine('Ignoring intentional RPC peer completion (epoch=$epoch)');
      return;
    }

    _log.warning(
      'Current RPC peer ended unexpectedly (epoch=$epoch, '
      'reason=${error ?? "closed"})',
    );
    _client = null;
    if (identical(_outController, outController)) {
      _outController = null;
    }
    _setConnectionState(false);
    _closeOutputController(outController);
    await _disconnectTransport();

    if (_disposed ||
        _intentionalDisconnect ||
        epoch != _connectionEpoch ||
        _client != null) {
      return;
    }
    _scheduleReconnect();
  }

  void _closeOutputController(StreamController<String>? controller) {
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  Future<void> _disconnectTransport() {
    final pending = _transportDisconnectFuture;
    if (pending != null) {
      return pending;
    }
    final future = _performTransportDisconnect();
    _transportDisconnectFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_transportDisconnectFuture, future)) {
          _transportDisconnectFuture = null;
        }
      }),
    );
    return future;
  }

  Future<void> _performTransportDisconnect() async {
    try {
      await _transport.disconnect();
    } catch (error) {
      _log.warning('Error during transport disconnect: $error');
    }
  }

  void _scheduleReconnect() {
    if (_disposed ||
        _intentionalDisconnect ||
        _isConnected ||
        _isReconnecting) {
      return;
    }

    _isReconnecting = true;
    final scheduledEpoch = _connectionEpoch;
    final delaySeconds = (1 << _reconnectAttempts).clamp(1, 5);
    final delay = Duration(seconds: delaySeconds);

    _log.info(
      'Reconnecting in ${delay.inSeconds} seconds '
      '(attempt ${_reconnectAttempts + 1}, epoch=$scheduledEpoch)...',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed ||
          _intentionalDisconnect ||
          _isConnected ||
          scheduledEpoch != _connectionEpoch) {
        _isReconnecting = false;
        return;
      }
      _reconnectAttempts++;
      connect().catchError((Object error) {
        _log.severe('Reconnect failed: $error');
      }).whenComplete(() {
        final shouldRetry =
            !_isConnected && !_disposed && !_intentionalDisconnect;
        _isReconnecting = false;
        if (shouldRetry) {
          _scheduleReconnect();
        }
      });
    });
  }

  Future<void> disconnect() {
    if (_disposed) {
      return _disposeFuture ?? Future<void>.value();
    }
    return _disconnectCurrent();
  }

  Future<void> _disconnectCurrent() async {
    _intentionalDisconnect = true;
    _connectionEpoch++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _isReconnecting = false;

    final pendingConnect = _connectFuture;
    final peer = _client;
    final outController = _outController;
    _client = null;
    _outController = null;
    _setConnectionState(false);

    await peer?.close();
    _closeOutputController(outController);
    await _disconnectTransport();
    if (pendingConnect != null) {
      try {
        await pendingConnect;
      } catch (_) {
        // The invalidated connection attempt is already fully torn down.
      }
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    await _disconnectCurrent();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _trustChangedController.close();
    await _pairingRequestController.close();
    await _pairingCompleteController.close();
    await _operationTransitionController.close();
    await _securityEventController.close();
    await _clipboardOfferController.close();
    await _clipboardExpiredController.close();
    await _notificationPostedController.close();
    await _notificationUpdatedController.close();
    await _notificationRemovedController.close();
    await _notificationActionRequestController.close();
    await _notificationActionResultController.close();
    await _deviceStatusUpdatedController.close();
    await _mediaPlaybackPostedController.close();
    await _mediaPlaybackUpdatedController.close();
    await _mediaPlaybackRemovedController.close();
    await _mediaPlaybackActionResultController.close();
    await _mediaPlaybackActionRequestController.close();
    await _fileOfferController.close();
    await _fileTransferProgressController.close();
    await _fileTransferReadyToCommitController.close();
    await _fileTransferCompletedController.close();
    await _fileTransferFailedController.close();
    await _connectionChangedController.close();
  }

  Future<dynamic> getDeviceInfo() async {
    return _sendRequest('rift.getDeviceInfo');
  }

  Future<dynamic> listDiscoveredPeers() async {
    return _sendRequest('rift.listDiscoveredPeers');
  }

  Future<dynamic> listTrustedPeers() async {
    return _sendRequest('rift.listTrustedPeers');
  }

  Future<dynamic> notifyLocalNotificationEvent({
    required String eventType,
    required Map<String, Object?> payload,
  }) async {
    return _sendRequest('rift.notifyLocalNotificationEvent', {
      'eventType': eventType,
      ...payload,
    });
  }

  Future<dynamic> listNotifications() async {
    return _sendRequest('rift.listNotifications');
  }

  Future<dynamic> notifyLocalMediaPlaybackEvent({
    required String eventType,
    required Map<String, Object?> payload,
  }) async {
    return _sendRequest('rift.notifyLocalMediaPlaybackEvent', {
      'eventType': eventType,
      ...payload,
    });
  }

  Future<dynamic> listMediaPlayback() async {
    return _sendRequest('rift.listMediaPlayback');
  }

  Future<dynamic> getPeerDeviceStatus(String deviceId) async {
    return _sendRequest('rift.getPeerDeviceStatus', {'deviceId': deviceId});
  }

  Future<dynamic> notifyLocalDeviceStatus({
    bool? batteryPresent,
    int? batteryPercent,
    String? chargingState,
    String? powerSource,
    bool? lowPowerMode,
    String? observedAt,
    String? sourcePlatform,
  }) async {
    return _sendRequest('rift.notifyLocalDeviceStatus', {
      if (batteryPresent != null) 'batteryPresent': batteryPresent,
      if (batteryPercent != null) 'batteryPercent': batteryPercent,
      if (chargingState != null) 'chargingState': chargingState,
      if (powerSource != null) 'powerSource': powerSource,
      if (lowPowerMode != null) 'lowPowerMode': lowPowerMode,
      if (observedAt != null) 'observedAt': observedAt,
      if (sourcePlatform != null) 'sourcePlatform': sourcePlatform,
    });
  }

  Future<dynamic> getMediaPlayback({
    required String sourceDeviceId,
    required String playbackId,
  }) async {
    return _sendRequest('rift.getMediaPlayback', {
      'sourceDeviceId': sourceDeviceId,
      'playbackId': playbackId,
    });
  }

  Future<dynamic> performMediaPlaybackAction({
    required String sourceDeviceId,
    required String playbackId,
    required String action,
    int? positionMs,
  }) async {
    final params = <String, dynamic>{
      'sourceDeviceId': sourceDeviceId,
      'playbackId': playbackId,
      'action': action,
    };
    if (positionMs != null) {
      params['positionMs'] = positionMs;
    }
    return _sendRequest('rift.performMediaPlaybackAction', params);
  }

  Future<dynamic> reportLocalMediaPlaybackActionHandled({
    required String requestId,
    required bool success,
    String? failureReason,
    String? message,
  }) async {
    return _sendRequest('rift.reportLocalMediaPlaybackActionHandled', {
      'requestId': requestId,
      'success': success,
      if (failureReason != null) 'failureReason': failureReason,
      if (message != null) 'message': message,
    });
  }

  Future<dynamic> performNotificationAction({
    required String sourceDeviceId,
    required String notificationId,
    required String action,
  }) async {
    return _sendRequest('rift.performNotificationAction', {
      'sourceDeviceId': sourceDeviceId,
      'notificationId': notificationId,
      'action': action,
    });
  }

  Future<dynamic> reportLocalNotificationActionHandled({
    required String requestId,
    required bool success,
    String? failureReason,
    String? message,
  }) async {
    return _sendRequest('rift.reportLocalNotificationActionHandled', {
      'requestId': requestId,
      'success': success,
      if (failureReason != null) 'failureReason': failureReason,
      if (message != null) 'message': message,
    });
  }

  Future<dynamic> updateNotificationSyncPolicy({
    required bool enabled,
    required String mode,
    required List<String> packageNames,
  }) async {
    return _sendRequest('rift.updateNotificationSyncPolicy', {
      'enabled': enabled,
      'mode': mode,
      'packageNames': packageNames,
    });
  }

  Future<dynamic> listOperations({
    int? limit,
    int? offset,
  }) async {
    final params = <String, dynamic>{};
    if (limit != null) params['limit'] = limit;
    if (offset != null) params['offset'] = offset;
    return _sendRequest('rift.listOperations', params);
  }

  Future<dynamic> queryEventLog({
    List<String>? eventTypes,
    List<String>? severities,
    String? peerDeviceId,
    String? since,
    int limit = 100,
    int offset = 0,
  }) async {
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
    return _sendRequest('rift.queryEventLog', params);
  }

  Future<dynamic> startDiscovery() async {
    final r = await _sendRequest('rift.startDiscovery').timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('Discovery request timed out'),
    );
    return r;
  }

  Future<dynamic> stopDiscovery() async {
    return _sendRequest('rift.stopDiscovery');
  }

  Future<dynamic> startPairing(String deviceId) async {
    final pending = _pendingStartPairings[deviceId];
    if (pending != null) {
      _log.info('Joining in-flight startPairing request for $deviceId');
      return pending;
    }

    final future = _sendRequest('rift.startPairing', {'deviceId': deviceId});
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
    final key = '$address:$port';
    final pending = _pendingEndpointPairings[key];
    if (pending != null) {
      _log.info('Joining in-flight startPairingByEndpoint request for $key');
      return pending;
    }

    final future = _sendRequest('rift.startPairingByEndpoint', {
      'address': address,
      'port': port,
    });
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
    return _sendRequest('rift.approvePairing', {
      'deviceId': deviceId,
      'fingerprint': fingerprint,
    });
  }

  Future<dynamic> rejectPairing(String deviceId) async {
    return _sendRequest('rift.rejectPairing', {'deviceId': deviceId});
  }

  Future<dynamic> revokeTrust(String deviceId, String reason) async {
    return _sendRequest('rift.revokeTrust', {
      'deviceId': deviceId,
      'reason': reason,
    });
  }

  Future<dynamic> unblockPeer(String deviceId) async {
    return _sendRequest('rift.unblockPeer', {'deviceId': deviceId});
  }

  Future<dynamic> resetRevokedPeer(String deviceId) async {
    return _sendRequest('rift.resetRevokedPeer', {'deviceId': deviceId});
  }

  Future<dynamic> notifyClipboardChange({
    required String contentType,
    required int byteSize,
    required String sha256,
    required String contentBase64,
  }) async {
    return _sendRequest('rift.notifyClipboardChange', {
      'contentType': contentType,
      'byteSize': byteSize,
      'sha256': sha256,
      'contentBase64': contentBase64,
    });
  }

  Future<dynamic> listClipboardOffers() async {
    return _sendRequest('rift.listClipboardOffers');
  }

  Future<dynamic> fetchClipboardContent(String offerId) async {
    return _sendRequest(
      'rift.fetchClipboardContent',
      {'offerId': offerId},
    );
  }

  Future<dynamic> offerFile({
    required String targetDeviceId,
    required String localPath,
    String? fileName,
    String? mediaType,
  }) async {
    final params = <String, dynamic>{
      'targetDeviceId': targetDeviceId,
      'localPath': localPath,
    };
    if (fileName != null && fileName.isNotEmpty) {
      params['fileName'] = fileName;
    }
    if (mediaType != null && mediaType.isNotEmpty) {
      params['mediaType'] = mediaType;
    }
    return _sendRequest('rift.offerFile', params);
  }

  Future<bool> supportsSendQueue() async {
    final cached = _supportsSendQueue;
    if (cached != null) {
      return cached;
    }
    try {
      await listSendQueue();
      _supportsSendQueue = true;
    } catch (error) {
      if (isMethodNotFoundError(error)) {
        _supportsSendQueue = false;
        return false;
      }
      rethrow;
    }
    return true;
  }

  Future<dynamic> enqueueFileSend({
    required String localPath,
    String? fileName,
    String? mediaType,
    String? targetDeviceId,
    String? origin,
  }) async {
    final params = <String, dynamic>{
      'localPath': localPath,
    };
    if (fileName != null && fileName.isNotEmpty) {
      params['fileName'] = fileName;
    }
    if (mediaType != null && mediaType.isNotEmpty) {
      params['mediaType'] = mediaType;
    }
    if (targetDeviceId != null && targetDeviceId.isNotEmpty) {
      params['targetDeviceId'] = targetDeviceId;
    }
    if (origin != null && origin.isNotEmpty) {
      params['origin'] = origin;
    }
    return _sendRequest('rift.enqueueFileSend', params);
  }

  Future<dynamic> listSendQueue() async {
    return _sendRequest('rift.listSendQueue');
  }

  Future<dynamic> getSendQueueItem(String queueItemId) async {
    return _sendRequest('rift.getSendQueueItem', {
      'queueItemId': queueItemId,
    });
  }

  Future<dynamic> assignSendQueueTarget({
    required String queueItemId,
    required String targetDeviceId,
  }) async {
    return _sendRequest('rift.assignSendQueueTarget', {
      'queueItemId': queueItemId,
      'targetDeviceId': targetDeviceId,
    });
  }

  Future<dynamic> retrySendQueueItem(String queueItemId) async {
    return _sendRequest('rift.retrySendQueueItem', {
      'queueItemId': queueItemId,
    });
  }

  Future<dynamic> cancelFileTransfer(String transferId) async {
    return _sendRequest('rift.cancelFileTransfer', {
      'transferId': transferId,
    });
  }

  Future<dynamic> removeSendQueueItem(String queueItemId) async {
    return _sendRequest('rift.removeSendQueueItem', {
      'queueItemId': queueItemId,
    });
  }

  Future<dynamic> listIncomingFileOffers() async {
    return _sendRequest('rift.listIncomingFileOffers');
  }

  Future<dynamic> acceptFileOffer({
    required String transferId,
    required String destinationPath,
    bool overwrite = false,
  }) async {
    return _sendRequest('rift.acceptFileOffer', {
      'transferId': transferId,
      'destinationPath': destinationPath,
      'overwrite': overwrite,
    });
  }

  Future<dynamic> rejectFileOffer({
    required String transferId,
    required String failureReason,
    String? message,
  }) async {
    final params = <String, dynamic>{
      'transferId': transferId,
      'failureReason': failureReason,
    };
    if (message != null && message.isNotEmpty) {
      params['message'] = message;
    }
    return _sendRequest('rift.rejectFileOffer', params);
  }

  Future<dynamic> listFileTransfers() async {
    return _sendRequest('rift.listFileTransfers');
  }

  Future<dynamic> listPendingFileCommits() async {
    return _sendRequest('rift.listPendingFileCommits');
  }

  Future<dynamic> confirmFileCommit({
    required String transferId,
    required String destinationPath,
  }) async {
    return _sendRequest('rift.confirmFileCommit', {
      'transferId': transferId,
      'destinationPath': destinationPath,
    });
  }

  Future<dynamic> failFileCommit({
    required String transferId,
    required String failureReason,
    String? message,
  }) async {
    final params = <String, dynamic>{
      'transferId': transferId,
      'failureReason': failureReason,
    };
    if (message != null && message.isNotEmpty) {
      params['message'] = message;
    }
    return _sendRequest('rift.failFileCommit', params);
  }

  Future<dynamic> getOperation(String operationId) async {
    return _sendRequest('rift.getOperation', {
      'operationId': operationId,
    });
  }

  Future<dynamic> invokeRpc(String method, [dynamic parameters]) async {
    return _sendRequest(method, parameters);
  }
}
