import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../src/ipc/json_rpc_client.dart';
import 'pairing_screen.dart';

class PairDeviceScreen extends StatefulWidget {
  const PairDeviceScreen({super.key});

  @override
  State<PairDeviceScreen> createState() => _PairDeviceScreenState();
}

class _PairDeviceScreenState extends State<PairDeviceScreen> {
  final TextEditingController _manualInputController = TextEditingController();
  List<dynamic> _discoveredPeers = [];
  Timer? _discoveryTimer;
  JsonRpcRiftClient? _client;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _client ??= context.read<JsonRpcRiftClient>();
  }

  @override
  void dispose() {
    _manualInputController.dispose();
    _discoveryTimer?.cancel();
    unawaited(_stopDiscovery());
    super.dispose();
  }

  Future<void> _startDiscovery() async {
    final client = _client ?? context.read<JsonRpcRiftClient>();
    try {
      await client.startDiscovery();
      _discoveryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted) _loadDiscoveredPeers();
      });
      await _loadDiscoveredPeers();
    } catch (e) {
      // Handle error
    }
  }

  Future<void> _stopDiscovery() async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      await client.stopDiscovery();
    } catch (_) {}
  }

  Future<void> _loadDiscoveredPeers() async {
    if (!mounted) return;
    final client = _client ?? context.read<JsonRpcRiftClient>();
    try {
      final discoveredResult = await client.listDiscoveredPeers();
      final peers = List<dynamic>.from(discoveredResult['peers'] ?? const []);
      if (mounted) {
        setState(() {
          _discoveredPeers = peers;
        });
      }
    } catch (_) {}
  }

  Future<void> _pairWithDevice(String deviceId) async {
    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (_) => PairingScreen(
        initialDeviceId: deviceId,
        autoStart: true,
      ),
    );
    if (result != null && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  Future<void> _pairManually() async {
    final input = _manualInputController.text.trim();
    if (input.isEmpty) return;

    String address = input;
    int port = 11112;

    if (input.startsWith('[')) {
      final closingIndex = input.indexOf(']');
      if (closingIndex > 0) {
        address = input.substring(1, closingIndex);
        final suffix = input.substring(closingIndex + 1);
        if (suffix.startsWith(':')) {
          port = int.tryParse(suffix.substring(1)) ?? 11112;
        }
      }
    } else {
      final lastColon = input.lastIndexOf(':');
      if (lastColon > 0 && input.indexOf(':') == lastColon) {
        address = input.substring(0, lastColon);
        port = int.tryParse(input.substring(lastColon + 1)) ?? 11112;
      }
    }

    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (_) => PairingScreen(
        initialEndpointAddress: address,
        initialEndpointPort: port,
        autoStart: true,
      ),
    );
    if (result != null && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  IconData _platformIcon(String? platform) {
    switch (platform?.toLowerCase()) {
      case 'android':
      case 'ios':
        return Icons.smartphone;
      case 'windows':
        return Icons.laptop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.terminal;
      default:
        return Icons.devices;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [

          Center(
            child: Container(
              width: 600,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.9,
              ),
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Modal Header
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.shield, color: theme.colorScheme.primary, size: 28),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Trust New Device',
                                    style: theme.textTheme.headlineMedium?.copyWith(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Securely pair a new device to your Rift network.',
                                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          color: theme.colorScheme.onSurfaceVariant,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  
                  // Modal Body
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Nearby Devices Section
                          Row(
                            children: [
                              Icon(Icons.radar, size: 16, color: theme.colorScheme.primary),
                              const SizedBox(width: 4),
                              Text(
                                'NEARBY DEVICES',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.primary,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          
                          if (_discoveredPeers.isEmpty)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant,
                                  style: BorderStyle.solid,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                children: [
                                  SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: theme.colorScheme.outline,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Scanning for nearby Rift devices...',
                                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                                  ),
                                ],
                              ),
                            )
                          else
                            Column(
                              children: _discoveredPeers.map((peer) {
                                final p = peer as Map<String, dynamic>;
                                final String deviceId = p['deviceId']?.toString() ?? '';
                                final String rawDisplayName = p['displayName']?.toString() ?? '';
                                final String titleText = rawDisplayName.isNotEmpty ? rawDisplayName : (deviceId.length > 16 ? deviceId.substring(0, 16) : deviceId);
                                final String platform = p['platform']?.toString() ?? 'unknown';

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: theme.colorScheme.outlineVariant),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.surfaceContainer,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(_platformIcon(platform), color: theme.colorScheme.onSurface),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              titleText,
                                              style: theme.textTheme.labelMedium?.copyWith(
                                                color: theme.colorScheme.onSurface,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '$platform • Secure Sync v0.1',
                                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                            ),
                                          ],
                                        ),
                                      ),
                                      FilledButton(
                                        onPressed: () => _pairWithDevice(deviceId),
                                        style: FilledButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                        child: const Text('Pair'),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                            
                          const SizedBox(height: 32),
                          
                          // Divider
                          Row(
                            children: [
                              Expanded(child: Container(height: 1, color: theme.colorScheme.outlineVariant)),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: Text('OR', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                              ),
                              Expanded(child: Container(height: 1, color: theme.colorScheme.outlineVariant)),
                            ],
                          ),
                          
                          const SizedBox(height: 32),
                          
                          // Add Manually Section
                          Row(
                            children: [
                              Icon(Icons.edit_note, size: 16, color: theme.colorScheme.secondary),
                              const SizedBox(width: 4),
                              Text(
                                'ADD MANUALLY',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.secondary,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: theme.colorScheme.outlineVariant),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Enter the IP address or hostname of the device you want to pair.',
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'IP Address / Hostname',
                                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _manualInputController,
                                        decoration: InputDecoration(
                                          hintText: 'e.g., 192.168.1.50 or device.local',
                                          hintStyle: TextStyle(color: theme.colorScheme.outline),
                                          filled: true,
                                          fillColor: theme.colorScheme.surface,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(8),
                                            borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(8),
                                            borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    OutlinedButton(
                                      onPressed: _pairManually,
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: theme.colorScheme.primary,
                                        side: BorderSide(color: theme.colorScheme.primary),
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      child: const Text('Connect'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  // Modal Footer
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.secondary,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
