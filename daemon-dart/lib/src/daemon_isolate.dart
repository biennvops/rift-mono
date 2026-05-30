// lib/src/daemon_isolate.dart

import 'dart:isolate';
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
