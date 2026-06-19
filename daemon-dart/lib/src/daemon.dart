import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/crypto/cert_decoder.dart';
import 'package:daemon_dart/src/crypto/identity_manager_impl.dart';
import 'package:daemon_dart/src/crypto/base32_utils.dart';
import 'package:daemon_dart/src/core/rift_constants.dart';
import 'package:daemon_dart/src/core/rift_exceptions.dart';
import 'package:daemon_dart/src/core/rpc_utils.dart';
import 'package:daemon_dart/src/network/discovery_service_impl.dart';
import 'package:daemon_dart/src/network/transport_impl.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/interfaces/discovery_service.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';
import 'package:daemon_dart/src/storage/trust_store_impl.dart';
import 'package:daemon_dart/src/pairing/pairing_manager.dart';
import 'package:path/path.dart' as p;

/// The root orchestrator for the Rift Android Daemon.
/// This class encapsulates all network, crypto, and session services
/// and is designed to be executed inside a background Isolate 
/// hosted by an Android Foreground Service.
class RiftDaemon {
  IdentityManagerImpl? _identityManager;
  DiscoveryServiceImpl? _discoveryService;
  TransportImpl? _transport;
  SessionManager? _sessionManager;
  TrustStoreImpl? _trustStore;
  PairingManager? _pairingManager;
  final Map<String, DiscoveredPeer> _discoveredPeers = {};

  final String storagePath;
  final int port;
  final void Function(Map<String, dynamic>)? onIpcEvent;

  RiftDaemon({required this.storagePath, this.port = 11112, this.onIpcEvent});

  Future<void> start() async {
    _identityManager = IdentityManagerImpl(storagePath);
    await _identityManager!.initialize();

    _trustStore = TrustStoreImpl(p.join(storagePath, 'trust_store.db'));
    await _trustStore!.initialize();

    _transport = TransportImpl(_identityManager!, port: port);
    await _transport!.startServer();

    _sessionManager = SessionManager(
      _transport!,
      _identityManager!,
      _trustStore!,
      peerAllowanceResolver: (peerDeviceId) async {
        final record = await _trustStore!.getPeer(peerDeviceId);
        return record == null ||
            (record.state != TrustState.blocked && record.state != TrustState.revoked);
      },
    );

    _pairingManager = PairingManager(
      trustStore: _trustStore!,
      sessionManager: _sessionManager!,
      identityManager: _identityManager!,
      onIpcEvent: (event) {
        onIpcEvent?.call(event);
      },
    );

    _discoveryService = DiscoveryServiceImpl(
      port: port,
      deviceIdHint: _identityManager!.deviceId,
      fingerprintPrefix: _fingerprintPrefix(_identityManager!.getDeviceFingerprint()),
    );
    await _discoveryService!.startAdvertising();
    await _discoveryService!.startDiscovery();
    // Discovery remains passive for browsing, but pairing may trigger an
    // explicit connect/handshake when the UI selects a discovered peer.
  }

  Future<void> stop() async {
    await _pairingManager?.dispose();
    await _discoveryService?.stopDiscovery();
    await _discoveryService?.stopAdvertising();
    await _discoveryService?.dispose(); // closes _peerStreamController
    await _transport?.stopServer();
    await _sessionManager?.dispose();
    _trustStore?.dispose();
    await _identityManager?.dispose();
  }

  Map<String, dynamic> getDeviceInfo() {
    final identityManager = _identityManager;
    if (identityManager == null) {
      throw const RiftIdentityNotInitializedException('Identity manager not initialized');
    }

    return {
      'deviceId': identityManager.deviceId,
      'fingerprint': _formatFingerprint(identityManager.getDeviceFingerprint()),
      'implementationId': RiftConstants.implementationId,
      'protocolVersion': RiftConstants.protocolVersion,
      'capabilities': RiftConstants.capabilities,
    };
  }

