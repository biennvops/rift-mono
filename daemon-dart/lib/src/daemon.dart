import 'dart:isolate';
import 'package:daemon_dart/src/crypto/identity_manager_impl.dart';
import 'package:daemon_dart/src/network/discovery_service_impl.dart';
import 'package:daemon_dart/src/network/transport_impl.dart';
import 'package:daemon_dart/src/network/session_manager.dart';

/// The root orchestrator for the Rift Android Daemon.
/// This class encapsulates all network, crypto, and session services
/// and is designed to be executed inside a background Isolate 
/// hosted by an Android Foreground Service.
class RiftDaemon {
  IdentityManagerImpl? _identityManager;
  DiscoveryServiceImpl? _discoveryService;
  TransportImpl? _transport;
  SessionManager? _sessionManager;

  final String storagePath;
  final int port;

  RiftDaemon({required this.storagePath, this.port = 11112});

  Future<void> start() async {
    // 1. Initialize Identity (Loads Ed25519 root key + generates ephemeral TLS cert)
    _identityManager = IdentityManagerImpl(storagePath);
    await _identityManager!.initialize();

    // 2. Initialize Transport (Binds mTLS SecureServerSocket)
    _transport = TransportImpl(_identityManager!, port: port);
    await _transport!.startServer();

    // 3. Initialize Session Manager (Handles State Machine & session.hello PoP verification)
    _sessionManager = SessionManager(_transport!, _identityManager!);

    // 4. Start Discovery (mDNS Advertising & Scanning via nsd)
    _discoveryService = DiscoveryServiceImpl(port: port);
    await _discoveryService!.startAdvertising();
    await _discoveryService!.startDiscovery();

    // 5. Peer Discovery is now completely passive.
    // We DO NOT auto-connect to unknown devices for privacy reasons.
    // Connections must be explicitly initiated via IPC commands from the Flutter UI.
  }

  Future<void> stop() async {
    await _discoveryService?.stopDiscovery();
    await _discoveryService?.stopAdvertising();
    await _transport?.stopServer();
    await _identityManager?.dispose();
  }

  /// The static entry point for spawning the Isolate from Flutter
  static void isolateEntryPoint(Map<String, dynamic> args) async {
    final storagePath = args['storagePath'] as String;
    final daemon = RiftDaemon(storagePath: storagePath);
    
    try {
      await daemon.start();
      
      // Setup ReceivePort / SendPort for IPC with Flutter main isolate
      if (args.containsKey('sendPort')) {
        final SendPort sendPort = args['sendPort'] as SendPort;
        
        // Isolate Crash Boundary: Forward uncaught exceptions to UI layer
        Isolate.current.addErrorListener(sendPort);

        // Setup ReceivePort to listen for UI commands
        final commandPort = ReceivePort();
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
            }
          }
        });

        // Forward discovered peers to UI
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

        sendPort.send({
          'status': 'running', 
          'deviceId': daemon._identityManager!.deviceId,
          'commandPort': commandPort.sendPort,
        });
      }
    } catch (e) {
      if (args.containsKey('sendPort')) {
        final SendPort sendPort = args['sendPort'] as SendPort;
        sendPort.send({'status': 'error', 'error': e.toString()});
      }
    }
  }
}
