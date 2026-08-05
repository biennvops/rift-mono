import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:daemon_dart/src/crypto/cert_decoder.dart';
import 'package:daemon_dart/src/crypto/identity_manager_impl.dart';
import 'package:daemon_dart/src/crypto/base32_utils.dart';
import 'package:daemon_dart/src/core/rift_constants.dart';
import 'package:daemon_dart/src/core/rift_exceptions.dart';
import 'package:daemon_dart/src/core/rift_log.dart';
import 'package:daemon_dart/src/core/rpc_utils.dart';
import 'package:daemon_dart/src/network/discovery_service_factory.dart'
    as discovery_factory;
import 'package:daemon_dart/src/network/transport_impl.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/interfaces/discovery_service.dart';
import 'package:daemon_dart/src/interfaces/identity_manager.dart';
import 'package:daemon_dart/src/interfaces/transport.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/storage/trust_store_impl.dart';
import 'package:daemon_dart/src/pairing/pairing_manager.dart';
import 'package:daemon_dart/src/clipboard/clipboard_engine.dart';
import 'package:daemon_dart/src/clipboard/clipboard_handler.dart';
import 'package:daemon_dart/src/clipboard/clipboard_models.dart';
import 'package:daemon_dart/src/file_transfer/file_transfer_service.dart';
import 'package:daemon_dart/src/media_playback/media_playback_manager.dart';
import 'package:daemon_dart/src/media_playback/media_playback_models.dart';
import 'package:daemon_dart/src/operation/operation_manager.dart';
import 'package:daemon_dart/src/operation/operation_models.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const int _clipboardFetchTimeoutSeconds = 15;

class _OperationFetchWaiter {
  final Future<ClipboardFetchResponse> future;
  final Future<void> Function(
    String failureReason,
    int errorCode,
    String message,
  )
  fail;

  const _OperationFetchWaiter({required this.future, required this.fail});
}

class _DiscoveredPeerRecord {
  final String deviceId;
  final Map<String, DiscoveredPeer> peersByInstanceId;

  _DiscoveredPeerRecord({
    required this.deviceId,
    required this.peersByInstanceId,
  });

  List<DiscoveredPeer> get orderedPeers {
    final peers = peersByInstanceId.values.toList(growable: false);
    final grouped = <int, List<DiscoveredPeer>>{};
    for (final peer in peers) {
      grouped
          .putIfAbsent(_endpointScore(peer.address), () => <DiscoveredPeer>[])
          .add(peer);
    }

    final scores = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final score in scores) ...grouped[score]!];
  }

  DiscoveredPeer? get primaryPeer =>
      orderedPeers.isEmpty ? null : orderedPeers.first;

  List<DiscoveredPeerEndpoint> get observedEndpoints => orderedPeers
      .map(
        (peer) => DiscoveredPeerEndpoint(
          instanceId: peer.instanceId,
          address: peer.address,
          port: peer.port,
        ),
      )
      .toList(growable: false);
}

class _NotificationSyncPolicy {
  bool enabled;
  List<String> blacklistedPackages;

  _NotificationSyncPolicy({
    this.enabled = true,
    List<String>? blacklistedPackages,
  }) : blacklistedPackages = List<String>.from(blacklistedPackages ?? const []);

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'blacklistedPackages': List<String>.from(blacklistedPackages),
  };
}

int _endpointScore(String address) {
  final ip = InternetAddress.tryParse(address);
  if (ip == null) {
    return 0;
  }

  if (ip.type == InternetAddressType.IPv4) {
    return 3;
  }

  if (ip.type == InternetAddressType.IPv6) {
    final raw = ip.rawAddress;
    final isLinkLocal =
        raw.length >= 2 && raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80;
    if (isLinkLocal) {
      return -1;
    }
    return 2;
  }

  return 0;
}

String _classifyPairingConnectFailure(Object error) {
  if (error is RiftAuthenticationFailedException) {
    if (error.message.contains(
      'Peer closed connection before sending session.hello',
    )) {
      return 'peer-closed-before-hello';
    }

    return 'authentication-failed';
  }

  if (error is SocketException) {
    final code = error.osError?.errorCode;
    switch (code) {
      case 111:
      case 61:
      case 10061:
        return 'connection-refused';
      case 22:
      case 10022:
        return 'invalid-endpoint-argument';
      case 101:
      case 10051:
        return 'network-unreachable';
      case 113:
      case 10065:
        return 'host-unreachable';
      case 8:
      case 11001:
      case 11004:
        return 'host-not-found';
    }

    final message = error.message.toLowerCase();
    if (message.contains('connection refused')) {
      return 'connection-refused';
    }
    if (message.contains('no address associated with hostname') ||
        message.contains('failed host lookup') ||
        message.contains('name or service not known') ||
        message.contains('nodename nor servname provided')) {
      return 'host-not-found';
    }
    if (message.contains('network is unreachable')) {
      return 'network-unreachable';
    }
    if (message.contains('no route to host') ||
        message.contains('host is down')) {
      return 'host-unreachable';
    }
    if (message.contains('invalid argument')) {
      return 'invalid-endpoint-argument';
    }
  }

  if (error is HandshakeException) {
    return 'tls-handshake-failed';
  }

  if (error is TimeoutException) {
    return 'session-timeout';
  }

  final message = error.toString().toLowerCase();
  if (message.contains('peer closed connection before sending session.hello')) {
    return 'peer-closed-before-hello';
  }

  return 'unknown';
}

String _describePairingConnectFailure(Object error) {
  switch (_classifyPairingConnectFailure(error)) {
    case 'connection-refused':
      return 'The peer was discovered, but nothing accepted the TLS connection on that endpoint.';
    case 'invalid-endpoint-argument':
      return 'The discovered endpoint was not usable on this platform, usually due to an invalid address form or unsupported scope.';
    case 'host-not-found':
      return 'The discovered host name could not be resolved to a reachable local-network address.';
    case 'host-unreachable':
      return 'The peer address was known, but the host was not reachable on the local network.';
    case 'network-unreachable':
      return 'The current network route could not reach that peer endpoint.';
    case 'peer-closed-before-hello':
      return 'The peer accepted TCP/TLS, then closed before session bootstrap completed; this often means a duplicate or stale discovery endpoint.';
    case 'tls-handshake-failed':
      return 'The TLS handshake failed before Rift session bootstrap could complete.';
    case 'authentication-failed':
      return 'The peer certificate or session bootstrap failed authentication.';
    case 'session-timeout':
      return 'The secure session did not finish establishing before the timeout expired.';
    default:
      return 'The endpoint failed before a secure Rift session could be established.';
  }
}

String _summarizePairingFailures(
  List<({DiscoveredPeer peer, Object error})> failures,
) {
  if (failures.isEmpty) {
    return 'No discovered endpoints were attempted.';
  }

  final last = failures.last;
  final samples = failures
      .map((failure) {
        final classification = _classifyPairingConnectFailure(failure.error);
        return '${failure.peer.address}:${failure.peer.port} ($classification)';
      })
      .toList(growable: false);

  return 'Attempted ${failures.length} endpoint(s): ${samples.join(', ')}. '
      'Last endpoint ${last.peer.address}:${last.peer.port}. '
      '${_describePairingConnectFailure(last.error)}';
}

bool _isLikelyDuplicateBootstrapRace(Object error) {
  if (_classifyPairingConnectFailure(error) == 'peer-closed-before-hello') {
    return true;
  }

  if (error is SessionException &&
      error.message.contains('Session already exists for ')) {
    return true;
  }

  final message = error.toString().toLowerCase();
  return message.contains('session already exists for ');
}

