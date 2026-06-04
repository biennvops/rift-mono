import 'package:flutter/material.dart';

import 'constants.dart';
import 'screens/event_log_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/trusted_devices_screen.dart';

void main() {
  runApp(const RiftApp());
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