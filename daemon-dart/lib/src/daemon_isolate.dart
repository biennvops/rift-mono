// lib/src/daemon_isolate.dart

import 'dart:isolate';
import 'dart:convert';
import 'crypto/identity_manager_impl.dart';
import 'network/discovery_service_impl.dart';
import 'network/transport_impl.dart';
import 'dart:developer' as developer;

class DaemonConfig {
  final String storagePath;
  final int port;
  DaemonConfig({required this.storagePath, required this.port});
}

/// The top-level entry point for the Android Foreground Service isolate.
void daemonEntryPoint(SendPort sendPort) async {
  developer.log('Daemon isolate starting...', name: 'Daemon');

  // To receive configuration from the main isolate
  var receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort);

  await for (var msg in receivePort) {
    if (msg is DaemonConfig) {
      developer.log('Received config. Initializing daemon core...', name: 'Daemon');
      try {
        var identityManager = IdentityManagerImpl(msg.storagePath);
        await identityManager.initialize();

        var transport = TransportImpl(identityManager, msg.port);
        await transport.initialize();
        await transport.startServer();

        var discoveryService = DiscoveryServiceImpl(identityManager, msg.port);
        
        // Link Discovery events to Flutter UI via JSON-RPC Notifications (Tuân thủ ipc.md)
        discoveryService.onDeviceDiscovered.listen((peer) {
          var notification = {
            'jsonrpc': '2.0',
            'method': 'rift.onPeerDiscovered',
            'params': {
              'deviceId': peer.deviceId,
              'address': peer.address,
              'port': peer.port,
              'txtRecord': {
                'version': peer.protocolVersion
              }
            }
          };
          sendPort.send(jsonEncode(notification));
        });

        await discoveryService.startAdvertising();
        await discoveryService.startDiscovery();

        developer.log('Daemon initialized successfully. Device ID: ${identityManager.deviceId}', name: 'Daemon');
        sendPort.send('ready');
      } catch (e, stack) {
        developer.log('Daemon failed to initialize', error: e, stackTrace: stack, name: 'Daemon');
        sendPort.send('error: $e');
      }
    }
  }
}