@visibleForTesting
Future<String> reconnectTrustedPeerViaEndpoints({
  required String peerDeviceId,
  required List<TrustedPeerEndpoint> trustedEndpoints,
  required Transport transport,
  required SessionContext? Function(String peerDeviceId) getContext,
  required Future<void> Function(String peerDeviceId) sendSessionHello,
  required Future<void> Function(String peerDeviceId) waitForSessionEstablished,
  required Future<void> Function(String peerDeviceId, String source)
  persistTrustedEndpoint,
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (trustedEndpoints.isEmpty) {
    throw RiftException(
      -32000,
      'Trusted peer $peerDeviceId has no persisted local endpoint to reconnect.',
    );
  }

  final attempts =
      <
        int,
        Future<
          ({
            int index,
            TrustedPeerEndpoint endpoint,
            String? peerDeviceId,
            Object? error,
          })
        >
      >{};
  for (var index = 0; index < trustedEndpoints.length; index++) {
    final endpoint = trustedEndpoints[index];
    attempts[index] = _attemptTrustedEndpoint(
      index,
      endpoint,
      peerDeviceId,
      transport,
      getContext,
      sendSessionHello,
      waitForSessionEstablished,
      timeout,
    );
  }

  Object? lastError;
  while (attempts.isNotEmpty) {
    final result = await Future.any(attempts.values);
    attempts.remove(result.index);
    if (result.error == null && result.peerDeviceId != null) {
      // A transport implementation retains the first authenticated session for
      // duplicate connections. Let losing attempts finish and consume their
      // results, but only persist the endpoint that won the race.
      unawaited(Future.wait(attempts.values));
      await persistTrustedEndpoint(result.peerDeviceId!, 'trusted-reconnect');
      return result.peerDeviceId!;
    }

    lastError = result.error;
    final classification = _classifyPairingConnectFailure(result.error!);
    RiftLog.warn(
      '[Reconnect] Trusted endpoint failed for peerDeviceId=$peerDeviceId '
      'address=${result.endpoint.address}:${result.endpoint.port} '
      'classification=$classification detail=${_describePairingConnectFailure(result.error!)}',
    );
  }

  throw RiftException(
    -32000,
    'Failed to reconnect trusted peer $peerDeviceId using persisted endpoints. '
    '${lastError == null ? "" : _describePairingConnectFailure(lastError)}',
  );
}

Future<
  ({
    int index,
    TrustedPeerEndpoint endpoint,
    String? peerDeviceId,
    Object? error,
  })
>
_attemptTrustedEndpoint(
  int index,
  TrustedPeerEndpoint endpoint,
  String expectedPeerDeviceId,
  Transport transport,
  SessionContext? Function(String peerDeviceId) getContext,
  Future<void> Function(String peerDeviceId) sendSessionHello,
  Future<void> Function(String peerDeviceId) waitForSessionEstablished,
  Duration timeout,
) async {
  try {
    final connectedPeerDeviceId = await transport
        .connectTo(
          endpoint.address,
          endpoint.port,
          expectedDeviceId: expectedPeerDeviceId,
          forceFreshSession: true,
        )
        .timeout(timeout);

    if (getContext(connectedPeerDeviceId) == null) {
      await sendSessionHello(connectedPeerDeviceId);
    }
    await waitForSessionEstablished(connectedPeerDeviceId).timeout(timeout);
    RiftLog.info(
      '[Reconnect] Trusted endpoint succeeded for peerDeviceId=$expectedPeerDeviceId '
      'address=${endpoint.address}:${endpoint.port} source=${endpoint.source}',
    );
    return (
      index: index,
      endpoint: endpoint,
      peerDeviceId: connectedPeerDeviceId,
      error: null,
    );
  } catch (error) {
    return (index: index, endpoint: endpoint, peerDeviceId: null, error: error);
  }
}

@visibleForTesting
Future<T> joinSingleFlightOperation<T>({
  required String key,
  required Map<String, Future<T>> pendingOperations,
  required Future<T> Function() startOperation,
}) async {
  final pending = pendingOperations[key];
  if (pending != null) {
    return pending;
  }

  final future = startOperation();
  pendingOperations[key] = future;
  try {
    return await future;
  } finally {
    if (identical(pendingOperations[key], future)) {
      pendingOperations.remove(key);
    }
  }
}

@visibleForTesting
Future<bool> allowPeerHandshake({
  required TrustStore trustStore,
  required String peerDeviceId,
}) async {
  final record = await trustStore.getPeer(peerDeviceId);
  if (record == null) {
    return true;
  }

  if (record.state == TrustState.revoked) {
    await trustStore.deletePeer(peerDeviceId);
    return false;
  }

  return record.state != TrustState.blocked;
}

/// The root orchestrator for the Rift Android Daemon.
/// This class encapsulates all network, crypto, and session services
/// and is designed to be executed inside a background Isolate
/// hosted by an Android Foreground Service.
typedef PeerTransportFactory =
    Transport Function(IdentityManager identityManager, int port);

class RiftDaemon {
  static const Duration _trustedReconnectTimeout = Duration(seconds: 3);
  static const Duration _discoveryPrefetchRetryDelay = Duration(seconds: 10);
  static const List<Duration> _trustedReconnectDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];
  static const Duration _defaultMediaPlaybackActionTimeout = Duration(
    seconds: 30,
  );
  static final RegExp _rfc3339UtcTimestamp = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\+00:00)$',
  );
  static const Set<String> _failureReasons = {
    'PeerUnreachable',
    'PeerRejected',
    'OfferExpired',
    'CapabilityUnavailable',
    'ConnectionLost',
    'Timeout',
    'PolicyDenied',
    'AuthenticationFailed',
    'Unauthorized',
    'HashMismatch',
    'MalformedMessage',
    'VersionMismatch',
    'ProtocolError',
    'PayloadTooLarge',
    'InvalidTransition',
  };
  IdentityManagerImpl? _identityManager;
  DiscoveryService? _discoveryService;
  Transport? _transport;
  int? _boundTransportPort;
  SessionManager? _sessionManager;
  TrustStoreImpl? _trustStore;
  PairingManager? _pairingManager;
  ClipboardEngine? _clipboardEngine;
  ClipboardProtocolHandler? _clipboardHandler;
  FileTransferService? _fileTransferService;
  OperationManager? _operationManager;
  MediaPlaybackManager? _mediaPlaybackManager;
  StreamSubscription<ProtocolMessage>? _notificationSyncMessageSub;
  StreamSubscription<ProtocolMessage>? _mediaPlaybackMessageSub;
  StreamSubscription<String>? _sessionDisconnectSub;
  final Map<String, Map<String, dynamic>> _pendingMediaPlaybackActions = {};
  final Map<String, String> _pendingMediaPlaybackActionKeys = {};
  final Map<String, Timer> _pendingMediaPlaybackActionTimers = {};
  final Map<String, Map<String, dynamic>> _pendingIncomingMediaPlaybackActions =
      {};
  final Map<String, Timer> _pendingIncomingMediaPlaybackActionTimers = {};
  final Map<String, Map<String, dynamic>> _notificationSyncRecords = {};
  _NotificationSyncPolicy _notificationSyncPolicy = _NotificationSyncPolicy();
  final Map<String, _DiscoveredPeerRecord> _discoveredPeers = {};
  final Map<String, DateTime> _lastDiscoveryPrefetchAttempts = {};
  final Map<String, Future<String>> _pendingSessionEnsures = {};
  final Map<String, Future<Map<String, dynamic>>> _pendingStartPairings = {};
  final Map<String, Future<Map<String, dynamic>>>
  _pendingEndpointStartPairings = {};
  final Map<String, Future<String>> _pendingTrustedReconnects = {};
  final Map<String, TrustedPeerEndpoint> _pendingTrustedEndpointHints = {};
  final Map<String, Timer> _trustedReconnectTimers = {};
  final Map<String, int> _trustedReconnectAttempts = {};
  bool _isDiscovering = false;
  bool _isStopping = false;

  final String storagePath;
  final Future<Uint8List> Function()? identityPrivateKeyProvider;
  final String? localDisplayName;
  final int port;
  final bool enableTransport;
  final Transport? peerTransport;
  final PeerTransportFactory? peerTransportFactory;
  final bool enableDiscovery;
  final void Function(Map<String, dynamic>)? onIpcEvent;
  final Duration mediaPlaybackActionTimeout;

  RiftDaemon({
    required this.storagePath,
    this.identityPrivateKeyProvider,
    this.localDisplayName,
    this.port = 11112,
    this.enableTransport = true,
    this.peerTransport,
    this.peerTransportFactory,
    this.enableDiscovery = true,
    this.onIpcEvent,
    this.mediaPlaybackActionTimeout = _defaultMediaPlaybackActionTimeout,
  });

  Future<void> start() async {
    _isStopping = false;
    _identityManager = IdentityManagerImpl(
      storagePath,
      privateKeyProvider: identityPrivateKeyProvider,
      platformDisplayName: localDisplayName,
    );
    await _identityManager!.initialize();

    _trustStore = TrustStoreImpl(p.join(storagePath, 'trust_store.db'));
    await _trustStore!.initialize();

    if (enableTransport) {
      final injectedTransport =
          peerTransport ?? peerTransportFactory?.call(_identityManager!, port);
      if (injectedTransport != null) {
        _transport = injectedTransport;
        await _transport!.startServer();
      } else {
        // If the requested port is unavailable (common on dev devices), fall back
        // to an ephemeral port rather than failing the entire IPC layer.
        try {
          _transport = TransportImpl(_identityManager!, port: port);
          await _transport!.startServer();
        } on SocketException {
          _transport = TransportImpl(_identityManager!, port: 0);
          await _transport!.startServer();
        }
      }
      _boundTransportPort = switch (_transport) {
        BoundTransport transport => transport.boundPort,
        _ => port,
      };
    }

    if (_transport != null) {
      _sessionManager = SessionManager(
        _transport!,
        _identityManager!,
        _trustStore!,
        peerAllowanceResolver: (peerDeviceId) => allowPeerHandshake(
          trustStore: _trustStore!,
          peerDeviceId: peerDeviceId,
        ),
      );

      _sessionManager!.onTrustedSessionReady.listen((ctx) {
        _trustedReconnectTimers.remove(ctx.peerDeviceId)?.cancel();
        _trustedReconnectAttempts.remove(ctx.peerDeviceId);
        unawaited(
          _persistTrustedEndpointIfAvailable(
            ctx.peerDeviceId,
            source: 'session-established',
          ),
        );
        unawaited(_replayActiveSyncState(ctx.peerDeviceId));
      });
      _sessionManager!.onPresenceUpdate.listen((ctx) {
        if (ctx.currentPresenceStatus != 'online') {
          _mediaPlaybackManager?.removePlaybacksFromSource(ctx.peerDeviceId);
        }
        _forwardIpcEvent({
          'jsonrpc': '2.0',
          'method': 'rift.onPresenceUpdate',
          'params': {
            'deviceId': ctx.peerDeviceId,
            'status': ctx.currentPresenceStatus,
            'lastSeenAt': ctx.lastHeartbeatReceived?.toUtc().toIso8601String(),
            'capabilities': ctx.negotiatedCapabilities
                .map((capability) => capability.name)
                .toList(),
          },
        });
      });

      _pairingManager = PairingManager(
        trustStore: _trustStore!,
        sessionManager: _sessionManager!,
        identityManager: _identityManager!,
        onIpcEvent: (event) {
          _forwardIpcEvent(event);
        },
        onPeerTrusted: (peerDeviceId) async {
          await _persistTrustedEndpointIfAvailable(
            peerDeviceId,
            source: 'pairing-session',
          );
        },
      );

      _clipboardEngine = ClipboardEngine();
      _clipboardHandler = ClipboardProtocolHandler(
        _sessionManager!,
        _clipboardEngine!,
        // ContentFetcher: serve content from the in-memory local store
        (offerId) async => _clipboardEngine!.getLocalContent(offerId),
        _identityManager!.deviceId,
      );
      _operationManager = OperationManager();
      _mediaPlaybackManager = MediaPlaybackManager();
      _sessionDisconnectSub = _sessionManager!.onPeerDisconnected.listen((
        peerDeviceId,
      ) {
        _mediaPlaybackManager?.removePlaybacksFromSource(peerDeviceId);
        _scheduleTrustedReconnect(peerDeviceId);
      });
      _fileTransferService = FileTransferService(
        sessionManager: _sessionManager!,
        trustStore: _trustStore!,
        operationManager: _operationManager!,
        localDeviceId: _identityManager!.deviceId,
        storagePath: storagePath,
      );

      _clipboardEngine!.onOfferAdded.listen((offer) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onClipboardOffer',
          'params': offer.toJson(),
        });
      });

      _clipboardEngine!.onOfferExpired.listen((offerId) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onClipboardExpired',
          'params': {'offerId': offerId},
        });
      });

      _fileTransferService!.onFileOffer.listen((offer) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onFileOffer',
          'params': offer,
        });
      });

      _fileTransferService!.onTransferProgress.listen((event) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onFileTransferProgress',
          'params': event,
        });
      });

      _fileTransferService!.onTransferCompleted.listen((event) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onFileTransferCompleted',
          'params': event,
        });
      });

      _fileTransferService!.onTransferFailed.listen((event) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onFileTransferFailed',
          'params': event,
        });
      });

      _operationManager!.onTransition.listen((event) {
        final operation = _operationManager!.getOperation(event.operationId);
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onOperationTransition',
          'params': event.toJson(),
        });
        unawaited(
          _recordSecurityEvent(
            eventType: 'operation.transitioned',
            severity: 'info',
            peerDeviceId: operation.destinationDeviceId,
            outcome:
                event.nextState == OperationState.failed ||
                    event.nextState == OperationState.expired
                ? 'failure'
                : 'success',
            failureReason: event.failureReason,
            details: event.toJson(),
          ),
        );
      });

      _notificationSyncMessageSub = _sessionManager!.onMessage.listen(
        _handleNotificationSyncProtocolMessage,
      );
      _mediaPlaybackMessageSub = _sessionManager!.onMessage.listen(
        _handleMediaPlaybackProtocolMessage,
      );

      _mediaPlaybackManager!.onPosted.listen((record) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onMediaPlaybackPosted',
          'params': record.toJson(),
        });
      });
      _mediaPlaybackManager!.onUpdated.listen((record) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onMediaPlaybackUpdated',
          'params': record.toJson(),
        });
      });
      _mediaPlaybackManager!.onRemoved.listen((record) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onMediaPlaybackRemoved',
          'params': {
            'playbackId': record.playbackId,
            'sourceDeviceId': record.sourceDeviceId,
            if (record.removedAt != null) 'removedAt': record.removedAt,
          },
        });
      });
      _mediaPlaybackManager!.onActionResult.listen((event) {
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onMediaPlaybackActionResult',
          'params': event,
        });
      });
    }

    if (enableDiscovery) {
      final advertisedPort = _boundTransportPort ?? port;
      _discoveryService = discovery_factory.createDiscoveryService(
        port: advertisedPort,
        deviceIdHint: _identityManager!.deviceId,
        fingerprintPrefix: _fingerprintPrefix(
          _identityManager!.getDeviceFingerprint(),
        ),
      );
      _discoveryService!.onDeviceDiscovered.listen((peer) {
        if (peer.deviceIdHint == _identityManager!.deviceId) return;
        if (peer.deviceIdHint == null) return;
        trackDiscoveredPeer(peer);
        unawaited(prefetchSessionForDiscoveredPeer(peer.deviceIdHint!));
        _forwardIpcEvent({
          'jsonrpc': '2.0',
          'method': 'rift.onPeerDiscovered',
          'params': {
            'deviceId': peer.deviceIdHint,
            'instanceId': peer.instanceId,
            'address': peer.address,
            'port': peer.port,
            'txtRecord': {
              'minV': peer.minVersion,
              'maxV': peer.maxVersion,
              'did': peer.deviceIdHint,
              if (peer.fingerprintPrefix != null) 'fp': peer.fingerprintPrefix,
            },
          },
        });
      });
      _discoveryService!.onDeviceLost.listen((peer) {
        final deviceId = peer.deviceIdHint;
        if (deviceId == null) return;

        final hadVisiblePeer = _discoveredPeers.containsKey(deviceId);
        untrackDiscoveredPeer(peer);
        if (hadVisiblePeer && !_discoveredPeers.containsKey(deviceId)) {
          _forwardIpcEvent({
            'jsonrpc': '2.0',
            'method': 'rift.onPeerLost',
            'params': {'deviceId': deviceId, 'instanceId': peer.instanceId},
          });
        }
      });
      try {
        await _discoveryService!.startAdvertising();
        if (await _shouldAutoStartDiscovery()) {
          await _discoveryService!.startDiscovery();
          _isDiscovering = true;
        }
      } catch (e) {
        RiftLog.warn(
          '[Discovery] Startup failed; continuing without active discovery: $e',
        );
      }
    }
    // Discovery remains passive for browsing, but pairing may trigger an
    // explicit connect/handshake when the UI selects a discovered peer.
  }

  void _validateClipboardChangePayload({
    required int byteSize,
    required String sha256Hex,
    required String contentBase64,
  }) {
    Uint8List bytes;
    try {
      bytes = base64.decode(contentBase64);
    } on FormatException {
      throw const RiftException(-32600, 'contentBase64 must be valid base64');
    }

    if (bytes.length != byteSize) {
      throw const RiftException(
        -32600,
        'byteSize does not match decoded content length',
      );
    }

    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != sha256Hex) {
      throw const RiftException(
        -32006,
        'sha256 does not match decoded content',
      );
    }
  }

  List<String> _normalizeNotificationSyncBlacklist(Object? value) {
    if (value == null) {
      return const <String>[];
    }
    if (value is! List) {
      throw ArgumentError.value(
        value,
        'blacklistedPackages',
        'must be a list of strings',
      );
    }

    final normalized = <String>{};
    for (final entry in value) {
      if (entry is! String) {
        throw ArgumentError.value(
          value,
          'blacklistedPackages',
          'must be a list of strings',
        );
      }
      final trimmed = entry.trim();
      if (trimmed.isNotEmpty) {
        normalized.add(trimmed);
      }
    }
    return normalized.toList(growable: false)..sort();
  }

  Future<Map<String, dynamic>> _updateNotificationSyncPolicy({
    required bool enabled,
    required List<String> blacklistedPackages,
  }) async {
    _notificationSyncPolicy = _NotificationSyncPolicy(
      enabled: enabled,
      blacklistedPackages: blacklistedPackages,
    );
    return _notificationSyncPolicy.toJson();
  }

  Map<String, dynamic> _listMediaPlaybackState() {
    return _mediaPlaybackManager?.listStateJson() ?? {'playbacks': <dynamic>[]};
  }

  Map<String, dynamic> _getMediaPlaybackState(Map<String, dynamic> params) {
    final sourceDeviceId = RpcUtils.requireStringParam(
      params,
      'sourceDeviceId',
    );
    final playbackId = RpcUtils.requireStringParam(params, 'playbackId');
    final playback = _mediaPlaybackManager!.getPlayback(
      sourceDeviceId,
      playbackId,
    );
    if (playback == null) {
      throw const RiftException(-32009, 'Media playback was not found');
    }
    return playback.toJson();
  }

  @visibleForTesting
  static Map<String, dynamic> buildNotificationReplayMessage({
    required String localDeviceId,
    required String peerDeviceId,
    required Map<String, dynamic> record,
  }) => {
    'rift': '0.1-draft',
    'messageId': const Uuid().v4(),
    'type': 'notification.updated',
    'sourceDeviceId': localDeviceId,
    'destinationDeviceId': peerDeviceId,
    'payload': record,
  };

  Future<void> _replayActiveSyncState(String peerDeviceId) async {
    final sessionManager = _sessionManager;
    final identityManager = _identityManager;
    final mediaPlaybackManager = _mediaPlaybackManager;
    if (sessionManager == null ||
        identityManager == null ||
        mediaPlaybackManager == null) {
      return;
    }

    final context = sessionManager.getContext(peerDeviceId);
    if (context == null || context.trustState != TrustState.trusted) {
      return;
    }

    final localDeviceId = identityManager.deviceId;
    if (context.hasCapability('notification.sync')) {
      for (final record in _notificationSyncRecords.values) {
        if (record['sourceDeviceId'] != localDeviceId) {
          continue;
        }
        try {
          await sessionManager.sendMessage(
            peerDeviceId,
            buildNotificationReplayMessage(
              localDeviceId: localDeviceId,
              peerDeviceId: peerDeviceId,
              record: record,
            ),
          );
        } catch (error) {
          RiftLog.warn(
            '[NotificationSync] Failed to replay active state to $peerDeviceId: $error',
          );
          return;
        }
      }
    }

    if (context.hasCapability('media.playback')) {
      final playbacks = mediaPlaybackManager.listStateJson()['playbacks'];
      if (playbacks is! List) {
        return;
      }
      for (final playback in playbacks.whereType<Map>()) {
        final record = Map<String, dynamic>.from(playback);
        if (record['sourceDeviceId'] != localDeviceId) {
          continue;
        }
        try {
          await sessionManager.sendMessage(peerDeviceId, {
            'rift': '0.1-draft',
            'messageId': const Uuid().v4(),
            'type': 'media.playbackPosted',
            'sourceDeviceId': localDeviceId,
            'destinationDeviceId': peerDeviceId,
            'payload': record,
          });
        } catch (error) {
          RiftLog.warn(
            '[MediaPlayback] Failed to replay active state to $peerDeviceId: $error',
          );
          return;
        }
      }
    }
  }

  Future<List<String>> _broadcastMediaPlaybackEnvelope({
    required String messageType,
    required Map<String, dynamic> payload,
  }) async {
    final trustedPeers = await _trustStore!.getPeersByState(TrustState.trusted);
    final broadcastTo = <String>[];
    for (final peer in trustedPeers) {
      try {
        await _ensureTrustedSessionForPeer(peer.deviceId);
        final ctx = _sessionManager!.getContext(peer.deviceId);
        if (ctx == null || !ctx.hasCapability('media.playback')) {
          continue;
        }
        await _sessionManager!.sendMessage(peer.deviceId, {
          'rift': '0.1-draft',
          'messageId': const Uuid().v4(),
          'type': messageType,
          'sourceDeviceId': _identityManager!.deviceId,
          'destinationDeviceId': peer.deviceId,
          'payload': payload,
        });
        broadcastTo.add(peer.deviceId);
      } catch (error) {
        RiftLog.warn(
          '[MediaPlayback] Could not send $messageType to ${peer.deviceId}: $error',
        );
      }
    }
    return broadcastTo;
  }

  Future<Map<String, dynamic>> _handleLocalMediaPlaybackEvent(
    Map<String, dynamic> params,
  ) async {
    _requireTransportServices();
    final eventType = RpcUtils.requireStringParam(params, 'eventType');
    final playbackId = RpcUtils.requireStringParam(params, 'playbackId');
    final localDeviceId = _identityManager!.deviceId;

    if (eventType == 'removed') {
      final removedAt = _optionalMediaPlaybackTimestamp(params, 'removedAt');
      _mediaPlaybackManager!.removePlayback(
        localDeviceId,
        playbackId,
        removedAt: removedAt,
      );
      final payload = <String, dynamic>{
        'playbackId': playbackId,
        'sourceDeviceId': localDeviceId,
        'removedAt': ?removedAt,
      };
      return {
        'playbackId': playbackId,
        'broadcastTo': await _broadcastMediaPlaybackEnvelope(
          messageType: 'media.playbackRemoved',
          payload: payload,
        ),
      };
    }

    if (eventType != 'posted' && eventType != 'updated') {
      throw ArgumentError.value(
        eventType,
        'eventType',
        'must be posted, updated, or removed',
      );
    }

    final record = MediaPlaybackRecord(
      playbackId: playbackId,
      sourceDeviceId: localDeviceId,
      sourcePlatform: params['sourcePlatform'] as String?,
      appId: RpcUtils.requireStringParam(params, 'appId'),
      appName: RpcUtils.requireStringParam(params, 'appName'),
      title: params['title'] as String?,
      artist: params['artist'] as String?,
      album: params['album'] as String?,
      artwork: params['artwork'] is Map
          ? Map<String, dynamic>.from(params['artwork'] as Map)
          : null,
      playbackState: RpcUtils.requireStringParam(params, 'playbackState'),
      positionMs: RpcUtils.requireIntParam(params, 'positionMs'),
      durationMs: params['durationMs'] as int?,
      canPlay: _requireMediaPlaybackBool(params, 'canPlay'),
      canPause: _requireMediaPlaybackBool(params, 'canPause'),
      canSkipNext: _requireMediaPlaybackBool(params, 'canSkipNext'),
      canSkipPrevious: _requireMediaPlaybackBool(params, 'canSkipPrevious'),
      canSeek: _requireMediaPlaybackBool(params, 'canSeek'),
      updatedAt: RpcUtils.requireStringParam(params, 'updatedAt'),
    );
    _validateMediaPlaybackRecord(record);
    final result = _mediaPlaybackManager!.notifyLocalEvent(eventType, record);
    return {
      ...result,
      'broadcastTo': await _broadcastMediaPlaybackEnvelope(
        messageType: eventType == 'posted'
            ? 'media.playbackPosted'
            : 'media.playbackUpdated',
        payload: record.toJson(),
      ),
    };
  }

  Future<Map<String, dynamic>> _performMediaPlaybackAction(
    Map<String, dynamic> params,
  ) async {
    _requireTransportServices();
    final sourceDeviceId = RpcUtils.requireStringParam(
      params,
      'sourceDeviceId',
    );
    final playbackId = RpcUtils.requireStringParam(params, 'playbackId');
    final action = _normalizeMediaPlaybackAction(
      RpcUtils.requireStringParam(params, 'action'),
      params['positionMs'] as int?,
    );
    final playback = _mediaPlaybackManager!.getPlayback(
      sourceDeviceId,
      playbackId,
    );
    if (playback == null) {
      throw const RiftException(-32009, 'Media playback was not found');
    }
    _ensureMediaPlaybackActionAllowed(playback, action);

    await _ensureTrustedSessionForPeer(sourceDeviceId);
    try {
      _sessionManager!.requireCapability(sourceDeviceId, 'media.playback');
    } catch (error) {
      throw RiftException(-32003, error.toString());
    }

    final actionKey = '$sourceDeviceId\n$playbackId\n$action';
    if (_pendingMediaPlaybackActionKeys.containsKey(actionKey)) {
      throw const RiftException(
        -32010,
        'A matching playback action is pending',
      );
    }

    final operationId = const Uuid().v4();
    _operationManager!.createOperation(
      operationId: operationId,
      operationType: _mediaPlaybackOperationType(action),
      sourceDeviceId: _identityManager!.deviceId,
      destinationDeviceId: sourceDeviceId,
    );
    _operationManager!.transitionOperation(
      operationId,
      OperationState.pending,
      details: {
        'playbackId': playbackId,
        'sourceDeviceId': sourceDeviceId,
        'action': action,
        if (params['positionMs'] != null) 'positionMs': params['positionMs'],
      },
    );
    _pendingMediaPlaybackActions[operationId] = {
      'operationId': operationId,
      'sourceDeviceId': sourceDeviceId,
      'playbackId': playbackId,
      'action': action,
      'actionKey': actionKey,
    };
    _pendingMediaPlaybackActionKeys[actionKey] = operationId;
    _pendingMediaPlaybackActionTimers[operationId] = Timer(
      mediaPlaybackActionTimeout,
      () => _expirePendingMediaPlaybackAction(operationId),
    );
    _operationManager!.transitionOperation(
      operationId,
      OperationState.dispatched,
    );

    try {
      await _sessionManager!.sendMessage(sourceDeviceId, {
        'rift': '0.1-draft',
        'messageId': const Uuid().v4(),
        'type': 'media.playbackActionRequest',
        'sourceDeviceId': _identityManager!.deviceId,
        'destinationDeviceId': sourceDeviceId,
        'operationId': operationId,
        'payload': {
          'playbackId': playbackId,
          'sourceDeviceId': sourceDeviceId,
          'requestingDeviceId': _identityManager!.deviceId,
          'action': action,
          if (params['positionMs'] != null) 'positionMs': params['positionMs'],
          'requestedAt': DateTime.now().toUtc().toIso8601String(),
        },
      });
    } catch (error) {
      final pending = _pendingMediaPlaybackActions.remove(operationId);
      if (pending != null) {
        if (_pendingMediaPlaybackActionKeys[actionKey] == operationId) {
          _pendingMediaPlaybackActionKeys.remove(actionKey);
        }
        _pendingMediaPlaybackActionTimers.remove(operationId)?.cancel();
        _operationManager!.transitionOperation(
          operationId,
          OperationState.failed,
          failureReason: 'PeerUnreachable',
        );
      }
      throw RiftException(-32003, 'Failed to send playback action: $error');
    }

    return {
      'operationId': operationId,
      'sourceDeviceId': sourceDeviceId,
      'playbackId': playbackId,
      'action': action,
      'state': 'Pending',
    };
  }

  void _expirePendingMediaPlaybackAction(String operationId) {
    final pending = _pendingMediaPlaybackActions.remove(operationId);
    _pendingMediaPlaybackActionTimers.remove(operationId);
    if (pending == null) {
      return;
    }

    final actionKey = pending['actionKey'] as String;
    if (_pendingMediaPlaybackActionKeys[actionKey] == operationId) {
      _pendingMediaPlaybackActionKeys.remove(actionKey);
    }
    _operationManager?.transitionOperation(
      operationId,
      OperationState.expired,
      failureReason: 'Timeout',
    );
  }

  Future<Map<String, dynamic>> _reportLocalMediaPlaybackActionHandled(
    Map<String, dynamic> params,
  ) async {
    _requireTransportServices();
    final requestId = RpcUtils.requireStringParam(params, 'requestId');
    final success = params['success'];
    if (success is! bool) {
      throw ArgumentError.value(success, 'success', 'must be a boolean');
    }
    final failureReason = _normalizeMediaPlaybackFailureReason(
      success: success,
      failureReason: params['failureReason'],
      invalidCode: -32602,
    );
    final message = params['message'];
    if (message != null && message is! String) {
      throw ArgumentError.value(message, 'message', 'must be a string');
    }
    final pending = _pendingIncomingMediaPlaybackActions.remove(requestId);
    if (pending == null) {
      throw const RiftException(
        -32009,
        'Playback action request was not found',
      );
    }
    _pendingIncomingMediaPlaybackActionTimers.remove(requestId)?.cancel();
    await _sendMediaPlaybackActionResult(
      pending,
      success: success,
      failureReason: failureReason,
      message: message as String?,
    );
    return {
      'requestId': requestId,
      'playbackId': pending['playbackId'],
      'action': pending['action'],
      'success': success,
    };
  }

  String? _normalizeMediaPlaybackFailureReason({
    required bool success,
    required Object? failureReason,
    required int invalidCode,
  }) {
    if (failureReason != null) {
      if (failureReason is! String) {
        throw ArgumentError.value(
          failureReason,
          'failureReason',
          'must be a string',
        );
      }
      if (!_failureReasons.contains(failureReason)) {
        throw RiftException(
          invalidCode,
          'Invalid failureReason: $failureReason',
        );
      }
      if (success) {
        return null;
      }
      return failureReason;
    }
    return success ? null : 'PeerRejected';
  }

  @visibleForTesting
  String? normalizeMediaPlaybackFailureReasonForTesting({
    required bool success,
    required Object? failureReason,
    required int invalidCode,
  }) => _normalizeMediaPlaybackFailureReason(
    success: success,
    failureReason: failureReason,
    invalidCode: invalidCode,
  );

  Future<void> _sendMediaPlaybackActionResult(
    Map<String, dynamic> request, {
    required bool success,
    String? failureReason,
    String? message,
  }) async {
    final requestingDeviceId = request['requestingDeviceId'] as String;
    await _sessionManager!.sendMessage(requestingDeviceId, {
      'rift': '0.1-draft',
      'messageId': const Uuid().v4(),
      'type': 'media.playbackActionResult',
      'sourceDeviceId': _identityManager!.deviceId,
      'destinationDeviceId': requestingDeviceId,
      'payload': {
        'playbackId': request['playbackId'],
        'sourceDeviceId': _identityManager!.deviceId,
        'requestingDeviceId': requestingDeviceId,
        'action': request['action'],
        'success': success,
        'failureReason': ?failureReason,
        'message': ?message,
      },
    });
  }

  Future<void> _trySendMediaPlaybackActionResult(
    Map<String, dynamic> request, {
    required bool success,
    String? failureReason,
    String? message,
  }) async {
    try {
      await _sendMediaPlaybackActionResult(
        request,
        success: success,
        failureReason: failureReason,
        message: message,
      );
    } catch (error) {
      RiftLog.warn(
        '[MediaPlayback] Failed to send incoming action result: $error',
      );
    }
  }

  Future<void> _expireIncomingMediaPlaybackAction(String requestId) async {
    _pendingIncomingMediaPlaybackActionTimers.remove(requestId);
    final pending = _pendingIncomingMediaPlaybackActions.remove(requestId);
    if (pending == null) {
      return;
    }
    try {
      await _sendMediaPlaybackActionResult(
        pending,
        success: false,
        failureReason: 'Timeout',
        message: 'The local media control client did not handle the request.',
      );
    } catch (error) {
      RiftLog.warn(
        '[MediaPlayback] Failed to expire incoming action $requestId: $error',
      );
    }
  }

  String? _optionalMediaPlaybackTimestamp(
    Map<String, dynamic> payload,
    String key,
  ) {
    final value = payload[key];
    if (value == null) {
      return null;
    }
    if (value is! String || !_isRfc3339UtcTimestamp(value)) {
      throw ArgumentError.value(
        value,
        key,
        'must be a full RFC 3339 UTC timestamp',
      );
    }
    return value;
  }

  bool _requireMediaPlaybackBool(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is! bool) {
      throw ArgumentError.value(value, key, 'must be a boolean');
    }
    return value;
  }

  void _validateMediaPlaybackRecord(MediaPlaybackRecord playback) {
    const playbackStates = {'playing', 'paused', 'stopped', 'buffering'};
    if (!playbackStates.contains(playback.playbackState)) {
      throw ArgumentError.value(
        playback.playbackState,
        'playbackState',
        'must be playing, paused, stopped, or buffering',
      );
    }
    if (playback.positionMs < 0 ||
        (playback.durationMs != null && playback.durationMs! < 0)) {
      throw const RiftException(
        -32602,
        'positionMs and durationMs must be non-negative',
      );
    }
    if (!_isRfc3339UtcTimestamp(playback.updatedAt)) {
      throw ArgumentError.value(
        playback.updatedAt,
        'updatedAt',
        'must be a full RFC 3339 UTC timestamp',
      );
    }
  }

  bool _isRfc3339UtcTimestamp(String value) {
    final match = _rfc3339UtcTimestamp.firstMatch(value);
    final timestamp = DateTime.tryParse(value);
    if (match == null || timestamp == null || !timestamp.isUtc) {
      return false;
    }
    final parts = value.substring(0, 19).split(RegExp(r'[-T:]'));
    final expected = parts.map(int.parse).toList(growable: false);
    return expected[0] > 0 &&
        timestamp.year == expected[0] &&
        timestamp.month == expected[1] &&
        timestamp.day == expected[2] &&
        timestamp.hour == expected[3] &&
        timestamp.minute == expected[4] &&
        timestamp.second == expected[5];
  }

  String _normalizeMediaPlaybackAction(
    String action,
    int? positionMs, {
    bool allowSeekWithoutPosition = false,
  }) {
    const actions = {
      'play',
      'pause',
      'togglePlayPause',
      'next',
      'previous',
      'seek',
    };
    if (!actions.contains(action)) {
      throw RiftException(-32010, 'Unknown media playback action: $action');
    }
    if (action == 'seek' &&
        !allowSeekWithoutPosition &&
        (positionMs == null || positionMs < 0)) {
      throw const RiftException(
        -32602,
        'A non-negative positionMs is required for seek',
      );
    }
    return action;
  }

  void _ensureMediaPlaybackActionAllowed(
    MediaPlaybackRecord playback,
    String action,
  ) {
    final allowed = switch (action) {
      'play' => playback.canPlay,
      'pause' => playback.canPause,
      'togglePlayPause' => playback.canPlay || playback.canPause,
      'next' => playback.canSkipNext,
      'previous' => playback.canSkipPrevious,
      'seek' => playback.canSeek,
      _ => false,
    };
    if (!allowed) {
      throw RiftException(
        -32010,
        "Media playback does not allow action '$action'",
      );
    }
  }

  String _mediaPlaybackOperationType(String action) => switch (action) {
    'play' => 'media.play',
    'pause' => 'media.pause',
    'togglePlayPause' => 'media.toggle',
    'next' => 'media.next',
    'previous' => 'media.previous',
    'seek' => 'media.seek',
    _ => 'media.playback',
  };

  Map<String, dynamic> _listNotificationSyncState() {
    final notifications =
        _notificationSyncRecords.values.toList(growable: false)..sort((a, b) {
          final aPostedAt = a['postedAt'] as String? ?? '';
          final bPostedAt = b['postedAt'] as String? ?? '';
          return bPostedAt.compareTo(aPostedAt);
        });
    return {
      'notifications': notifications,
      'policy': _notificationSyncPolicy.toJson(),
    };
  }

  String _notificationRecordKey(String sourceDeviceId, String notificationId) =>
      '$sourceDeviceId\n$notificationId';

  Map<String, dynamic> _normalizeNotificationRecord(
    Map<String, dynamic> params, {
    required String notificationId,
    required String sourceDeviceId,
  }) {
    final record = <String, dynamic>{
      'notificationId': notificationId,
      'sourceDeviceId': sourceDeviceId,
      if (params['sourcePlatform'] is String &&
          (params['sourcePlatform'] as String).isNotEmpty)
        'sourcePlatform': params['sourcePlatform'],
      'packageName': RpcUtils.requireStringParam(params, 'packageName'),
      'appName': RpcUtils.requireStringParam(params, 'appName'),
      if (params['title'] is String && (params['title'] as String).isNotEmpty)
        'title': params['title'],
      if (params['bodyPreview'] is String &&
          (params['bodyPreview'] as String).isNotEmpty)
        'bodyPreview': params['bodyPreview'],
      'postedAt': RpcUtils.requireStringParam(params, 'postedAt'),
    };

    final isDismissible = params['isDismissible'];
    final isOpenable = params['isOpenable'];
    if (isDismissible is! bool || isOpenable is! bool) {
      throw ArgumentError.value(
        params,
        'isDismissible/isOpenable',
        'must be booleans',
      );
    }
    record['isDismissible'] = isDismissible;
    record['isOpenable'] = isOpenable;
    return record;
  }

  bool _isNotificationBlacklisted(String packageName) {
    return _notificationSyncPolicy.blacklistedPackages.contains(packageName);
  }

  Future<List<String>> _broadcastNotificationSyncEnvelope({
    required String messageType,
    required Map<String, dynamic> payload,
  }) async {
    final trustedPeers = await _trustStore!.getPeersByState(TrustState.trusted);
    final broadcastTo = <String>[];
    for (final peer in trustedPeers) {
      try {
        await _ensureTrustedSessionForPeer(peer.deviceId);
        final ctx = _sessionManager!.getContext(peer.deviceId);
        if (ctx == null || !ctx.hasCapability('notification.sync')) {
          continue;
        }
        await _sessionManager!.sendMessage(peer.deviceId, {
          'rift': '0.1-draft',
          'messageId': const Uuid().v4(),
          'type': messageType,
          'sourceDeviceId': _identityManager!.deviceId,
          'destinationDeviceId': peer.deviceId,
          'payload': payload,
        });
        broadcastTo.add(peer.deviceId);
      } catch (error) {
        RiftLog.warn(
          '[NotificationSync] Could not send $messageType to ${peer.deviceId}: $error',
        );
      }
    }
    return broadcastTo;
  }

  Future<Map<String, dynamic>> _handleLocalNotificationSyncEvent(
    Map<String, dynamic> params,
  ) async {
    _requireTransportServices();
    final eventType = RpcUtils.requireStringParam(params, 'eventType');
    final notificationId = RpcUtils.requireStringParam(
      params,
      'notificationId',
    );
    final localDeviceId = _identityManager!.deviceId;

    switch (eventType) {
      case 'posted':
      case 'updated':
        final record = _normalizeNotificationRecord(
          params,
          notificationId: notificationId,
          sourceDeviceId: localDeviceId,
        );

        _notificationSyncRecords[_notificationRecordKey(
              localDeviceId,
              notificationId,
            )] =
            record;

        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': eventType == 'posted'
              ? 'rift.onNotificationPosted'
              : 'rift.onNotificationUpdated',
          'params': record,
        });

        var broadcastTo = const <String>[];
        final packageName = record['packageName'] as String;
        if (_notificationSyncPolicy.enabled &&
            !_isNotificationBlacklisted(packageName)) {
          broadcastTo = await _broadcastNotificationSyncEnvelope(
            messageType: eventType == 'posted'
                ? 'notification.posted'
                : 'notification.updated',
            payload: record,
          );
        }

        return {
          'notificationId': notificationId,
          'broadcastTo': broadcastTo,
          'suppressed':
              !_notificationSyncPolicy.enabled ||
              _isNotificationBlacklisted(packageName),
        };
      case 'removed':
        final removedPayload = <String, dynamic>{
          'notificationId': notificationId,
          'sourceDeviceId': localDeviceId,
          if (params['removedAt'] is String &&
              (params['removedAt'] as String).isNotEmpty)
            'removedAt': params['removedAt'],
        };
        _notificationSyncRecords.remove(
          _notificationRecordKey(localDeviceId, notificationId),
        );

        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onNotificationRemoved',
          'params': removedPayload,
        });

        final broadcastTo = await _broadcastNotificationSyncEnvelope(
          messageType: 'notification.removed',
          payload: removedPayload,
        );
        return {'notificationId': notificationId, 'broadcastTo': broadcastTo};
      default:
        throw ArgumentError.value(
          eventType,
          'eventType',
          'must be posted, updated, or removed',
        );
    }
  }

  Future<void> _handleNotificationSyncProtocolMessage(
    ProtocolMessage message,
  ) async {
    final type = message.payload['type'] as String?;
    if (type == null || !type.startsWith('notification.')) {
      return;
    }

    try {
      _sessionManager!.requireCapability(
        message.peerDeviceId,
        'notification.sync',
      );
    } catch (error) {
      RiftLog.warn(
        '[NotificationSync] Dropping $type from ${message.peerDeviceId}: $error',
      );
      return;
    }

    final payload = message.payload['payload'];
    if (payload is! Map<String, dynamic>) {
      RiftLog.warn(
        '[NotificationSync] Missing payload for $type from ${message.peerDeviceId}',
      );
      return;
    }

    switch (type) {
      case 'notification.posted':
      case 'notification.updated':
        final record = _normalizeNotificationRecord(
          payload,
          notificationId: RpcUtils.requireStringParam(
            payload,
            'notificationId',
          ),
          sourceDeviceId: RpcUtils.requireStringParam(
            payload,
            'sourceDeviceId',
          ),
        );
        if (record['sourceDeviceId'] != message.peerDeviceId) {
          RiftLog.warn(
            '[NotificationSync] Dropping $type from ${message.peerDeviceId}: sourceDeviceId mismatch',
          );
          return;
        }
        _notificationSyncRecords[_notificationRecordKey(
              record['sourceDeviceId'] as String,
              record['notificationId'] as String,
            )] =
            record;
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': type == 'notification.posted'
              ? 'rift.onNotificationPosted'
              : 'rift.onNotificationUpdated',
          'params': record,
        });
        return;
      case 'notification.removed':
        final notificationId = RpcUtils.requireStringParam(
          payload,
          'notificationId',
        );
        final sourceDeviceId = RpcUtils.requireStringParam(
          payload,
          'sourceDeviceId',
        );
        if (sourceDeviceId != message.peerDeviceId) {
          RiftLog.warn(
            '[NotificationSync] Dropping $type from ${message.peerDeviceId}: sourceDeviceId mismatch',
          );
          return;
        }
        _notificationSyncRecords.remove(
          _notificationRecordKey(sourceDeviceId, notificationId),
        );
        onIpcEvent?.call({
          'jsonrpc': '2.0',
          'method': 'rift.onNotificationRemoved',
          'params': <String, dynamic>{
            'notificationId': notificationId,
            'sourceDeviceId': sourceDeviceId,
            if (payload['removedAt'] is String &&
                (payload['removedAt'] as String).isNotEmpty)
              'removedAt': payload['removedAt'],
          },
        });
        return;
      default:
        return;
    }
  }

  @visibleForTesting
  SessionManager get sessionManagerForTesting => _sessionManager!;

  @visibleForTesting
  Future<void> handleMediaPlaybackProtocolMessageForTesting(
    String peerDeviceId,
    Map<String, dynamic> envelope,
  ) => _handleMediaPlaybackProtocolMessage(
    ProtocolMessage(peerDeviceId, null, envelope),
  );

  Future<void> _handleMediaPlaybackProtocolMessage(
    ProtocolMessage message,
  ) async {
    try {
      await _handleValidatedMediaPlaybackProtocolMessage(message);
    } on RiftException catch (error) {
      final reason = error.code == -32010
          ? 'ProtocolError'
          : 'MalformedMessage';
      RiftLog.warn(
        '[MediaPlayback] Dropping $reason from ${message.peerDeviceId}: $error',
      );
      try {
        await _sessionManager!.sendPeerError(
          message.peerDeviceId,
          failureReason: reason,
          refMessageId: message.payload['messageId'] is String
              ? message.payload['messageId'] as String
              : null,
          message: error.message,
        );
      } catch (rejectError) {
        RiftLog.warn(
          '[MediaPlayback] Failed to send $reason to ${message.peerDeviceId}: $rejectError',
        );
      }
    } on ArgumentError catch (error) {
      await _rejectMalformedMediaPlaybackMessage(message, error);
    } on TypeError catch (error) {
      await _rejectMalformedMediaPlaybackMessage(message, error);
    }
  }

  Future<void> _trySendMediaPlaybackPeerError(
    ProtocolMessage message,
    String failureReason,
    String errorMessage,
  ) async {
    try {
      await _sessionManager!.sendPeerError(
        message.peerDeviceId,
        failureReason: failureReason,
        refMessageId: message.payload['messageId'] is String
            ? message.payload['messageId'] as String
            : null,
        message: errorMessage,
      );
    } catch (error) {
      RiftLog.warn(
        '[MediaPlayback] Failed to send $failureReason to ${message.peerDeviceId}: $error',
      );
    }
  }

  Future<void> _rejectMalformedMediaPlaybackMessage(
    ProtocolMessage message,
    Object error,
  ) async {
    RiftLog.warn(
      '[MediaPlayback] Dropping MalformedMessage from ${message.peerDeviceId}: $error',
    );
    await _trySendMediaPlaybackPeerError(
      message,
      'MalformedMessage',
      error.toString(),
    );
  }

  Future<void> _handleValidatedMediaPlaybackProtocolMessage(
    ProtocolMessage message,
  ) async {
    final type = message.payload['type'] as String?;
    if (type == null || !type.startsWith('media.playback')) {
      return;
    }

    try {
      _sessionManager!.requireCapability(
        message.peerDeviceId,
        'media.playback',
      );
    } catch (error) {
      final failureReason = error.toString().contains('CapabilityUnavailable')
          ? 'CapabilityUnavailable'
          : 'Unauthorized';
      RiftLog.warn(
        '[MediaPlayback] Dropping $type from ${message.peerDeviceId}: $error',
      );
      await _trySendMediaPlaybackPeerError(
        message,
        failureReason,
        error.toString(),
      );
      return;
    }

    final payload = message.payload['payload'];
    if (payload is! Map<String, dynamic>) {
      throw ArgumentError.value(payload, 'payload', 'must be an object');
    }

    if (type == 'media.playbackActionRequest') {
      final sourceDeviceId = RpcUtils.requireStringParam(
        payload,
        'sourceDeviceId',
      );
      final requestingDeviceId = RpcUtils.requireStringParam(
        payload,
        'requestingDeviceId',
      );
      if (sourceDeviceId != _identityManager!.deviceId ||
          requestingDeviceId != message.peerDeviceId) {
        const errorMessage = 'Media playback action request identity mismatch';
        RiftLog.warn(
          '[MediaPlayback] Dropping $type from ${message.peerDeviceId}: $errorMessage',
        );
        await _trySendMediaPlaybackPeerError(
          message,
          'Unauthorized',
          errorMessage,
        );
        return;
      }
      final requestId = const Uuid().v4();
      final action = _normalizeMediaPlaybackAction(
        RpcUtils.requireStringParam(payload, 'action'),
        payload['positionMs'] as int?,
      );
      final playbackId = RpcUtils.requireStringParam(payload, 'playbackId');
      final requestedAt = _optionalMediaPlaybackTimestamp(
        payload,
        'requestedAt',
      );
      final request = <String, dynamic>{
        'requestId': requestId,
        'playbackId': playbackId,
        'sourceDeviceId': sourceDeviceId,
        'requestingDeviceId': requestingDeviceId,
        'action': action,
        if (payload['positionMs'] is int) 'positionMs': payload['positionMs'],
        'requestedAt': ?requestedAt,
      };
      final localPlayback = _mediaPlaybackManager!.getPlayback(
        sourceDeviceId,
        playbackId,
      );
      if (localPlayback == null) {
        await _trySendMediaPlaybackActionResult(
          request,
          success: false,
          failureReason: 'CapabilityUnavailable',
          message: 'The local media playback was not found.',
        );
        return;
      }
      try {
        _ensureMediaPlaybackActionAllowed(localPlayback, action);
      } on RiftException catch (error) {
        await _trySendMediaPlaybackActionResult(
          request,
          success: false,
          failureReason: 'CapabilityUnavailable',
          message: error.message,
        );
        return;
      }
      if (onIpcEvent == null) {
        await _trySendMediaPlaybackActionResult(
          request,
          success: false,
          failureReason: 'CapabilityUnavailable',
          message: 'No local media control client is connected.',
        );
        return;
      }
      _pendingIncomingMediaPlaybackActions[requestId] = request;
      _pendingIncomingMediaPlaybackActionTimers[requestId] = Timer(
        mediaPlaybackActionTimeout,
        () => unawaited(_expireIncomingMediaPlaybackAction(requestId)),
      );
      onIpcEvent?.call({
        'jsonrpc': '2.0',
        'method': 'rift.onMediaPlaybackActionRequest',
        'params': request,
      });
      return;
    }

    final sourceDeviceId = RpcUtils.requireStringParam(
      payload,
      'sourceDeviceId',
    );
    if (sourceDeviceId != message.peerDeviceId) {
      const errorMessage = 'Media playback sourceDeviceId mismatch';
      RiftLog.warn(
        '[MediaPlayback] Dropping $type from ${message.peerDeviceId}: $errorMessage',
      );
      await _trySendMediaPlaybackPeerError(
        message,
        'Unauthorized',
        errorMessage,
      );
      return;
    }

    if (type == 'media.playbackActionResult') {
      final requestingDeviceId = RpcUtils.requireStringParam(
        payload,
        'requestingDeviceId',
      );
      if (requestingDeviceId != _identityManager!.deviceId) {
        const errorMessage = 'Media playback requestingDeviceId mismatch';
        RiftLog.warn(
          '[MediaPlayback] Dropping $type from ${message.peerDeviceId}: $errorMessage',
        );
        await _trySendMediaPlaybackPeerError(
          message,
          'Unauthorized',
          errorMessage,
        );
        return;
      }
      final playbackId = RpcUtils.requireStringParam(payload, 'playbackId');
      final action = _normalizeMediaPlaybackAction(
        RpcUtils.requireStringParam(payload, 'action'),
        null,
        allowSeekWithoutPosition: true,
      );
      final success = payload['success'];
      if (success is! bool) {
        throw ArgumentError.value(success, 'success', 'must be a boolean');
      }
      final failureReason = _normalizeMediaPlaybackFailureReason(
        success: success,
        failureReason: payload['failureReason'],
        invalidCode: -32010,
      );
      if (payload['message'] != null && payload['message'] is! String) {
        throw ArgumentError.value(
          payload['message'],
          'message',
          'must be a string',
        );
      }
      final actionKey = '$sourceDeviceId\n$playbackId\n$action';
      final operationId = _pendingMediaPlaybackActionKeys.remove(actionKey);
      final pending = operationId == null
          ? null
          : _pendingMediaPlaybackActions.remove(operationId);
      if (operationId == null || pending == null) {
        RiftLog.warn(
          '[MediaPlayback] Dropping unmatched action result from ${message.peerDeviceId}',
        );
        return;
      }
      _pendingMediaPlaybackActionTimers.remove(operationId)?.cancel();
      _operationManager!.transitionOperation(
        operationId,
        OperationState.active,
      );
      _operationManager!.transitionOperation(
        operationId,
        success ? OperationState.done : OperationState.failed,
        failureReason: failureReason,
        details: payload['message'] is String
            ? {'message': payload['message']}
            : null,
      );
      _mediaPlaybackManager!.addActionResult({
        'playbackId': playbackId,
        'sourceDeviceId': sourceDeviceId,
        'operationId': operationId,
        'action': action,
        'state': success ? 'Done' : 'Failed',
        'success': success,
        'failureReason': ?failureReason,
        if (payload['message'] is String) 'message': payload['message'],
      });
      return;
    }

    final playbackId = RpcUtils.requireStringParam(payload, 'playbackId');
    if (type == 'media.playbackRemoved') {
      _mediaPlaybackManager!.removePlayback(
        sourceDeviceId,
        playbackId,
        removedAt: _optionalMediaPlaybackTimestamp(payload, 'removedAt'),
      );
      return;
    }

    final record = MediaPlaybackRecord(
      playbackId: playbackId,
      sourceDeviceId: sourceDeviceId,
      sourcePlatform: payload['sourcePlatform'] as String?,
      appId: RpcUtils.requireStringParam(payload, 'appId'),
      appName: RpcUtils.requireStringParam(payload, 'appName'),
      title: payload['title'] as String?,
      artist: payload['artist'] as String?,
      album: payload['album'] as String?,
      artwork: payload['artwork'] is Map
          ? Map<String, dynamic>.from(payload['artwork'] as Map)
          : null,
      playbackState: RpcUtils.requireStringParam(payload, 'playbackState'),
      positionMs: RpcUtils.requireIntParam(payload, 'positionMs'),
      durationMs: payload['durationMs'] as int?,
      canPlay: _requireMediaPlaybackBool(payload, 'canPlay'),
      canPause: _requireMediaPlaybackBool(payload, 'canPause'),
      canSkipNext: _requireMediaPlaybackBool(payload, 'canSkipNext'),
      canSkipPrevious: _requireMediaPlaybackBool(payload, 'canSkipPrevious'),
      canSeek: _requireMediaPlaybackBool(payload, 'canSeek'),
      updatedAt: RpcUtils.requireStringParam(payload, 'updatedAt'),
    );
    _validateMediaPlaybackRecord(record);

    switch (type) {
      case 'media.playbackPosted':
        _mediaPlaybackManager!.notifyLocalEvent('posted', record);
        return;
      case 'media.playbackUpdated':
        _mediaPlaybackManager!.notifyLocalEvent('updated', record);
        return;
      default:
        return;
    }
  }

  Future<void> stop() async {
    _isStopping = true;
    await _notificationSyncMessageSub?.cancel();
    await _mediaPlaybackMessageSub?.cancel();
    await _sessionDisconnectSub?.cancel();
    for (final timer in _trustedReconnectTimers.values) {
      timer.cancel();
    }
    _trustedReconnectTimers.clear();
    _trustedReconnectAttempts.clear();
    _lastDiscoveryPrefetchAttempts.clear();
    for (final timer in _pendingMediaPlaybackActionTimers.values) {
      timer.cancel();
    }
    _pendingMediaPlaybackActionTimers.clear();
    for (final timer in _pendingIncomingMediaPlaybackActionTimers.values) {
      timer.cancel();
    }
    _pendingIncomingMediaPlaybackActionTimers.clear();
    await _pairingManager?.dispose();
    _clipboardHandler?.dispose();
    _clipboardEngine?.dispose();
    await _fileTransferService?.dispose();
    _mediaPlaybackManager?.dispose();
    _operationManager?.dispose();
    await _discoveryService?.stopDiscovery();
    await _discoveryService?.stopAdvertising();
    await _discoveryService?.dispose(); // closes _peerStreamController
    await _sessionManager?.dispose();
    await _transport?.stopServer();
    _trustStore?.dispose();
    await _identityManager?.dispose();
  }

  Future<bool> _shouldAutoStartDiscovery() async {
    final trustStore = _trustStore;
    if (trustStore == null) {
      return true;
    }

    for (final state in const [TrustState.trusted]) {
      final peers = await trustStore.getPeersByState(state);
      if (peers.isNotEmpty) {
        return false;
      }
    }

    return true;
  }

  Map<String, dynamic> getDeviceInfo() {
    final identityManager = _identityManager;
    if (identityManager == null) {
      throw const RiftIdentityNotInitializedException(
        'Identity manager not initialized',
      );
    }

    return {
      'deviceId': identityManager.deviceId,
      'displayName': identityManager.displayName,
      'platform': _localPlatform(),
      'fingerprint': _formatFingerprint(identityManager.getDeviceFingerprint()),
      'implementationId': RiftConstants.implementationId,
      'protocolVersion': RiftConstants.protocolVersion,
      'capabilities': RiftConstants.capabilities,
    };
  }

  Future<List<Map<String, dynamic>>> listTrustedPeers() async {
    final trustStore = _trustStore;
    final sessionManager = _sessionManager;
    if (trustStore == null) return [];

    // Device-list surface:
    // - trusted peers stay visible
    // - blocked peers stay visible
    // - pairing_pending stays visible
    final peers = <PeerRecord>[
      ...await trustStore.getPeersByState(TrustState.pairingPending),
      ...await trustStore.getPeersByState(TrustState.trusted),
      ...await trustStore.getPeersByState(TrustState.blocked),
    ];

    return peers.map((peer) {
      final ctx = sessionManager?.getContext(peer.deviceId);
      final lastSeenAt =
          ctx?.lastHeartbeatReceived?.toUtc().toIso8601String() ??
          peer.lastSeenAt?.toUtc().toIso8601String();
      return {
        'deviceId': peer.deviceId,
        if (peer.displayName != null) 'displayName': peer.displayName,
        'platform': peer.platform ?? _platformFromDisplayName(peer.displayName),
        'trustState': peer.state.toJson(),
        if (peer.pairedAt != null)
          'pairedAt': peer.pairedAt!.toUtc().toIso8601String(),
        'lastSeenAt': lastSeenAt,
        'presence': ctx?.currentPresenceStatus ?? 'offline',
        'capabilities':
            ctx?.negotiatedCapabilities.map((c) => c.name).toList() ??
            <String>[],
      };
    }).toList();
  }

  Future<List<Map<String, dynamic>>> listPeersByState(String trustState) async {
    final trustStore = _trustStore;
    final sessionManager = _sessionManager;
    if (trustStore == null) return [];

    final state = TrustState.fromJson(trustState);
    final peers = await trustStore.getPeersByState(state);

    return peers.map((peer) {
      final ctx = sessionManager?.getContext(peer.deviceId);
      final lastSeenAt =
          ctx?.lastHeartbeatReceived?.toUtc().toIso8601String() ??
          peer.lastSeenAt?.toUtc().toIso8601String();
      return {
        'deviceId': peer.deviceId,
        if (peer.displayName != null) 'displayName': peer.displayName,
        'platform': peer.platform ?? _platformFromDisplayName(peer.displayName),
        'trustState': peer.state.toJson(),
        if (peer.pairedAt != null)
          'pairedAt': peer.pairedAt!.toUtc().toIso8601String(),
        'lastSeenAt': lastSeenAt,
        'presence': ctx?.currentPresenceStatus ?? 'offline',
        'capabilities':
            ctx?.negotiatedCapabilities.map((c) => c.name).toList() ??
            <String>[],
      };
    }).toList();
  }

  Future<List<Map<String, dynamic>>> listDiscoveredPeers() async {
    final trustStore = _trustStore;
    final results = <Map<String, dynamic>>[];

    for (final entry in _discoveredPeers.entries) {
      final peer = entry.value.primaryPeer;
      if (peer == null) continue;
      final hintedDeviceId = entry.key;

      // Filter out our own device ID
      if (_identityManager != null &&
          hintedDeviceId == _identityManager!.deviceId) {
        continue;
      }

      final trustState = trustStore != null
          ? (await trustStore.getPeer(hintedDeviceId))?.state.toJson() ??
                'discovered'
          : 'discovered';
      final knownPeer = trustStore != null
          ? await trustStore.getPeer(hintedDeviceId)
          : null;

      results.add({
        'deviceId': hintedDeviceId,
        if (knownPeer?.displayName != null)
          'displayName': knownPeer!.displayName,
        'platform':
            knownPeer?.platform ??
            _platformFromDisplayName(knownPeer?.displayName),
        'address': peer.address,
        'port': peer.port,
        'trustState': trustState,
        'observedEndpoints': entry.value.observedEndpoints
            .map(
              (endpoint) => {
                'instanceId': endpoint.instanceId,
                'address': endpoint.address,
                'port': endpoint.port,
              },
            )
            .toList(growable: false),
        'txtRecord': {
          'minV': peer.minVersion,
          'maxV': peer.maxVersion,
          'did': peer.deviceIdHint,
          if (peer.fingerprintPrefix != null) 'fp': peer.fingerprintPrefix,
        },
      });
    }

    return results;
  }

  String _localPlatform() {
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isMacOS) {
      return 'macos';
    }
    if (Platform.isLinux) {
      return 'linux';
    }
    return 'unknown';
  }

  String _platformFromDisplayName(String? displayName) {
    if (displayName == null || displayName.isEmpty) {
      return 'unknown';
    }

    if (displayName.startsWith('Android ')) {
      return 'android';
    }
    if (displayName.startsWith('iOS ')) {
      return 'ios';
    }
    if (displayName.startsWith('Windows ')) {
      return 'windows';
    }
    if (displayName.startsWith('macOS ')) {
      return 'macos';
    }
    if (displayName.startsWith('Linux ')) {
      return 'linux';
    }
    return 'unknown';
  }

  Future<Map<String, dynamic>> queryEventLog({
    List<String>? eventTypes,
    List<String>? severities,
    String? peerDeviceId,
    String? since,
    int limit = 100,
    int offset = 0,
  }) async {
    final trustStore = _trustStore;
    if (trustStore == null) {
      return {'events': const <Map<String, dynamic>>[], 'total': 0};
    }

    final sinceTime = since == null || since.isEmpty
        ? null
        : DateTime.tryParse(since);
    final filtered = await trustStore.querySecurityEvents(
      SecurityEventQuery(
        eventTypes: eventTypes,
        severities: severities,
        peerDeviceId: peerDeviceId,
        since: sinceTime,
        limit: limit,
        offset: offset,
      ),
    );
    final total = await trustStore.countSecurityEvents(
      SecurityEventQuery(
        eventTypes: eventTypes,
        severities: severities,
        peerDeviceId: peerDeviceId,
        since: sinceTime,
      ),
    );
    return {
      'events': filtered.map((event) => event.toJson()).toList(),
      'total': total,
    };
  }

  Map<String, dynamic> listOperations({int limit = 50, int offset = 0}) {
    final operationManager = _operationManager;
    if (operationManager == null) {
      return {'operations': const <Map<String, dynamic>>[], 'total': 0};
    }

    return {
      'operations': operationManager
          .listOperations(limit: limit, offset: offset)
          .map((operation) => operation.toListJson())
          .toList(growable: false),
      'total': operationManager.totalCount,
    };
  }

  Map<String, dynamic> getOperation(String operationId) {
    final operationManager = _operationManager;
    if (operationManager == null) {
      throw const RiftNotFoundException('Operation not found');
    }

    return operationManager.getOperation(operationId).toDetailJson();
  }

  Future<Map<String, dynamic>> handleJsonRpcRequest(
    Map<String, dynamic> request,
  ) async {
    final method = request['method'] as String?;
    final params = RpcUtils.normalizeParams(request['params']);
    if (method == null) {
      throw UnsupportedError('Method not found: null');
    }

    switch (method) {
      case 'rift.getDeviceInfo':
        return getDeviceInfo();
      case 'rift.listTrustedPeers':
        return {'peers': await listTrustedPeers()};
      case 'rift.listPeersByState':
        final state = RpcUtils.requireStringParam(params, 'trustState');
        return {'peers': await listPeersByState(state)};
      case 'rift.getPeerPresence':
        final peerDeviceId = RpcUtils.requireStringParam(params, 'deviceId');
        final trustRecord = await _trustStore!.getPeer(peerDeviceId);
        if (trustRecord == null) {
          throw const RiftNotFoundException('Peer not found in TrustStore');
        }
        if (trustRecord.state != TrustState.trusted) {
          throw const RiftUnauthorizedException('Peer is not trusted');
        }
        final ctx = _sessionManager?.getContext(peerDeviceId);
        return {
          'deviceId': peerDeviceId,
          'status': ctx?.currentPresenceStatus ?? 'offline',
          'lastSeenAt':
              ctx?.lastHeartbeatReceived?.toUtc().toIso8601String() ??
              trustRecord.lastSeenAt?.toUtc().toIso8601String(),
          'capabilities':
              ctx?.negotiatedCapabilities.map((c) => c.name).toList() ?? [],
        };
      case 'rift.listDiscoveredPeers':
        return {
          'peers': await listDiscoveredPeers(),
          'isDiscovering': _isDiscovering,
        };
      case 'rift.notifyClipboardChange':
        _requireTransportServices();
        final contentType = RpcUtils.requireStringParam(params, 'contentType');
        final byteSize = RpcUtils.requireIntParam(params, 'byteSize');
        final sha256 = RpcUtils.requireStringParam(params, 'sha256');
        final contentBase64 = RpcUtils.requireStringParam(
          params,
          'contentBase64',
        );
        const expiresInMs = 120000; // 2 minutes per spec default

        if (byteSize < 0) {
          throw const RiftException(-32600, 'byteSize must be non-negative');
        }

        // Guard: 32 MiB max
        if (byteSize > 32 * 1024 * 1024) {
          throw const RiftException(
            -32007,
            'Content exceeds maximum payload size',
          );
        }

        _validateClipboardChangePayload(
          byteSize: byteSize,
          sha256Hex: sha256,
          contentBase64: contentBase64,
        );

        final offerId = const Uuid().v4();
        final offer = _clipboardEngine!.createLocalOffer(
          offerId: offerId,
          contentType: contentType,
          byteSize: byteSize,
          sha256: sha256,
          expiresInMs: expiresInMs,
          localDeviceId: _identityManager!.deviceId,
          contentBase64: contentBase64,
        );
        final offerPayload = offer.toJson();

        final trustedPeers = await _trustStore!.getPeersByState(
          TrustState.trusted,
        );
        final broadcastTo = <String>[];
        for (final peer in trustedPeers) {
          try {
            await _ensureTrustedSessionForPeer(peer.deviceId);
            await _sessionManager!.sendMessage(peer.deviceId, {
              'rift': '0.1-draft',
              'type': 'clipboard.offer',
              'id': const Uuid().v4(),
              'messageId': const Uuid().v4(),
              'sourceDeviceId': _identityManager!.deviceId,
              'destinationDeviceId': peer.deviceId,
              'payload': offerPayload,
            });
            broadcastTo.add(peer.deviceId);
          } catch (e) {
            RiftLog.warn(
              '[Clipboard] Could not send offer to ${peer.deviceId}: $e',
            );
          }
        }
        return {
          'offerId': offerId,
          'expiresInMs': expiresInMs,
          'broadcastTo': broadcastTo,
        };

      case 'rift.notifyLocalNotificationEvent':
        return _handleLocalNotificationSyncEvent(params);

      case 'rift.notifyLocalMediaPlaybackEvent':
        return _handleLocalMediaPlaybackEvent(params);

      case 'rift.listNotifications':
        return _listNotificationSyncState();

      case 'rift.listMediaPlayback':
        return _listMediaPlaybackState();

      case 'rift.getMediaPlayback':
        return _getMediaPlaybackState(params);

      case 'rift.performMediaPlaybackAction':
        return _performMediaPlaybackAction(params);

      case 'rift.reportLocalMediaPlaybackActionHandled':
        return _reportLocalMediaPlaybackActionHandled(params);

      case 'rift.updateNotificationSyncPolicy':
        final enabled = params['enabled'];
        if (enabled is! bool) {
          throw ArgumentError.value(enabled, 'enabled', 'must be a boolean');
        }
        final blacklist = _normalizeNotificationSyncBlacklist(
          params['blacklistedPackages'],
        );
        return _updateNotificationSyncPolicy(
          enabled: enabled,
          blacklistedPackages: blacklist,
        );

      case 'rift.listClipboardOffers':
        _requireTransportServices();
        // Return both local and incoming offers to show unified history
        final allOffers = _clipboardEngine!.getAllOffers().map((o) {
          final expiresAt = _clipboardEngine!.getOfferExpiresAt(o.offerId);
          return {
            'offerId': o.offerId,
            'sourceDeviceId': o.sourceDeviceId,
            'contentType': o.contentType,
            'byteSize': o.byteSize,
            'sha256': o.sha256,
            'expiresAt': expiresAt?.toIso8601String(),
          };
        }).toList();
        return {'offers': allOffers};

      case 'rift.offerFile':
        _requireTransportServices();
        final targetDeviceId = RpcUtils.requireStringParam(
          params,
          'targetDeviceId',
        );
        final localPath = RpcUtils.requireStringParam(params, 'localPath');
        await _ensureTrustedSessionForPeer(targetDeviceId);
        final result = await _fileTransferService!.offerFile(
          targetDeviceId: targetDeviceId,
          localPath: localPath,
          fileName: params['fileName'] as String?,
          mediaType: params['mediaType'] as String?,
        );
        return result.toJson();

      case 'rift.listIncomingFileOffers':
        _requireTransportServices();
        return {'offers': _fileTransferService!.listIncomingFileOffers()};

      case 'rift.acceptFileOffer':
        _requireTransportServices();
        final transferId = RpcUtils.requireStringParam(params, 'transferId');
        final destinationPath = RpcUtils.requireStringParam(
          params,
          'destinationPath',
        );
        final offer = _fileTransferService!
            .listIncomingFileOffers()
            .cast<Map<String, dynamic>>()
            .firstWhere(
              (candidate) => candidate['transferId'] == transferId,
              orElse: () => <String, dynamic>{},
            );
        final sourceDeviceId = offer['sourceDeviceId'] as String?;
        if (sourceDeviceId != null && sourceDeviceId.isNotEmpty) {
          await _ensureTrustedSessionForPeer(sourceDeviceId);
        }
        final result = await _fileTransferService!.acceptFileOffer(
          transferId: transferId,
          destinationPath: destinationPath,
          overwrite: params['overwrite'] as bool? ?? false,
        );
        return result.toJson();

      case 'rift.rejectFileOffer':
        _requireTransportServices();
        final transferId = RpcUtils.requireStringParam(params, 'transferId');
        final failureReason = RpcUtils.requireStringParam(
          params,
          'failureReason',
        );
        final offer = _fileTransferService!
            .listIncomingFileOffers()
            .cast<Map<String, dynamic>>()
            .firstWhere(
              (candidate) => candidate['transferId'] == transferId,
              orElse: () => <String, dynamic>{},
            );
        final sourceDeviceId = offer['sourceDeviceId'] as String?;
        if (sourceDeviceId != null && sourceDeviceId.isNotEmpty) {
          await _ensureTrustedSessionForPeer(sourceDeviceId);
        }
        final result = await _fileTransferService!.rejectFileOffer(
          transferId: transferId,
          failureReason: failureReason,
          message: params['message'] as String?,
        );
        return result.toJson();

      case 'rift.listFileTransfers':
        _requireTransportServices();
        return {'transfers': _fileTransferService!.listFileTransfers()};

      case 'rift.fetchClipboardContent':
        _requireTransportServices();
        // Spec: only needs offerId - daemon looks up the source peer internally
        final offerId = RpcUtils.requireStringParam(params, 'offerId');

        final offer = _clipboardEngine!.getOffer(offerId);
        if (offer == null) {
          throw const RiftException(-32002, 'Offer expired or not found');
        }

        final operationId = const Uuid().v4();
        _operationManager!.createOperation(
          operationId: operationId,
          operationType: 'clipboard.fetch',
          sourceDeviceId: _identityManager!.deviceId,
          destinationDeviceId: offer.sourceDeviceId,
        );
        _operationManager!.transitionOperation(
          operationId,
          OperationState.pending,
        );

        final fetchWait = _awaitClipboardFetchResult(offerId, operationId);
        try {
          await _ensureTrustedSessionForPeer(offer.sourceDeviceId);
          await _clipboardHandler!.sendFetchRequest(
            offer.sourceDeviceId,
            offerId,
          );
          _operationManager!.transitionOperation(
            operationId,
            OperationState.dispatched,
          );
        } catch (e) {
          final failureReason = _classifyClipboardFetchFailureReason(e);
          await fetchWait.fail(
            failureReason,
            _errorCodeForFailureReason(failureReason),
            e.toString(),
          );
          rethrow;
        }

        try {
          final fetchResult = await fetchWait.future;
          return {
            'offerId': fetchResult.offerId,
            'contentBase64': fetchResult.contentBase64,
            'byteSize': fetchResult.byteSize,
            'sha256': fetchResult.sha256,
            'verified': true, // handler already verified hash before emitting
          };
        } on RiftException {
          rethrow;
        } catch (e) {
          throw RiftException(-32603, e.toString());
        }
      case 'rift.queryEventLog':
        return queryEventLog(
          eventTypes: (params['eventTypes'] as List?)?.cast<String>(),
          severities: (params['severities'] as List?)?.cast<String>(),
          peerDeviceId: params['peerDeviceId'] as String?,
          since: params['since'] as String?,
          limit: (params['limit'] as int?) ?? 100,
          offset: (params['offset'] as int?) ?? 0,
        );
      case 'rift.listOperations':
        return listOperations(
          limit: (params['limit'] as int?) ?? 50,
          offset: (params['offset'] as int?) ?? 0,
        );
      case 'rift.getOperation':
        return getOperation(RpcUtils.requireStringParam(params, 'operationId'));
      case 'rift.cancelFileTransfer':
        return _fileTransferService!.cancelTransfer(
          RpcUtils.requireStringParam(params, 'transferId'),
        );
      case 'rift.startDiscovery':
        _requireDiscoveryServices();
        await _discoveryService!.startDiscovery();
        _isDiscovering = true;
        return {'started': true};
      case 'rift.stopDiscovery':
        _requireDiscoveryServices();
        await _discoveryService!.stopDiscovery();
        _discoveredPeers.clear();
        _isDiscovering = false;
        return {'stopped': true};
      case 'rift.startPairing':
        _requireTransportServices();
        final requestedPeerId = RpcUtils.requireStringParam(params, 'deviceId');
        final pendingStartPairing = _pendingStartPairings[requestedPeerId];
        if (pendingStartPairing != null) {
          RiftLog.debug(
            '[Pairing] Joining pending startPairing for peerDeviceId=$requestedPeerId',
          );
          return await pendingStartPairing;
        }

        final future = _startPairingRpc(requestedPeerId, method, params);
        _pendingStartPairings[requestedPeerId] = future;
        try {
          return await future;
        } finally {
          if (identical(_pendingStartPairings[requestedPeerId], future)) {
            _pendingStartPairings.remove(requestedPeerId);
          }
        }
      case 'rift.startPairingByEndpoint':
        _requireTransportServices();
        final address = RpcUtils.requireStringParam(params, 'address');
        final port = RpcUtils.requireIntParam(params, 'port');
        if (port <= 0 || port > 65535) {
          throw const RiftException(-32602, 'port must be between 1 and 65535');
        }
        final endpointKey = '$address:$port';
        final pendingEndpointPairing =
            _pendingEndpointStartPairings[endpointKey];
        if (pendingEndpointPairing != null) {
          RiftLog.debug(
            '[Pairing] Joining pending startPairingByEndpoint for endpoint=$endpointKey',
          );
          return await pendingEndpointPairing;
        }

        final endpointFuture = _startPairingByEndpointRpc(
          address,
          port,
          method,
          params,
        );
        _pendingEndpointStartPairings[endpointKey] = endpointFuture;
        try {
          return await endpointFuture;
        } finally {
          if (identical(
            _pendingEndpointStartPairings[endpointKey],
            endpointFuture,
          )) {
            _pendingEndpointStartPairings.remove(endpointKey);
          }
        }
      case 'rift.pingEndpoint':
        _requireTransportServices();
        final address = RpcUtils.requireStringParam(params, 'address');
        final port = RpcUtils.requireIntParam(params, 'port');
        if (port <= 0 || port > 65535) {
          throw const RiftException(-32602, 'port must be between 1 and 65535');
        }
        unawaited(_pingEndpointRpc(address, port));
        return {'pinged': true};
      case 'rift.approvePairing':
        _requireTransportServices();
        await _pairingManager!.handleIpcCommand({
          'method': method,
          'params': params,
        });
        return {
          'trustedDeviceId': RpcUtils.requireStringParam(params, 'deviceId'),
          'persistedAt': DateTime.now().toUtc().toIso8601String(),
        };
      case 'rift.rejectPairing':
        _requireTransportServices();
        await _pairingManager!.handleIpcCommand({
          'method': method,
          'params': params,
        });
        return {'rejected': true};
      case 'rift.revokeTrust':
        _requireTransportServices();
        RpcUtils.requireStringParam(params, 'deviceId');
        RpcUtils.requireStringParam(params, 'reason');
        await _pairingManager!.handleIpcCommand({
          'method': 'rift.unpair',
          'params': {
            'deviceId': params['deviceId'],
            'reason': params['reason'],
          },
        });
        return {
          'removed': true,
          'removedAt': DateTime.now().toUtc().toIso8601String(),
          'revoked': true,
          'revokedAt': DateTime.now().toUtc().toIso8601String(),
        };
      case 'rift.unblockPeer':
        _requireTransportServices();
        await _pairingManager!.handleIpcCommand({
          'method': method,
          'params': params,
        });
        return {'unblocked': true};
      case 'rift.resetRevokedPeer':
        _requireTransportServices();
        await _pairingManager!.handleIpcCommand({
          'method': method,
          'params': params,
        });
        return {'reset': true};
      case 'rift.connect':
        _requireTransportServices();
        final host = RpcUtils.requireStringParam(params, 'host');
        final port = params['port'];
        if (port is! int) {
          throw ArgumentError.value(port, 'port', 'must be an integer');
        }
        final peerDeviceId = params['peerDeviceId'] as String?;
        final resolvedPeerDeviceId = await _transport!.connectTo(
          host,
          port,
          expectedDeviceId: peerDeviceId,
        );
        await _sessionManager!.sendSessionHello(resolvedPeerDeviceId);
        return {'connected': true, 'deviceId': resolvedPeerDeviceId};
      case 'rift.stop':
        await stop();
        return {'stopped': true};
      default:
        throw UnsupportedError('Method not found: $method');
    }
  }

  RiftException _mapClipboardFetchReject(ClipboardFetchReject reject) {
    switch (reject.failureReason) {
      case 'OfferExpired':
        return RiftException(-32002, 'Fetch rejected: ${reject.failureReason}');
      case 'HashMismatch':
        return RiftException(-32006, 'Fetch rejected: ${reject.failureReason}');
      case 'CapabilityUnavailable':
        return RiftException(-32003, 'Fetch rejected: ${reject.failureReason}');
      case 'Unauthorized':
        return RiftException(-32004, 'Fetch rejected: ${reject.failureReason}');
      case 'PayloadTooLarge':
        return RiftException(-32007, 'Fetch rejected: ${reject.failureReason}');
      case 'Timeout':
        return RiftException(-32011, 'Fetch rejected: ${reject.failureReason}');
      case 'PeerUnreachable':
      case 'ConnectionLost':
        return RiftException(-32000, 'Fetch rejected: ${reject.failureReason}');
      default:
        return RiftException(-32603, 'Fetch rejected: ${reject.failureReason}');
    }
  }

  _OperationFetchWaiter _awaitClipboardFetchResult(
    String offerId,
    String operationId,
  ) {
    final completer = Completer<ClipboardFetchResponse>();
    completer.future
        .ignore(); // Prevent unhandled exception if cancelled before await
    late final StreamSubscription<ClipboardFetchResponse> responseSub;
    late final StreamSubscription<ClipboardFetchReject> rejectSub;
    Timer? timeoutTimer;
    var isSettled = false;

    void completeResponse(ClipboardFetchResponse response) {
      completer.complete(response);
    }

    void completeFailure(
      RiftException error, {
      String? failureReason,
      required bool expired,
    }) {
      _operationManager!.transitionOperation(
        operationId,
        expired ? OperationState.expired : OperationState.failed,
        failureReason: failureReason,
      );
      completer.completeError(error);
    }

    Future<void> settle({
      ClipboardFetchResponse? response,
      RiftException? error,
      String? failureReason,
      required bool expired,
    }) async {
      if (isSettled) return;
      isSettled = true;
      timeoutTimer?.cancel();
      await responseSub.cancel();
      await rejectSub.cancel();
      if (error != null) {
        completeFailure(error, failureReason: failureReason, expired: expired);
        return;
      }

      if (response != null) {
        completeResponse(response);
      }
    }

    responseSub = _clipboardHandler!.onFetchResponse.listen((response) {
      if (response.offerId != offerId) return;
      try {
        _operationManager!.transitionOperation(
          operationId,
          OperationState.active,
        );
      } on RiftInvalidTransitionException {
        // Duplicate network delivery should not crash the daemon.
      }
      _operationManager!.transitionOperation(operationId, OperationState.done);
      unawaited(settle(response: response, expired: false));
    });

    rejectSub = _clipboardHandler!.onFetchReject.listen((reject) {
      if (reject.offerId != offerId) return;
      try {
        _operationManager!.transitionOperation(
          operationId,
          OperationState.active,
        );
      } on RiftInvalidTransitionException {
        // Duplicate network delivery should not crash the daemon.
      }
      unawaited(
        settle(
          error: _mapClipboardFetchReject(reject),
          failureReason: reject.failureReason,
          expired: reject.failureReason == 'Timeout',
        ),
      );
    });

    timeoutTimer = Timer(
      const Duration(seconds: _clipboardFetchTimeoutSeconds),
      () => unawaited(
        settle(
          error: const RiftException(-32011, 'Clipboard fetch timed out'),
          failureReason: 'Timeout',
          expired: true,
        ),
      ),
    );

    return _OperationFetchWaiter(
      future: completer.future,
      fail: (failureReason, errorCode, message) => settle(
        error: RiftException(errorCode, message),
        failureReason: failureReason,
        expired: false,
      ),
    );
  }

  String _classifyClipboardFetchFailureReason(Object error) {
    if (error is RiftException) {
      switch (error.code) {
        case -32002:
          return 'OfferExpired';
        case -32003:
          return 'CapabilityUnavailable';
        case -32004:
          return 'Unauthorized';
        case -32006:
          return 'HashMismatch';
        case -32007:
          return 'PayloadTooLarge';
        case -32011:
          return 'Timeout';
        case -32000:
          return 'PeerUnreachable';
      }
    }

    final message = error.toString().toLowerCase();
    if (message.contains('capabilityunavailable')) {
      return 'CapabilityUnavailable';
    }
    if (message.contains('unauthorized')) {
      return 'Unauthorized';
    }
    if (message.contains('timeout')) {
      return 'Timeout';
    }

    return 'PeerUnreachable';
  }

  int _errorCodeForFailureReason(String failureReason) {
    switch (failureReason) {
      case 'OfferExpired':
        return -32002;
      case 'CapabilityUnavailable':
        return -32003;
      case 'Unauthorized':
        return -32004;
      case 'HashMismatch':
        return -32006;
      case 'PayloadTooLarge':
        return -32007;
      case 'Timeout':
        return -32011;
      case 'PeerUnreachable':
      case 'ConnectionLost':
        return -32000;
      default:
        return -32603;
    }
  }

  void _requireTransportServices() {
    if (_transport == null ||
        _sessionManager == null ||
        _pairingManager == null) {
      throw const RiftException(
        -32603,
        'Transport-dependent services are not initialized',
      );
    }
  }

  void _forwardIpcEvent(Map<String, dynamic> event) {
    onIpcEvent?.call(event);

    final method = event['method']?.toString();
    final params = event['params'];
    if (params is! Map<String, dynamic>) {
      return;
    }

    switch (method) {
      case 'rift.onPairingComplete':
        unawaited(
          _recordSecurityEvent(
            eventType: 'pairing.completed',
            severity: 'info',
            peerDeviceId: params['deviceId']?.toString(),
            outcome: 'success',
          ),
        );
        break;
      case 'rift.onTrustChanged':
        final newState = params['newState']?.toString();
        final previousState = params['previousState']?.toString();
        final reason = params['reason']?.toString();
        if (newState == 'removed') {
          unawaited(
            _recordSecurityEvent(
              eventType: 'trust.removed',
              severity: 'warning',
              peerDeviceId: params['deviceId']?.toString(),
              outcome: 'success',
              failureReason: reason,
            ),
          );
        } else if (newState != null && previousState != null) {
          unawaited(
            _recordSecurityEvent(
              eventType: 'trust.transitioned',
              severity: 'info',
              peerDeviceId: params['deviceId']?.toString(),
              outcome: 'success',
              details: {'previousState': previousState, 'newState': newState},
            ),
          );
        }
        break;
    }
  }

  Future<void> _recordSecurityEvent({
    required String eventType,
    required String severity,
    required String outcome,
    String? peerDeviceId,
    String? failureReason,
    Map<String, dynamic>? details,
  }) async {
    final event = SecurityEventRecord(
      eventId: const Uuid().v4(),
      eventType: eventType,
      severity: severity,
      localDeviceId: _identityManager?.deviceId ?? '',
      timestamp: DateTime.now().toUtc(),
      outcome: outcome,
      peerDeviceId: peerDeviceId,
      failureReason: failureReason,
      details: details,
    );
    await _trustStore?.appendSecurityEvent(event);
    onIpcEvent?.call({
      'jsonrpc': '2.0',
      'method': 'rift.onSecurityEvent',
      'params': event.toJson(),
    });
  }

  void _requireDiscoveryServices() {
    if (_discoveryService == null) {
      throw const RiftException(
        -32603,
        'Discovery services are not initialized',
      );
    }
  }

  void trackDiscoveredPeer(DiscoveredPeer peer) {
    final deviceId = peer.deviceIdHint;
    if (deviceId == null) return;

    final existing = _discoveredPeers[deviceId];
    final peersByInstanceId = <String, DiscoveredPeer>{
      if (existing != null) ...existing.peersByInstanceId,
      peer.instanceId: peer,
    };
    _discoveredPeers[deviceId] = _DiscoveredPeerRecord(
      deviceId: deviceId,
      peersByInstanceId: peersByInstanceId,
    );
  }

  void untrackDiscoveredPeer(DiscoveredPeer peer) {
    final deviceId = peer.deviceIdHint;
    if (deviceId == null) return;

    final existing = _discoveredPeers[deviceId];
    if (existing == null) return;

    final peersByInstanceId = Map<String, DiscoveredPeer>.from(
      existing.peersByInstanceId,
    )..remove(peer.instanceId);

    if (peersByInstanceId.isEmpty) {
      _discoveredPeers.remove(deviceId);
      return;
    }

    _discoveredPeers[deviceId] = _DiscoveredPeerRecord(
      deviceId: deviceId,
      peersByInstanceId: peersByInstanceId,
    );
  }

  void replaceExternalDiscoveredPeers(
    Iterable<Map<String, dynamic>> rawPeers, {
    required bool isDiscovering,
  }) {
    final previousPeerIds = _discoveredPeers.keys.toSet();
    final addedPeerIds = <String>{};
    final refreshedPeerIds = <String>{};
    _discoveredPeers.clear();
    for (final rawPeer in rawPeers) {
      final instanceId = rawPeer['instanceId'];
      final minVersion = rawPeer['minVersion'];
      final maxVersion = rawPeer['maxVersion'];
      if (instanceId is! String ||
          minVersion is! String ||
          maxVersion is! String) {
        continue;
      }

      final deviceIdHint = rawPeer['deviceIdHint'] as String?;
      final fingerprintPrefix = rawPeer['fingerprintPrefix'] as String?;
      final observedEndpoints = rawPeer['observedEndpoints'] as List?;

      final expandedPeers = <DiscoveredPeer>[];
      if (observedEndpoints != null && observedEndpoints.isNotEmpty) {
        for (var i = 0; i < observedEndpoints.length; i += 1) {
          final endpoint = observedEndpoints[i];
          if (endpoint is! Map) continue;
          final address = endpoint['address'];
          final port = endpoint['port'];
          if (address is! String || port is! int) {
            continue;
          }

          expandedPeers.add(
            DiscoveredPeer(
              instanceId: i == 0 ? instanceId : '$instanceId#$i',
              address: address,
              port: port,
              minVersion: minVersion,
              maxVersion: maxVersion,
              deviceIdHint: deviceIdHint,
              fingerprintPrefix: fingerprintPrefix,
            ),
          );
        }
      }

      if (expandedPeers.isEmpty) {
        final address = rawPeer['address'];
        final port = rawPeer['port'];
        if (address is! String || port is! int) {
          continue;
        }

        expandedPeers.add(
          DiscoveredPeer(
            instanceId: instanceId,
            address: address,
            port: port,
            minVersion: minVersion,
            maxVersion: maxVersion,
            deviceIdHint: deviceIdHint,
            fingerprintPrefix: fingerprintPrefix,
          ),
        );
      }

      for (final peer in expandedPeers) {
        trackDiscoveredPeer(peer);
        final peerId = peer.deviceIdHint;
        if (peerId != null) {
          if (!previousPeerIds.contains(peerId)) {
            addedPeerIds.add(peerId);
          }
          refreshedPeerIds.add(peerId);
        }
      }
    }
    _isDiscovering = isDiscovering;

    // Android inbound mTLS currently cannot provisionally accept arbitrary
    // self-signed client certificates during server-side TLS handshake
    // (BoringSSL rejects them before Dart session bootstrap can inspect the
    // peer cert). To keep the peer protocol unchanged while preserving
    // cross-platform pairing, the Android daemon prefers proactively opening
    // outbound sessions to discovered peers and then reuses those authenticated
    // sessions when the local user initiates pairing later.
    _lastDiscoveryPrefetchAttempts.removeWhere(
      (peerId, _) => !refreshedPeerIds.contains(peerId),
    );
    final now = DateTime.now();
    for (final peerId in refreshedPeerIds) {
      final lastAttempt = _lastDiscoveryPrefetchAttempts[peerId];
      if (!addedPeerIds.contains(peerId) &&
          lastAttempt != null &&
          now.difference(lastAttempt) < _discoveryPrefetchRetryDelay) {
        continue;
      }
      _lastDiscoveryPrefetchAttempts[peerId] = now;
      unawaited(prefetchSessionForDiscoveredPeer(peerId));
    }
  }

  static Map<String, dynamic> jsonRpcResult(
    Object? id,
    Map<String, dynamic> result,
  ) {
    return {'jsonrpc': '2.0', 'id': id, 'result': result};
  }

  static Map<String, dynamic> jsonRpcError(
    Object? id,
    int code,
    String message,
  ) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  static String _formatFingerprint(Uint8List hashBytes) {
    final base32Str = Base32Utils.encode(
      hashBytes,
    ).toUpperCase().replaceAll('=', '');
    final truncated = base32Str.substring(0, 32);
    return truncated
        .replaceAllMapped(RegExp(r'.{4}'), (m) => '${m.group(0)}-')
        .substring(0, 39);
  }

  static String _deriveFingerprint(Uint8List certDer) {
    final peerPublicKey = RiftCertDecoder.extractEd25519PublicKeyFromDer(
      certDer,
    );
    final hash = sha256.convert(peerPublicKey).bytes;
    return _formatFingerprint(Uint8List.fromList(hash));
  }

  static String _fingerprintPrefix(Uint8List hashBytes) {
    final base32Str = Base32Utils.encode(
      hashBytes,
    ).toUpperCase().replaceAll('=', '');
    return base32Str.substring(0, 8);
  }

  Future<void> _ensurePeerRecordForPairing(String peerDeviceId) async {
    final trustStore = _trustStore;
    final transport = _transport;
    if (trustStore == null || transport == null) {
      throw const RiftIdentityNotInitializedException(
        'Daemon services not initialized',
      );
    }

    final existing = await trustStore.getPeer(peerDeviceId);
    if (existing != null) {
      return;
    }

    final peerCertDer = transport.getPeerCert(peerDeviceId);
    if (peerCertDer == null) {
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }

    await trustStore.upsertPeer(
      PeerRecord(
        deviceId: peerDeviceId,
        certDer: Uint8List.fromList(peerCertDer),
        state: TrustState.discovered,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> _persistTrustedEndpointIfAvailable(
    String peerDeviceId, {
    required String source,
  }) async {
    final trustStore = _trustStore;
    final transport = _transport;
    if (trustStore == null || transport == null) {
      return;
    }

    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null || record.state != TrustState.trusted) {
      return;
    }

    final now = DateTime.now().toUtc();
    final nextEndpoint = _resolveTrustedEndpointForPersistence(
      peerDeviceId: peerDeviceId,
      record: record,
      source: source,
      persistedAt: now,
    );
    if (nextEndpoint == null) {
      RiftLog.debug(
        '[Endpoint] Skipping persistence for peerDeviceId=$peerDeviceId '
        'because no stable listener port is known.',
      );
      return;
    }

    final mergedEndpoints = <TrustedPeerEndpoint>[
      nextEndpoint,
      ...record.trustedEndpoints.where(
        (existing) =>
            existing.address != nextEndpoint.address ||
            existing.port != nextEndpoint.port,
      ),
    ];

    await trustStore.upsertPeer(
      PeerRecord(
        deviceId: record.deviceId,
        displayName: record.displayName,
        platform: record.platform,
        certDer: record.certDer,
        state: record.state,
        pairedAt: record.pairedAt,
        updatedAt: now,
        lastSeenAt: record.lastSeenAt,
        trustedEndpoints: mergedEndpoints.take(4).toList(growable: false),
      ),
    );

    RiftLog.info(
      '[Endpoint] Persisted trusted endpoint for peerDeviceId=$peerDeviceId '
      'address=${nextEndpoint.address}:${nextEndpoint.port} source=$source',
    );
  }

  TrustedPeerEndpoint? _resolveTrustedEndpointForPersistence({
    required String peerDeviceId,
    required PeerRecord record,
    required String source,
    required DateTime persistedAt,
  }) {
    final hintedEndpoint = _pendingTrustedEndpointHints.remove(peerDeviceId);
    if (hintedEndpoint != null) {
      return TrustedPeerEndpoint(
        address: hintedEndpoint.address,
        port: hintedEndpoint.port,
        source: source,
        addressFamily: hintedEndpoint.addressFamily,
        lastSuccessAt: persistedAt,
      );
    }

    final primaryPeer = _discoveredPeers[peerDeviceId]?.primaryPeer;
    if (primaryPeer != null) {
      return TrustedPeerEndpoint(
        address: primaryPeer.address,
        port: primaryPeer.port,
        source: source,
        addressFamily: InternetAddress.tryParse(primaryPeer.address)?.type.name,
        lastSuccessAt: persistedAt,
      );
    }

    final activeEndpoint = _transport?.getPeerSocketEndpoint(peerDeviceId);
    if (activeEndpoint != null && record.trustedEndpoints.isNotEmpty) {
      final existingEndpoint = record.trustedEndpoints.first;
      final portToUse = activeEndpoint.isServer
          ? existingEndpoint.port
          : activeEndpoint.port;
      return TrustedPeerEndpoint(
        address: activeEndpoint.address,
        port: portToUse,
        source: source,
        addressFamily:
            InternetAddress.tryParse(activeEndpoint.address)?.type.name ??
            existingEndpoint.addressFamily,
        lastSuccessAt: persistedAt,
      );
    }

    return null;
  }

  @visibleForTesting
  static bool hasActivePairingSession(
    SessionContext? context,
    PeerSocketEndpoint? endpoint,
  ) => context != null && endpoint != null;

  Future<String> _ensureSessionForPairing(String peerDeviceId) async {
    final sessionManager = _sessionManager;
    final transport = _transport;
    if (sessionManager == null || transport == null) {
      throw const RiftIdentityNotInitializedException(
        'Daemon services not initialized',
      );
    }

    final record = await _trustStore?.getPeer(peerDeviceId);
    final expectedTrustState = record?.state ?? TrustState.discovered;
    final ctx = sessionManager.getContext(peerDeviceId);
    final activeEndpoint = transport.getPeerSocketEndpoint(peerDeviceId);
    if (ctx != null && ctx.trustState != expectedTrustState) {
      RiftLog.warn(
        '[Pairing] Session context for peerDeviceId=$peerDeviceId had stale '
        'trust state ${ctx.trustState.toJson()} (expected ${expectedTrustState.toJson()}); '
        'restarting session prefetch.',
      );
      sessionManager.disconnectPeer(peerDeviceId);
    } else if (ctx != null && !hasActivePairingSession(ctx, activeEndpoint)) {
      RiftLog.warn(
        '[Pairing] Session context for peerDeviceId=$peerDeviceId had no active '
        'transport socket. Restarting session prefetch.',
      );
      sessionManager.disconnectPeer(peerDeviceId);
    } else if (ctx != null &&
        ctx.handshakeState == HandshakeState.established) {
      return peerDeviceId;
    } else if (ctx != null &&
        ctx.handshakeState == HandshakeState.handshaking) {
      RiftLog.debug(
        '[Pairing] Reusing in-flight handshake for peerDeviceId=$peerDeviceId',
      );
      await sessionManager.waitForSessionEstablished(peerDeviceId);
      return peerDeviceId;
    }

    final pending = _pendingSessionEnsures[peerDeviceId];
    if (pending != null) {
      RiftLog.debug(
        '[Pairing] Joining pending ensureSession for peerDeviceId=$peerDeviceId',
      );
      return pending;
    }

    final future = _openSessionForPairing(peerDeviceId);
    _pendingSessionEnsures[peerDeviceId] = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingSessionEnsures[peerDeviceId], future)) {
        _pendingSessionEnsures.remove(peerDeviceId);
      }
    }
  }

  void _scheduleTrustedReconnect(String peerDeviceId) {
    if (_isStopping || _trustedReconnectTimers.containsKey(peerDeviceId)) {
      return;
    }

    final attempt = _trustedReconnectAttempts[peerDeviceId] ?? 0;
    final delay =
        _trustedReconnectDelays[attempt
            .clamp(0, _trustedReconnectDelays.length - 1)
            .toInt()];
    _trustedReconnectTimers[peerDeviceId] = Timer(delay, () {
      _trustedReconnectTimers.remove(peerDeviceId);
      unawaited(_attemptTrustedReconnect(peerDeviceId, attempt));
    });
  }

  Future<void> _attemptTrustedReconnect(
    String peerDeviceId,
    int attempt,
  ) async {
    if (_isStopping) {
      return;
    }

    final record = await _trustStore?.getPeer(peerDeviceId);
    if (record == null || record.state != TrustState.trusted) {
      _trustedReconnectAttempts.remove(peerDeviceId);
      return;
    }

    try {
      await _ensureTrustedSessionForPeer(peerDeviceId);
      _trustedReconnectAttempts.remove(peerDeviceId);
    } catch (error) {
      if (_isStopping) {
        return;
      }
      _trustedReconnectAttempts[peerDeviceId] = attempt + 1;
      RiftLog.debug(
        '[Reconnect] Scheduled trusted reconnect failed for '
        'peerDeviceId=$peerDeviceId attempt=${attempt + 1} error=$error',
      );
      _scheduleTrustedReconnect(peerDeviceId);
    }
  }

  Future<String> _ensureTrustedSessionForPeer(String peerDeviceId) async {
    final trustStore = _trustStore;
    final sessionManager = _sessionManager;
    final transport = _transport;
    if (trustStore == null || sessionManager == null) {
      throw const RiftIdentityNotInitializedException(
        'Daemon services not initialized',
      );
    }

    final record = await trustStore.getPeer(peerDeviceId);
    if (record == null || record.state != TrustState.trusted) {
      throw RiftException(
        -32004,
        'Peer $peerDeviceId is not trusted for protected reconnect',
      );
    }

    final ctx = sessionManager.getContext(peerDeviceId);
    if (ctx != null && ctx.handshakeState == HandshakeState.established) {
      if (transport?.getPeerSocketEndpoint(peerDeviceId) == null) {
        RiftLog.warn(
          '[Reconnect] Session context for peerDeviceId=$peerDeviceId was established '
          'but no active transport socket remained. Reconnecting.',
        );
        sessionManager.disconnectPeer(peerDeviceId);
      } else {
        return peerDeviceId;
      }
    }
    if (ctx != null && ctx.handshakeState == HandshakeState.handshaking) {
      if (transport?.getPeerSocketEndpoint(peerDeviceId) == null) {
        RiftLog.warn(
          '[Reconnect] In-flight handshake for peerDeviceId=$peerDeviceId had no active '
          'transport socket. Restarting reconnect.',
        );
        sessionManager.disconnectPeer(peerDeviceId);
      } else {
        await sessionManager.waitForSessionEstablished(peerDeviceId);
        return peerDeviceId;
      }
    }

    return joinSingleFlightOperation(
      key: peerDeviceId,
      pendingOperations: _pendingTrustedReconnects,
      startOperation: () {
        RiftLog.debug(
          '[Reconnect] Starting trusted reconnect for peerDeviceId=$peerDeviceId',
        );
        return _reconnectTrustedPeer(peerDeviceId, record);
      },
    );
  }

  Future<String> _reconnectTrustedPeer(
    String peerDeviceId,
    PeerRecord record,
  ) async {
    final sessionManager = _sessionManager!;
    final transport = _transport!;
    Object? persistedEndpointFailure;
    if (record.trustedEndpoints.isNotEmpty) {
      try {
        return await reconnectTrustedPeerViaEndpoints(
          peerDeviceId: peerDeviceId,
          trustedEndpoints: record.trustedEndpoints,
          transport: transport,
          getContext: sessionManager.getContext,
          sendSessionHello: sessionManager.sendSessionHello,
          waitForSessionEstablished: sessionManager.waitForSessionEstablished,
          persistTrustedEndpoint: (resolvedPeerDeviceId, source) {
            return _persistTrustedEndpointIfAvailable(
              resolvedPeerDeviceId,
              source: source,
            );
          },
          timeout: _trustedReconnectTimeout,
        );
      } catch (error) {
        persistedEndpointFailure = error;
        RiftLog.warn(
          '[Reconnect] Persisted endpoint reconnect failed for '
          'peerDeviceId=$peerDeviceId. '
          'Trying discovery fallback if available. error=$error',
        );
      }
    }

    final discoveredPeerRecord = _discoveredPeers[peerDeviceId];
    if (discoveredPeerRecord != null &&
        discoveredPeerRecord.orderedPeers.isNotEmpty) {
      final resolvedPeerDeviceId = await _openSessionForPairing(peerDeviceId);
      await _persistTrustedEndpointIfAvailable(
        resolvedPeerDeviceId,
        source: 'discovery-reconnect',
      );
      return resolvedPeerDeviceId;
    }

    if (persistedEndpointFailure != null) {
      throw persistedEndpointFailure;
    }

    throw RiftException(
      -32000,
      'Trusted peer $peerDeviceId has no persisted endpoint for reconnect '
      'and is not currently discoverable.',
    );
  }

  Future<String> _openSessionForPairing(String peerDeviceId) async {
    final discoveredPeerRecord = _discoveredPeers[peerDeviceId];
    final hasDiscovered =
        discoveredPeerRecord != null &&
        discoveredPeerRecord.orderedPeers.isNotEmpty;

    if (hasDiscovered) {
      final failures = <({DiscoveredPeer peer, Object error})>[];
      for (final discoveredPeer in discoveredPeerRecord.orderedPeers) {
        RiftLog.debug(
          '[Pairing] Opening session for peerDeviceId=$peerDeviceId '
          'using address=${discoveredPeer.address}:${discoveredPeer.port} '
          'deviceIdHint=${discoveredPeer.deviceIdHint ?? "<none>"} '
          'instanceId=${discoveredPeer.instanceId}',
        );

        try {
          return await _connectEndpointForPairing(
            discoveredPeer.address,
            discoveredPeer.port,
            expectedPeerDeviceId: discoveredPeer.deviceIdHint == peerDeviceId
                ? peerDeviceId
                : null,
            duplicateRacePeerDeviceId: peerDeviceId,
            duplicateRaceLogContext:
                'peerDeviceId=$peerDeviceId '
                'address=${discoveredPeer.address}:${discoveredPeer.port} '
                'instanceId=${discoveredPeer.instanceId}',
          );
        } catch (e) {
          failures.add((peer: discoveredPeer, error: e));
          final classification = _classifyPairingConnectFailure(e);
          RiftLog.warn(
            '[Pairing] Endpoint failed for peerDeviceId=$peerDeviceId '
            'address=${discoveredPeer.address}:${discoveredPeer.port} '
            'instanceId=${discoveredPeer.instanceId} '
            'classification=$classification '
            'detail=${_describePairingConnectFailure(e)} '
            'error=$e',
          );
        }
      }

      final failureSummary = _summarizePairingFailures(failures);
      RiftLog.warn(
        '[Pairing] All discovered endpoints failed for peerDeviceId=$peerDeviceId. '
        '$failureSummary',
      );
    }

    final trustStore = _trustStore;
    var hasPersisted = false;
    if (trustStore != null) {
      final record = await trustStore.getPeer(peerDeviceId);
      if (record != null && record.trustedEndpoints.isNotEmpty) {
        hasPersisted = true;
        RiftLog.debug(
          '[Pairing] Falling back to persisted endpoints for peerDeviceId=$peerDeviceId',
        );
        for (final endpoint in record.trustedEndpoints) {
          try {
            return await _connectEndpointForPairing(
              endpoint.address,
              endpoint.port,
              expectedPeerDeviceId: peerDeviceId,
              duplicateRacePeerDeviceId: peerDeviceId,
              duplicateRaceLogContext:
                  'peerDeviceId=$peerDeviceId '
                  'address=${endpoint.address}:${endpoint.port} '
                  'source=persisted',
            );
          } catch (e) {
            RiftLog.warn(
              '[Pairing] Persisted endpoint failed for peerDeviceId=$peerDeviceId '
              'address=${endpoint.address}:${endpoint.port} '
              'error=$e',
            );
          }
        }
        RiftLog.warn(
          '[Pairing] All persisted endpoints failed for peerDeviceId=$peerDeviceId.',
        );
      }
    }

    if (hasDiscovered || hasPersisted) {
      throw RiftException(
        -32603,
        'Failed to establish a secure session with $peerDeviceId across all endpoints.',
      );
    } else {
      throw const RiftNotFoundException(
        'Peer not found in discovery cache or trusted endpoints',
      );
    }
  }

  Future<String> _connectEndpointForPairing(
    String address,
    int port, {
    String? expectedPeerDeviceId,
    String? duplicateRacePeerDeviceId,
    required String duplicateRaceLogContext,
  }) async {
    final sessionManager = _sessionManager!;
    final transport = _transport!;
    var resolvedPeerDeviceId = expectedPeerDeviceId;

    Future<String> connectCurrentEndpoint() async {
      final connectedPeerDeviceId = await transport.connectTo(
        address,
        port,
        expectedDeviceId: expectedPeerDeviceId,
        forceFreshSession: expectedPeerDeviceId != null,
      );
      resolvedPeerDeviceId = connectedPeerDeviceId;

      if (sessionManager.getContext(connectedPeerDeviceId) == null) {
        await sessionManager.sendSessionHello(connectedPeerDeviceId);
      }
      await sessionManager.waitForSessionEstablished(connectedPeerDeviceId);
      return connectedPeerDeviceId;
    }

    try {
      return await connectCurrentEndpoint();
    } catch (e) {
      Object failure = e;
      final peerToReuse = duplicateRacePeerDeviceId ?? resolvedPeerDeviceId;
      if (_isLikelyDuplicateBootstrapRace(e) && peerToReuse != null) {
        RiftLog.info(
          '[Pairing] Duplicate bootstrap race detected for '
          '$duplicateRaceLogContext. Waiting briefly for an in-flight '
          'session before retrying.',
        );

        try {
          await sessionManager.waitForSessionEstablished(
            peerToReuse,
            timeout: const Duration(milliseconds: 300),
          );
          return peerToReuse;
        } catch (_) {
          try {
            return await connectCurrentEndpoint();
          } catch (retryError) {
            failure = retryError;
          }
        }
      }

      throw failure;
    }
  }

  Future<Map<String, dynamic>> _startPairingRpc(
    String requestedPeerId,
    String method,
    Map<String, dynamic> params,
  ) async {
    final peerDeviceId = await _ensureSessionForPairing(requestedPeerId);
    await _ensurePeerRecordForPairing(peerDeviceId);
    await _pairingManager!.handleIpcCommand({
      'method': method,
      'params': {...params, 'deviceId': peerDeviceId},
    });
    final record = await _trustStore?.getPeer(peerDeviceId);
    if (record == null) {
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }
    return {
      'deviceId': peerDeviceId,
      'fingerprint': _formatFingerprint(
        _identityManager!.getDeviceFingerprint(),
      ),
      'peerFingerprint': _deriveFingerprint(record.certDer),
      'expiresInMs':
          120000, // ipc.md §4.3: startPairing always returns 120 000 ms
    };
  }

  Future<Map<String, dynamic>> _startPairingByEndpointRpc(
    String address,
    int port,
    String method,
    Map<String, dynamic> params,
  ) async {
    final transport = _transport;
    final sessionManager = _sessionManager;
    if (transport == null || sessionManager == null) {
      throw const RiftIdentityNotInitializedException(
        'Daemon services not initialized',
      );
    }

    final resolvedPeerIdentity = await transport.connectTo(address, port);
    RiftLog.info(
      '[Pairing] Manual endpoint $address:$port resolved to '
      'peerDeviceId=$resolvedPeerIdentity. Resetting any existing session '
      'before starting pairing to avoid reusing a stale authenticated socket.',
    );
    sessionManager.disconnectPeer(resolvedPeerIdentity);

    final resolvedPeerDeviceId = await _connectEndpointForPairing(
      address,
      port,
      expectedPeerDeviceId: resolvedPeerIdentity,
      duplicateRacePeerDeviceId: resolvedPeerIdentity,
      duplicateRaceLogContext:
          'manual endpoint=$address:$port peerDeviceId=$resolvedPeerIdentity',
    );
    RiftLog.info(
      '[Pairing] Manual endpoint $address:$port established session with '
      'peerDeviceId=$resolvedPeerDeviceId. Dispatching IPC pairing command.',
    );
    _pendingTrustedEndpointHints[resolvedPeerDeviceId] = TrustedPeerEndpoint(
      address: address,
      port: port,
      source: 'manual-pairing',
      addressFamily: InternetAddress.tryParse(address)?.type.name,
      lastSuccessAt: DateTime.now().toUtc(),
    );
    await _ensurePeerRecordForPairing(resolvedPeerDeviceId);

    await _pairingManager!.handleIpcCommand({
      'method': method,
      'params': {...params, 'deviceId': resolvedPeerDeviceId},
    });
    RiftLog.info(
      '[Pairing] Manual endpoint $address:$port completed '
      'handleIpcCommand for peerDeviceId=$resolvedPeerDeviceId.',
    );

    final record = await _trustStore?.getPeer(resolvedPeerDeviceId);
    if (record == null) {
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }

    return {
      'deviceId': resolvedPeerDeviceId,
      'fingerprint': _formatFingerprint(
        _identityManager!.getDeviceFingerprint(),
      ),
      'peerFingerprint': _deriveFingerprint(record.certDer),
      'expiresInMs': 120000,
    };
  }

  Future<void> _pingEndpointRpc(String address, int port) async {
    try {
      RiftLog.debug(
        '[Discovery] Reverse pinging explicit endpoint $address:$port',
      );
      final transport = _transport;
      final sessionManager = _sessionManager;
      if (transport == null || sessionManager == null) return;

      // Establish a full session to force Linux to recognize us and persist us
      // in its TrustStore. Linux will drop us if we don't send session.hello.
      final resolvedPeerIdentity = await transport.connectTo(address, port);
      await sessionManager.sendSessionHello(resolvedPeerIdentity);
      RiftLog.debug(
        '[Discovery] Reverse ping session established successfully',
      );
    } catch (e) {
      RiftLog.debug('[Discovery] Reverse ping to $address:$port failed: $e');
    }
  }

  Future<void> prefetchSessionForDiscoveredPeer(String peerDeviceId) async {
    try {
      final sessionManager = _sessionManager;
      if (sessionManager == null) {
        return;
      }

      final ctx = sessionManager.getContext(peerDeviceId);
      if (ctx != null && ctx.handshakeState == HandshakeState.established) {
        return;
      }

      RiftLog.debug(
        '[Session] Prefetching outbound session for discovered peer $peerDeviceId',
      );
      await _ensureSessionForPairing(peerDeviceId);
    } catch (e) {
      final classification = _classifyPairingConnectFailure(e);
      final detail = _describePairingConnectFailure(e);
      RiftLog.debug(
        '[Session] Session prefetch skipped for $peerDeviceId '
        'classification=$classification detail=$detail error=$e',
      );
    }
  }

  /// The static entry point for spawning the Isolate from Flutter
  static void isolateEntryPoint(
    Map<String, dynamic> args, {
    PeerTransportFactory? peerTransportFactory,
  }) async {
    final storagePath = args['storagePath'] as String;
    final sendPort = args.containsKey('sendPort')
        ? args['sendPort'] as SendPort
        : null;
    final port = args['port'] as int? ?? 11112;
    final enableDiscovery = args['enableDiscovery'] as bool? ?? true;
    final enableTransport = args['enableTransport'] as bool? ?? true;
    // Identity seed loaded by the host (e.g. from a platform keystore) before
    // spawning; the daemon isolate itself cannot use platform channels.
    final identityKey = args['identityKey'];
    final localDisplayName = args['localDisplayName'] as String?;

    final daemon = RiftDaemon(
      storagePath: storagePath,
      port: port,
      enableDiscovery: enableDiscovery,
      enableTransport: enableTransport,
      peerTransportFactory: peerTransportFactory,
      identityPrivateKeyProvider: identityKey is Uint8List
          ? () async => identityKey
          : null,
      localDisplayName: localDisplayName,
      onIpcEvent: (event) => sendPort?.send(event),
    );

    try {
      await daemon.start();

      if (args.containsKey('sendPort')) {
        final SendPort sendPort = args['sendPort'] as SendPort;

        // Forward uncaught isolate exceptions to the Flutter UI layer.
        Isolate.current.addErrorListener(sendPort);

        final rpcPort = ReceivePort();
        try {
          rpcPort.listen((message) async {
            if (message is Map<String, dynamic>) {
              if (message['internal'] == 'android.discoverySnapshot') {
                final peers = message['peers'];
                daemon.replaceExternalDiscoveredPeers(
                  peers is List
                      ? peers.whereType<Map>().map(Map<String, dynamic>.from)
                      : const <Map<String, dynamic>>[],
                  isDiscovering: message['isDiscovering'] == true,
                );
                return;
              }

              if (message['internal'] == 'android.prefetchPeer') {
                final deviceId = message['deviceId'];
                if (deviceId is String) {
                  unawaited(daemon.prefetchSessionForDiscoveredPeer(deviceId));
                }
                return;
              }

              if (message['jsonrpc'] == '2.0' && message['method'] is String) {
                final id = message['id'];
                try {
                  final result = await daemon.handleJsonRpcRequest(message);
                  sendPort.send(RiftDaemon.jsonRpcResult(id, result));
                  if (message['method'] == 'rift.stop') {
                    rpcPort.close();
                  }
                } on RiftException catch (e) {
                  sendPort.send(RiftDaemon.jsonRpcError(id, e.code, e.message));
                } on UnsupportedError catch (e) {
                  sendPort.send(
                    RiftDaemon.jsonRpcError(id, -32601, e.toString()),
                  );
                } on ArgumentError catch (e) {
                  sendPort.send(
                    RiftDaemon.jsonRpcError(
                      id,
                      -32602,
                      e.message?.toString() ?? e.toString(),
                    ),
                  );
                } on SocketException catch (e) {
                  sendPort.send(
                    RiftDaemon.jsonRpcError(
                      id,
                      -32000,
                      'NetworkError: ${e.message}',
                    ),
                  );
                } catch (e) {
                  sendPort.send(
                    RiftDaemon.jsonRpcError(id, -32603, e.toString()),
                  );
                }
              } else {
                sendPort.send(
                  RiftDaemon.jsonRpcError(
                    message['id'],
                    -32600,
                    'Invalid Request',
                  ),
                );
              }
            }
          });

          // Signal readiness as early as possible so the Flutter UI can start
          // issuing requests even if discovery/presence listeners are still
          // wiring up (those can be slow on some Android builds).
          sendPort.send({
            'jsonrpc': '2.0',
            'method': 'rift.daemonReady',
            'params': {
              'status': 'running',
              'deviceId': daemon._identityManager!.deviceId,
              'advertisedPort': daemon._boundTransportPort ?? daemon.port,
              'fingerprintPrefix': _fingerprintPrefix(
                daemon._identityManager!.getDeviceFingerprint(),
              ),
              'rpcPort': rpcPort.sendPort,
            },
          });
        } on SocketException catch (e) {
          rpcPort.close();
          sendPort.send({
            'jsonrpc': '2.0',
            'method': 'rift.daemonError',
            'params': {
              'status': 'error',
              'error': 'SocketException: ${e.message}',
            },
          });
        } catch (e) {
          // Close port to avoid ReceivePort leak if IPC setup fails.
          rpcPort.close();
          sendPort.send({
            'jsonrpc': '2.0',
            'method': 'rift.daemonError',
            'params': {'status': 'error', 'error': e.toString()},
          });
        }
      }
    } on SocketException catch (e) {
      if (args.containsKey('sendPort')) {
        final SendPort sendPort = args['sendPort'] as SendPort;
        sendPort.send({
          'jsonrpc': '2.0',
          'method': 'rift.daemonError',
          'params': {
            'status': 'error',
            'error': 'SocketException: ${e.message}',
          },
        });
      }
    } catch (e) {
      if (args.containsKey('sendPort')) {
        final SendPort sendPort = args['sendPort'] as SendPort;
        sendPort.send({
          'jsonrpc': '2.0',
          'method': 'rift.daemonError',
          'params': {'status': 'error', 'error': e.toString()},
        });
      }
    }
  }
}
