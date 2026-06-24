import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';

import 'constants.dart';
import 'screens/event_log_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/trusted_devices_screen.dart';
import 'screens/settings_screen.dart';

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

class RiftApp extends StatefulWidget {
  const RiftApp({super.key});

  @override
  State<RiftApp> createState() => _RiftAppState();
}

class _RiftAppState extends State<RiftApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<Map<String, dynamic>>? _pairingRequestSub;
  String? _activePairingDeviceId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindPairingRequests();
    });
  }

  @override
  void dispose() {
    _pairingRequestSub?.cancel();
    super.dispose();
  }

  void _bindPairingRequests() {
    final client = context.read<JsonRpcRiftClient>();
    _pairingRequestSub = client.onPairingRequest.listen((event) {
      final navigator = _navigatorKey.currentState;
      if (!mounted || navigator == null) return;

      final deviceId = event['deviceId']?.toString();
      if (deviceId == null || deviceId.isEmpty) return;
      // Guard against notification bursts stacking multiple pairing screens.
      if (_activePairingDeviceId != null) return;

      _activePairingDeviceId = deviceId;
      try {
        navigator
            .push(
              MaterialPageRoute<void>(
                builder: (_) => PairingScreen(
                  initialDeviceId: deviceId,
                  initialDisplayName: event['displayName']?.toString(),
                  initialPeerFingerprint: event['fingerprint']?.toString(),
                  initialExpiresInMs: (event['expiresInMs'] as num?)?.toInt(),
                  initialCanApproveLocally: true,
                  initialStatus: 'Incoming pairing request',
                ),
              ),
            )
            .whenComplete(() {
              if (mounted && _activePairingDeviceId == deviceId) {
                _activePairingDeviceId = null;
              }
            });
      } catch (_) {
        if (mounted && _activePairingDeviceId == deviceId) {
          _activePairingDeviceId = null;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: AppStrings.appTitle,
      theme: ThemeData(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _statusPollTimer;
  bool _isConnected = false;
  int _trustedCount = 0;
  int _onlineTrustedCount = 0;
  int _discoveredCount = 0;
  bool _isDiscovering = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncHomeStatus();
      _statusPollTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _syncHomeStatus(),
      );
    });
  }

  @override
  void dispose() {
    _statusPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _syncHomeStatus() async {
    if (!mounted) return;
    final client = context.read<JsonRpcRiftClient>();
    final nextConnected = client.isConnected;

    if (!nextConnected) {
      if (_isConnected ||
          _trustedCount != 0 ||
          _onlineTrustedCount != 0 ||
          _discoveredCount != 0 ||
          _isDiscovering) {
        setState(() {
          _isConnected = false;
          _trustedCount = 0;
          _onlineTrustedCount = 0;
          _discoveredCount = 0;
          _isDiscovering = false;
        });
      }
      return;
    }

    try {
      final trustedResult = await client.listTrustedPeers() as Map;
      final discoveredResult = await client.listDiscoveredPeers() as Map;
      if (!mounted) return;

      final trustedPeers = List<dynamic>.from(trustedResult['peers'] ?? const []);
      final discoveredPeers = List<dynamic>.from(
        discoveredResult['peers'] ?? const [],
      );
      final onlineTrusted = trustedPeers.where((peer) {
        return peer is Map && peer['presence']?.toString() == 'online';
      }).length;
      final isDiscovering = discoveredResult['isDiscovering'] == true;

      if (nextConnected == _isConnected &&
          trustedPeers.length == _trustedCount &&
          onlineTrusted == _onlineTrustedCount &&
          discoveredPeers.length == _discoveredCount &&
          isDiscovering == _isDiscovering) {
        return;
      }

      setState(() {
        _isConnected = nextConnected;
        _trustedCount = trustedPeers.length;
        _onlineTrustedCount = onlineTrusted;
        _discoveredCount = discoveredPeers.length;
        _isDiscovering = isDiscovering;
      });
    } catch (_) {
      if (!_isConnected) return;
      setState(() {
        _isConnected = false;
        _trustedCount = 0;
        _onlineTrustedCount = 0;
        _discoveredCount = 0;
        _isDiscovering = false;
      });
    }
  }

  String _buildDaemonSubtitle() {
    if (!_isConnected) {
      return 'Waiting for the local daemon.';
    }

    final parts = <String>[
      '$_trustedCount trusted',
      '$_onlineTrustedCount online',
      '$_discoveredCount discovered',
      _isDiscovering ? 'discovery running' : 'discovery idle',
    ];
    return parts.join('  •  ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.appTitle)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(AppStrings.homeSubtitle),
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: _isConnected
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: Icon(
                  _isConnected ? Icons.link : Icons.link_off,
                  color: _isConnected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  _isConnected
                      ? AppStrings.daemonConnected
                      : AppStrings.daemonReconnecting,
                ),
                subtitle: Text(
                  _isConnected
                      ? _buildDaemonSubtitle()
                      : 'Waiting for the local daemon.',
                ),
              ),
            ),
            const SizedBox(height: 8),
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
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
              child: const Text(AppStrings.openSettings),
            ),
          ],
        ),
      ),
    );
  }
}
