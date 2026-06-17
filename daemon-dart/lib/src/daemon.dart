import 'dart:isolate';
import 'package:daemon_dart/src/crypto/identity_manager_impl.dart';
import 'package:daemon_dart/src/network/discovery_service_impl.dart';
import 'package:daemon_dart/src/network/transport_impl.dart';
import 'package:daemon_dart/src/network/session_manager.dart';
import 'package:daemon_dart/src/crypto/trust_store_impl.dart';
import 'package:daemon_dart/src/interfaces/trust_store.dart';

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

  final String storagePath;
  final int port;

  RiftDaemon({required this.storagePath, this.port = 11112});

  Future<void> start() async {
    _identityManager = IdentityManagerImpl(storagePath);
    await _identityManager!.initialize();

    _trustStore = TrustStoreImpl(storagePath);
    await _trustStore!.initialize();

    _transport = TransportImpl(_identityManager!, port: port);
    await _transport!.startServer();

    _sessionManager = SessionManager(_transport!, _identityManager!, _trustStore!);

    _discoveryService = DiscoveryServiceImpl(port: port);
    await _discoveryService!.startAdvertising();
    await _discoveryService!.startDiscovery();
    // Discovery is passive — connections are initiated explicitly via IPC from the Flutter UI.
  }

  Future<void> stop() async {
    await _discoveryService?.stopDiscovery();
    await _discoveryService?.stopAdvertising();
    await _discoveryService?.dispose(); // closes _peerStreamController
    _sessionManager?.dispose();
    await _transport?.stopServer();
    await _identityManager?.dispose();
  }

  /// The static entry point for spawning the Isolate from Flutter
  static void isolateEntryPoint(Map<String, dynamic> args) async {
    final storagePath = args['storagePath'] as String;
    final daemon = RiftDaemon(storagePath: storagePath);
    
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
              final cmd = message['command'];
              if (cmd == 'stop') {
                await daemon.stop();
                commandPort.close();
              } else if (cmd == 'connect') {
                final host = message['host'] as String;
                final port = message['port'] as int;
                final peerDeviceId = message['peerDeviceId'] as String?;
                
                try {
                  await daemon._transport!.connectTo(host, port, expectedDeviceId: peerDeviceId);
                  if (peerDeviceId != null) {
                    await daemon._sessionManager!.sendSessionHello(peerDeviceId);
                  }
                } catch (e) {
                  sendPort.send({'event': 'connection_error', 'error': e.toString()});
                }
              } else if (cmd == 'getPeerPresence') {
                final peerDeviceId = message['peerDeviceId'] as String;
                final ctx = daemon._sessionManager!.getContext(peerDeviceId);
                final trustRecord = await daemon._trustStore!.getTrustRecord(peerDeviceId);
                sendPort.send({
                  'event': 'peer_presence',
                  'deviceId': peerDeviceId,
                  'status': ctx?.currentPresenceStatus ?? 'offline',
                  'lastSeenAt': ctx?.lastHeartbeatReceived?.toUtc().toIso8601String() ?? trustRecord?.lastSeenAt?.toUtc().toIso8601String(),
                  'capabilities': ctx?.negotiatedCapabilities.map((c) => c.name).toList() ?? [],
                });
              } else if (cmd == 'listTrustedPeers') {
                final peers = await daemon._trustStore!.getAllTrustRecords();
                final peerList = peers.where((p) => p.state == TrustState.trusted).map((p) {
                  final ctx = daemon._sessionManager!.getContext(p.deviceId);
                  return {
                    'deviceId': p.deviceId,
                    'fingerprint': p.fingerprint,
                    'trustState': p.state.toJson(),
                    'presence': {
                      'status': ctx?.currentPresenceStatus ?? 'offline',
                      'lastSeenAt': ctx?.lastHeartbeatReceived?.toUtc().toIso8601String() ?? p.lastSeenAt?.toUtc().toIso8601String(),
                      'capabilities': ctx?.negotiatedCapabilities.map((c) => c.name).toList() ?? [],
                    }
                  };
                }).toList();
                
                sendPort.send({
                  'event': 'trusted_peers',
                  'peers': peerList,
                });
              }
            }
          });

          daemon._discoveryService!.onDeviceDiscovered.listen((peer) {
            if (peer.deviceIdHint == daemon._identityManager!.deviceId) return;
            sendPort.send({
              'event': 'peer_discovered',
              'instanceId': peer.instanceId,
              'address': peer.address,
              'port': peer.port,
              'deviceIdHint': peer.deviceIdHint,
            });
          });

          daemon._sessionManager!.onPresenceUpdate.listen((ctx) {
            sendPort.send({
              'event': 'presence_update',
              'deviceId': ctx.peerDeviceId,
              'status': ctx.currentPresenceStatus,
              'lastSeenAt': ctx.lastHeartbeatReceived?.toUtc().toIso8601String(),
              'capabilities': ctx.negotiatedCapabilities.map((c) => c.name).toList(),
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
