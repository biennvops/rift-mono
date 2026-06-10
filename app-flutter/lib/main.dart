import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'constants.dart';
import 'screens/event_log_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/trusted_devices_screen.dart';

import 'src/ipc/json_rpc_client.dart';
import 'src/ipc/transport_factory.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final client = JsonRpcRiftClient(TransportFactory.create());
  // Start the connection immediately in the background
  client.connect().catchError((Object error, StackTrace stackTrace) {
    debugPrint('Initial IPC connection failed (will auto-reconnect): $error');
  });

  runApp(
    Provider<JsonRpcRiftClient>.value(
      value: client,
      child: const RiftApp(),
    ),
  );
}

class RiftApp extends StatelessWidget {
  const RiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: AppStrings.appTitle,
      theme: ThemeData(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.appTitle)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(AppStrings.homeSubtitle),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PairingScreen(),
                  ),
                );
              },
              child: const Text(AppStrings.openPairing),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TrustedDevicesScreen(),
                  ),
                );
              },
              child: const Text(AppStrings.openTrustedDevices),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EventLogScreen(),
                  ),
                );
              },
              child: const Text(AppStrings.openEventLog),
            ),
          ],
        ),
      ),
    );
  }
}
