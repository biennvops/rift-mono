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
    } catch (_) {
      // Discovery startup errors are reflected by the subsequent refresh state.
    }
  }

  Future<void> _stopDiscovery() async {
    final client = _client;
    if (client == null) return;
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isMobile = constraints.maxWidth < 1024;
                return Container(
                  width: isMobile ? double.infinity : 600,
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.9,
                  ),
                  margin: EdgeInsets.all(isMobile ? 0 : 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isMobile ? 0 : 16),
                      bottomRight: Radius.circular(isMobile ? 0 : 16),
                    ),
                    border: isMobile
                        ? null
                        : Border.all(color: theme.colorScheme.outlineVariant),
                    boxShadow: isMobile
                        ? null
                        : [
                            BoxShadow(
                              color: theme.colorScheme.primaryContainer
                                  .withValues(alpha: 0.1),
                              blurRadius: 40,
                              offset: const Offset(0, 20),
                            ),
                          ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: theme.colorScheme.outlineVariant)),
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
                                      Icon(Icons.shield,
                                          color: theme
                                              .colorScheme.primaryContainer,
                                          size: 28),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Trust New Device',
                                        style: TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -0.01,
                                          height: 32 / 24,
                                          color: theme.colorScheme.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Securely pair a new device to your Rift network.',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w400,
                                      height: 24 / 16,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
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
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.radar,
                                      size: 16,
                                      color:
                                          theme.colorScheme.primaryContainer),
                                  const SizedBox(width: 4),
                                  Text(
                                    'NEARBY DEVICES',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.05,
                                      height: 16 / 14,
                                      color: theme.colorScheme.onSurfaceVariant,
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
                                        color:
                                            theme.colorScheme.outlineVariant),
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
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                          height: 20 / 14,
                                          color: theme.colorScheme.outline,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              else
                                Column(
                                  children: _discoveredPeers.map((peer) {
                                    final p = peer as Map<String, dynamic>;
                                    final String deviceId =
                                        p['deviceId']?.toString() ?? '';
                                    final String rawDisplayName =
                                        p['displayName']?.toString() ?? '';
                                    final String titleText =
                                        rawDisplayName.isNotEmpty
                                            ? rawDisplayName
                                            : (deviceId.length > 16
                                                ? deviceId.substring(0, 16)
                                                : deviceId);
                                    final String platform =
                                        p['platform']?.toString() ?? 'unknown';

                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 12),
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                            color: theme
                                                .colorScheme.outlineVariant),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme
                                                  .surfaceContainerLow,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(_platformIcon(platform),
                                                color: theme.colorScheme
                                                    .onSurfaceVariant),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  titleText,
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w600,
                                                    height: 24 / 16,
                                                    color: theme
                                                        .colorScheme.onSurface,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  '$platform • Secure Sync v0.1',
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w400,
                                                    height: 20 / 14,
                                                    color: theme.colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                _pairWithDevice(deviceId),
                                            style: FilledButton.styleFrom(
                                              backgroundColor: theme
                                                  .colorScheme.primaryContainer,
                                              foregroundColor:
                                                  theme.colorScheme.onPrimary,
                                              elevation: 0,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 10),
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(4)),
                                            ),
                                            child: const Text('Pair',
                                                style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
                              const SizedBox(height: 32),
                              Row(
                                children: [
                                  Expanded(
                                      child: Container(
                                          height: 1,
                                          color: theme
                                              .colorScheme.outlineVariant)),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    child: Text('OR',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          height: 16 / 12,
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                        )),
                                  ),
                                  Expanded(
                                      child: Container(
                                          height: 1,
                                          color: theme
                                              .colorScheme.outlineVariant)),
                                ],
                              ),
                              const SizedBox(height: 32),
                              Row(
                                children: [
                                  Icon(Icons.edit_note,
                                      size: 16,
                                      color:
                                          theme.colorScheme.onSurfaceVariant),
                                  const SizedBox(width: 4),
                                  Text(
                                    'ADD MANUALLY',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.05,
                                      height: 16 / 14,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: theme.colorScheme.outlineVariant),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Enter the IP address or hostname of the device you want to pair.',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                        height: 20 / 14,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      'IP Address / Hostname',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        height: 16 / 12,
                                        color: theme.colorScheme.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: _manualInputController,
                                            decoration: InputDecoration(
                                              hintText:
                                                  'e.g., 192.168.1.50 or device.local',
                                              hintStyle: TextStyle(
                                                  color: theme
                                                      .colorScheme.outline),
                                              filled: false,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 12),
                                              border: OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                  borderSide: BorderSide(
                                                      color: theme.colorScheme
                                                          .outlineVariant)),
                                              enabledBorder: OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                  borderSide: BorderSide(
                                                      color: theme.colorScheme
                                                          .outlineVariant
                                                          .withValues(
                                                              alpha: 0.6))),
                                              focusedBorder: OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                  borderSide: BorderSide(
                                                      color: theme.colorScheme
                                                          .primaryContainer,
                                                      width: 2)),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        OutlinedButton(
                                          onPressed: _pairManually,
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: theme
                                                .colorScheme.primaryContainer,
                                            side: BorderSide(
                                                color: theme.colorScheme
                                                    .primaryContainer),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 16, vertical: 10),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(4)),
                                          ),
                                          child: const Text('Connect',
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600)),
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
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border(
                              top: BorderSide(
                                  color: theme.colorScheme.outlineVariant)),
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(12)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    theme.colorScheme.onSurfaceVariant,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4)),
                              ),
                              child: const Text('Cancel',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