  Future<List<Map<String, dynamic>>> listTrustedPeers() async {
    final trustStore = _trustStore;
    if (trustStore == null) return [];

    // ipc.md: listTrustedPeers is a trust-management surface.
    // Include all non-discovered peers (pairing_pending, trusted, blocked, revoked).
    final peers = <PeerRecord>[
      ...await trustStore.getPeersByState(TrustState.pairingPending),
      ...await trustStore.getPeersByState(TrustState.trusted),
      ...await trustStore.getPeersByState(TrustState.blocked),
      ...await trustStore.getPeersByState(TrustState.revoked),
    ];

    return peers.map((peer) {
      final ctx = _sessionManager!.getContext(peer.deviceId);
      final lastSeenAt = ctx?.lastHeartbeatReceived?.toUtc().toIso8601String() ??
          peer.lastSeenAt?.toUtc().toIso8601String();
      return {
        'deviceId': peer.deviceId,
        if (peer.displayName != null) 'displayName': peer.displayName,
        'trustState': peer.state.toJson(),
        if (peer.pairedAt != null) 'pairedAt': peer.pairedAt!.toUtc().toIso8601String(),
        'lastSeenAt': lastSeenAt,
        'presence': ctx?.currentPresenceStatus ?? 'offline',
        'capabilities': ctx?.negotiatedCapabilities.map((c) => c.name).toList() ?? <String>[],
      };
    }).toList();
  }

  Future<List<Map<String, dynamic>>> listPeersByState(String trustState) async {
    final trustStore = _trustStore;
    if (trustStore == null) return [];

    final state = TrustState.fromJson(trustState);
    final peers = await trustStore.getPeersByState(state);

    return peers.map((peer) {
      final ctx = _sessionManager!.getContext(peer.deviceId);
      final lastSeenAt = ctx?.lastHeartbeatReceived?.toUtc().toIso8601String() ??
          peer.lastSeenAt?.toUtc().toIso8601String();
      return {
        'deviceId': peer.deviceId,
        if (peer.displayName != null) 'displayName': peer.displayName,
        'trustState': peer.state.toJson(),
        if (peer.pairedAt != null) 'pairedAt': peer.pairedAt!.toUtc().toIso8601String(),
        'lastSeenAt': lastSeenAt,
        'presence': ctx?.currentPresenceStatus ?? 'offline',
        'capabilities': ctx?.negotiatedCapabilities.map((c) => c.name).toList() ?? <String>[],
      };
    }).toList();
  }

  Future<List<Map<String, dynamic>>> listDiscoveredPeers() async {
    final trustStore = _trustStore;
    final results = <Map<String, dynamic>>[];

    for (final entry in _discoveredPeers.entries) {
      final peer = entry.value;
      final hintedDeviceId = peer.deviceIdHint;
      final trustState = hintedDeviceId != null && trustStore != null
          ? (await trustStore.getPeer(hintedDeviceId))?.state.toJson() ?? 'discovered'
          : 'discovered';

      results.add({
        'deviceId': hintedDeviceId ?? peer.instanceId,
        'address': peer.address,
        'port': peer.port,
        'trustState': trustState,
        'txtRecord': {
          'minV': peer.minVersion,
          'maxV': peer.maxVersion,
          if (peer.deviceIdHint != null) 'did': peer.deviceIdHint,
          if (peer.fingerprintPrefix != null) 'fp': peer.fingerprintPrefix,
        },
        if (hintedDeviceId == null) 'instanceId': peer.instanceId,
      });
    }

    return results;
  }

