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

    // 5. Connect discovery events to Session/Transport orchestration
    _discoveryService!.onDeviceDiscovered.listen((peer) {
      if (peer.deviceIdHint == _identityManager!.deviceId) {
        return; // Ignore self
      }

      // Automatically attempt to connect to discovered peers.
      // Note: In a production app, connection might require user initiation,
      // but the spec suggests Rift continuously maintains LAN meshes.
      _transport!.connectTo(peer.address, peer.port).then((_) {
        // We do not eagerly send session.hello unless requested, 
        // or we do it to complete the mesh. Let's assume initiator sends hello.
        if (peer.deviceIdHint != null) {
          _sessionManager!.sendSessionHello(peer.deviceIdHint!);
        }
      }).catchError((e) {
        // Ignore connection failures to unreachable mDNS peers
      });
    });
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

        sendPort.send({
          'status': 'running', 
          'deviceId': daemon._identityManager!.deviceId,
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
