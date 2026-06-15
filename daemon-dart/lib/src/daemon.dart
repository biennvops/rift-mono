import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/crypto/cert_decoder.dart';
import 'package:daemon_dart/src/crypto/identity_manager_impl.dart';
import 'package:daemon_dart/src/crypto/base32_utils.dart';
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

  static const String protocolVersion = '0.1-draft';
  static const String implementationId = 'riftd-dart/0.1.0';
  static const List<Map<String, dynamic>> capabilities = [
    {'name': 'clipboard.offer_fetch', 'version': 1},
    {'name': 'presence.basic', 'version': 1},
    {'name': 'operation.lifecycle', 'version': 1},
    {'name': 'security.event_log', 'version': 1},
  ];

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
      isPeerAllowed: (peerDeviceId) async {
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

    _discoveryService = DiscoveryServiceImpl(port: port);
    await _discoveryService!.startAdvertising();
    await _discoveryService!.startDiscovery();
    // Discovery is passive — connections are initiated explicitly via IPC from the Flutter UI.
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
      throw StateError('Identity manager not initialized');
    }

    return {
      'deviceId': identityManager.deviceId,
      'fingerprint': _formatFingerprint(identityManager.getDeviceFingerprint()),
      'implementationId': implementationId,
      'protocolVersion': protocolVersion,
      'capabilities': capabilities,
    };
  }

  Future<List<Map<String, dynamic>>> listTrustedPeers() async {
    final trustStore = _trustStore;
    if (trustStore == null) return [];

    final peers = <PeerRecord>[];
    peers.addAll(await trustStore.getPeersByState(TrustState.trusted));
    peers.addAll(await trustStore.getPeersByState(TrustState.blocked));
    peers.addAll(await trustStore.getPeersByState(TrustState.revoked));
    peers.addAll(await trustStore.getPeersByState(TrustState.pairingPending));

    return peers.map((peer) {
      return {
        'deviceId': peer.deviceId,
        if (peer.displayName != null) 'displayName': peer.displayName,
        'trustState': peer.state.toJson(),
        if (peer.pairedAt != null) 'pairedAt': peer.pairedAt!.toIso8601String(),
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
    final params = request['params'] as Map<String, dynamic>? ?? {};

    switch (method) {
      case 'rift.getDeviceInfo':
        return getDeviceInfo();
      case 'rift.listTrustedPeers':
        return {'peers': await listTrustedPeers()};
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
        await _pairingManager?.handleIpcCommand({'method': method, 'params': params});
        final record = await _trustStore?.getPeer(params['deviceId'] as String);
        if (record == null) {
          throw StateError('Peer not found in TrustStore');
        }
        return {
          'fingerprint': _formatFingerprint(_identityManager!.getDeviceFingerprint()),
          'peerFingerprint': _deriveFingerprint(record.certDer),
          'expiresInMs': 30000,
        };
      case 'rift.approvePairing':
        await _pairingManager?.handleIpcCommand({'method': method, 'params': params});
        return {
          'trustedDeviceId': params['deviceId'],
          'persistedAt': DateTime.now().toUtc().toIso8601String(),
        };
      case 'rift.rejectPairing':
        await _pairingManager?.handleIpcCommand({'method': method, 'params': params});
        return {'rejected': true};
      case 'rift.revokeTrust':
        await _pairingManager?.handleIpcCommand({
          'method': 'rift.unpair',
          'params': {'deviceId': params['deviceId']},
        });
        return {
          'revoked': true,
          'revokedAt': DateTime.now().toUtc().toIso8601String(),
        };
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

        final commandPort = ReceivePort();
        try {
          commandPort.listen((message) async {
            if (message is Map<String, dynamic>) {
              if (message['jsonrpc'] == '2.0' && message['method'] is String) {
                final id = message['id'];
                try {
                  final result = await daemon.handleJsonRpcRequest(message);
                  sendPort.send(RiftDaemon.jsonRpcResult(id, result));
                } on UnsupportedError catch (e) {
                  sendPort.send(RiftDaemon.jsonRpcError(id, -32601, e.toString()));
                } on StateError catch (e) {
                  final msg = e.message.toString();
                  final code = msg.contains('blocked or revoked') ? -32004 : -32009;
                  sendPort.send(RiftDaemon.jsonRpcError(id, code, msg));
                } catch (e) {
                  sendPort.send(RiftDaemon.jsonRpcError(id, -32603, e.toString()));
                }
                return;
              }

              final cmd = message['command'];
              if (cmd == 'stop') {
                await daemon.stop();
                commandPort.close();
              } else if (cmd == 'connect') {
                final host = message['host'] as String;
                final port = message['port'] as int;
                final peerDeviceId = message['peerDeviceId'] as String?;
                
                try {
                  final resolvedPeerDeviceId =
                      await daemon._transport!.connectTo(host, port, expectedDeviceId: peerDeviceId);
                  await daemon._sessionManager!.sendSessionHello(resolvedPeerDeviceId);
                } catch (e) {
                  sendPort.send({'event': 'connection_error', 'error': e.toString()});
                }
              } else if (cmd != null && cmd.toString().startsWith('rift.')) {
                try {
                  final result = await daemon.handleJsonRpcRequest({
                    'jsonrpc': '2.0',
                    'method': cmd,
                    'params': message,
                  });
                  sendPort.send(RiftDaemon.jsonRpcResult(message['id'], result));
                } catch (e) {
                  sendPort.send(RiftDaemon.jsonRpcError(message['id'], -32603, e.toString()));
                }
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

          sendPort.send({
            'status': 'running', 
            'deviceId': daemon._identityManager!.deviceId,
            'commandPort': commandPort.sendPort,
          });
        } catch (e) {
          // Close port to avoid ReceivePort leak if IPC setup fails.
          commandPort.close();
          sendPort.send({'status': 'error', 'error': e.toString()});
        }
      }
    } catch (e) {
      if (args.containsKey('sendPort')) {
        final SendPort sendPort = args['sendPort'] as SendPort;
        sendPort.send({'status': 'error', 'error': e.toString()});
      }
    }
  }
}