  Future<Map<String, dynamic>> handleJsonRpcRequest(Map<String, dynamic> request) async {
    final method = request['method'] as String?;
    final params = RpcUtils.normalizeParams(request['params']);

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
        final ctx = _sessionManager!.getContext(peerDeviceId);
        return {
          'deviceId': peerDeviceId,
          'status': ctx?.currentPresenceStatus ?? 'offline',
          'lastSeenAt': ctx?.lastHeartbeatReceived?.toUtc().toIso8601String() ??
              trustRecord.lastSeenAt?.toUtc().toIso8601String(),
          'capabilities': ctx?.negotiatedCapabilities.map((c) => c.name).toList() ?? [],
        };
      case 'rift.listDiscoveredPeers':
        return {'peers': await listDiscoveredPeers()};
      case 'rift.startDiscovery':
        await _discoveryService?.startDiscovery();
        return {'started': true};
      case 'rift.stopDiscovery':
        await _discoveryService?.stopDiscovery();
        _discoveredPeers.clear();
        return {'stopped': true};
      case 'rift.startPairing':
        final requestedPeerId = RpcUtils.requireStringParam(params, 'deviceId');
        final peerDeviceId = await _ensureSessionForPairing(requestedPeerId);
        await _ensurePeerRecordForPairing(peerDeviceId);
        await _pairingManager?.handleIpcCommand({
          'method': method,
          'params': {
            ...params,
            'deviceId': peerDeviceId,
          },
        });
        final record = await _trustStore?.getPeer(peerDeviceId);
        if (record == null) {
          throw const RiftNotFoundException('Peer not found in TrustStore');
        }
        return {
          'fingerprint': _formatFingerprint(_identityManager!.getDeviceFingerprint()),
          'peerFingerprint': _deriveFingerprint(record.certDer),
          'expiresInMs': 120000, // ipc.md §4.3: startPairing always returns 120 000 ms
        };
      case 'rift.approvePairing':
        await _pairingManager?.handleIpcCommand({'method': method, 'params': params});
        return {
          'trustedDeviceId': RpcUtils.requireStringParam(params, 'deviceId'),
          'persistedAt': DateTime.now().toUtc().toIso8601String(),
        };
      case 'rift.rejectPairing':
        await _pairingManager?.handleIpcCommand({'method': method, 'params': params});
        return {'rejected': true};
      case 'rift.revokeTrust':
        RpcUtils.requireStringParam(params, 'deviceId');
        RpcUtils.requireStringParam(params, 'reason');
        await _pairingManager?.handleIpcCommand({
          'method': 'rift.unpair',
          'params': {
            'deviceId': params['deviceId'],
            'reason': params['reason'],
          },
        });
        return {
          'revoked': true,
          'revokedAt': DateTime.now().toUtc().toIso8601String(),
        };
      case 'rift.unblockPeer':
        await _pairingManager?.handleIpcCommand({'method': method, 'params': params});
        return {'unblocked': true};
      case 'rift.connect':
        final host = RpcUtils.requireStringParam(params, 'host');
        final port = params['port'];
        if (port is! int) {
          throw ArgumentError.value(port, 'port', 'must be an integer');
        }
        final peerDeviceId = params['peerDeviceId'] as String?;
        final resolvedPeerDeviceId = await _transport!.connectTo(host, port, expectedDeviceId: peerDeviceId);
        await _sessionManager!.sendSessionHello(resolvedPeerDeviceId);
        return {'connected': true, 'deviceId': resolvedPeerDeviceId};
      case 'rift.stop':
        await stop();
        return {'stopped': true};
      default:
        throw UnsupportedError('Method not found: $method');
    }
  }

  void trackDiscoveredPeer(DiscoveredPeer peer) {
    _discoveredPeers[peer.instanceId] = peer;
  }

  static Map<String, dynamic> jsonRpcResult(Object? id, Map<String, dynamic> result) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
  }

  static Map<String, dynamic> jsonRpcError(Object? id, int code, String message) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': code,
        'message': message,
      }
    };
  }


  static String _formatFingerprint(Uint8List hashBytes) {
    final base32Str = Base32Utils.encode(hashBytes).toUpperCase().replaceAll('=', '');
    final truncated = base32Str.substring(0, 32);
    return truncated.replaceAllMapped(RegExp(r'.{4}'), (m) => '${m.group(0)}-').substring(0, 39);
  }

  static String _deriveFingerprint(Uint8List certDer) {
    final peerPublicKey = RiftCertDecoder.extractEd25519PublicKeyFromDer(certDer);
    final hash = sha256.convert(peerPublicKey).bytes;
    return _formatFingerprint(Uint8List.fromList(hash));
  }

  static String _fingerprintPrefix(Uint8List hashBytes) {
    final base32Str = Base32Utils.encode(hashBytes).toUpperCase().replaceAll('=', '');
    return base32Str.substring(0, 8);
  }

  Future<void> _ensurePeerRecordForPairing(String peerDeviceId) async {
    final trustStore = _trustStore;
    final transport = _transport;
    if (trustStore == null || transport == null) {
      throw const RiftIdentityNotInitializedException('Daemon services not initialized');
    }

    final existing = await trustStore.getPeer(peerDeviceId);
    if (existing != null) {
      return;
    }

    final peerCertDer = transport.getPeerCert(peerDeviceId);
    if (peerCertDer == null) {
      throw const RiftNotFoundException('Peer not found in TrustStore');
    }

    await trustStore.upsertPeer(PeerRecord(
      deviceId: peerDeviceId,
      certDer: Uint8List.fromList(peerCertDer),
      state: TrustState.discovered,
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  Future<String> _ensureSessionForPairing(String peerDeviceId) async {
    final sessionManager = _sessionManager;
    final transport = _transport;
    if (sessionManager == null || transport == null) {
      throw const RiftIdentityNotInitializedException('Daemon services not initialized');
    }

    final ctx = sessionManager.getContext(peerDeviceId);
    if (ctx != null && ctx.handshakeState == HandshakeState.established) {
      return peerDeviceId;
    }

    final discoveredPeer = _findDiscoveredPeer(peerDeviceId);
    if (discoveredPeer == null) {
      throw const RiftNotFoundException('Peer not found in discovery cache');
    }

    final expectedDeviceId = discoveredPeer.deviceIdHint == peerDeviceId ? peerDeviceId : null;
    final resolvedPeerDeviceId = await transport.connectTo(
      discoveredPeer.address,
      discoveredPeer.port,
      expectedDeviceId: expectedDeviceId,
    );

    if (sessionManager.getContext(resolvedPeerDeviceId) == null) {
      await sessionManager.sendSessionHello(resolvedPeerDeviceId);
    }
    await sessionManager.waitForSessionEstablished(resolvedPeerDeviceId);
    return resolvedPeerDeviceId;
  }

  DiscoveredPeer? _findDiscoveredPeer(String peerDeviceId) {
    for (final entry in _discoveredPeers.entries) {
      final peer = entry.value;
      if (peer.deviceIdHint == peerDeviceId || entry.key == peerDeviceId) {
        return peer;
      }
    }
    return null;
  }

  /// The static entry point for spawning the Isolate from Flutter
  static void isolateEntryPoint(Map<String, dynamic> args) async {
    final storagePath = args['storagePath'] as String;
    final sendPort = args.containsKey('sendPort') ? args['sendPort'] as SendPort : null;
    final port = args['port'] as int? ?? 11112;
    
    final daemon = RiftDaemon(
      storagePath: storagePath,
      port: port,
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
                  sendPort.send(RiftDaemon.jsonRpcError(id, -32601, e.toString()));
                } on ArgumentError catch (e) {
                  sendPort.send(RiftDaemon.jsonRpcError(id, -32602, e.message?.toString() ?? e.toString()));
                } on SocketException catch (e) {
                  sendPort.send(RiftDaemon.jsonRpcError(id, -32000, 'NetworkError: ${e.message}'));
                } catch (e) {
                  sendPort.send(RiftDaemon.jsonRpcError(id, -32603, e.toString()));
                }
              } else {
                sendPort.send(RiftDaemon.jsonRpcError(message['id'], -32600, 'Invalid Request'));
              }
            }
          });

          daemon._discoveryService!.onDeviceDiscovered.listen((peer) {
            if (peer.deviceIdHint == daemon._identityManager!.deviceId) return;
            daemon.trackDiscoveredPeer(peer);
            sendPort.send({
              'jsonrpc': '2.0',
              'method': 'rift.onPeerDiscovered',
              'params': {
                'deviceId': peer.deviceIdHint ?? peer.instanceId,
                'address': peer.address,
                'port': peer.port,
                'txtRecord': {
                  'minV': peer.minVersion,
                  'maxV': peer.maxVersion,
                  if (peer.deviceIdHint != null) 'did': peer.deviceIdHint,
                  if (peer.fingerprintPrefix != null) 'fp': peer.fingerprintPrefix,
                }
              }
            });
          });

          daemon._sessionManager!.onPresenceUpdate.listen((ctx) {
            sendPort.send({
              'jsonrpc': '2.0',
              'method': 'rift.onPresenceUpdate',
              'params': {
                'deviceId': ctx.peerDeviceId,
                'status': ctx.currentPresenceStatus,
                'lastSeenAt': ctx.lastHeartbeatReceived?.toUtc().toIso8601String(),
                'capabilities': ctx.negotiatedCapabilities.map((c) => c.name).toList(),
              }
            });
          });

          // Wrap startup status in a JSON-RPC 2.0 notification so all transport
          // messages conform to ipc.md and the Flutter client can use a single
          // parsing path without special-casing status/error objects.
          sendPort.send({
            'jsonrpc': '2.0',
            'method': 'rift.daemonReady',
            'params': {
              'status': 'running',
              'deviceId': daemon._identityManager!.deviceId,
              'rpcPort': rpcPort.sendPort,
            },
          });
        } on SocketException catch (e) {
          rpcPort.close();
          sendPort.send({
            'jsonrpc': '2.0',
            'method': 'rift.daemonError',
            'params': {'status': 'error', 'error': 'SocketException: ${e.message}'},
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
          'params': {'status': 'error', 'error': 'SocketException: ${e.message}'},
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
