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
    _identityManager = IdentityManagerImpl(storagePath);
    await _identityManager!.initialize();

    _transport = TransportImpl(_identityManager!, port: port);
    await _transport!.startServer();

    _sessionManager = SessionManager(_transport!, _identityManager!);

    _discoveryService = DiscoveryServiceImpl(port: port);
    await _discoveryService!.startAdvertising();
    await _discoveryService!.startDiscovery();
    // Discovery is passive — connections are initiated explicitly via IPC from the Flutter UI.
  }

  Future<void> stop() async {
    await _discoveryService?.stopDiscovery();
    await _discoveryService?.stopAdvertising();
    await _discoveryService?.dispose(); // closes _peerStreamController
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
