import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../src/ipc/json_rpc_client.dart';

class TrustedDevicesScreen extends StatefulWidget {
  const TrustedDevicesScreen({super.key});

  @override
  State<TrustedDevicesScreen> createState() => _TrustedDevicesScreenState();
}

class _TrustedDevicesScreenState extends State<TrustedDevicesScreen> {
  bool _isDiscovering = false;
  List<dynamic> _trustedPeers = [];
  List<dynamic> _discoveredPeers = [];
  String? _error;
  
  StreamSubscription? _discoverySub;
  StreamSubscription? _trustSub;

  @override
  void initState() {
    super.initState();
    // Schedule fetch after layout to ensure Provider is accessible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
      _setupListeners();
    });
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    _trustSub?.cancel();
    super.dispose();
  }

  void _setupListeners() {
    final client = context.read<JsonRpcRiftClient>();
    _discoverySub = client.onPeerDiscovered.listen((_) => _loadData());
    _trustSub = client.onTrustChanged.listen((_) => _loadData());
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final client = context.read<JsonRpcRiftClient>();
    
    // Default empty lists if not connected
    if (!client.isConnected) {
      setState(() {
        _trustedPeers = [];
        _discoveredPeers = [];
        _error = 'Daemon not connected';
      });
      return;
    }

    try {
      final trustedResult = await client.listTrustedPeers();
      final discoveredResult = await client.listDiscoveredPeers();
      if (mounted) {
        setState(() {
          _trustedPeers = trustedResult['peers'] ?? [];
          _discoveredPeers = discoveredResult['peers'] ?? [];
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _toggleDiscovery() async {
    final client = context.read<JsonRpcRiftClient>();
    if (!client.isConnected) return;
    try {
      if (_isDiscovering) {
        await client.stopDiscovery();
      } else {
        await client.startDiscovery();
      }
      setState(() {
        _isDiscovering = !_isDiscovering;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Widget _buildPeerCard(Map<String, dynamic> peer, bool isTrusted) {
    final isOnline = peer['presence'] == 'online';
    final theme = Theme.of(context);
    
    return Card(
      elevation: 0,
      color: isTrusted 
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isTrusted 
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: isTrusted ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
          foregroundColor: isTrusted ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
          child: Icon(
            isTrusted ? Icons.verified_user : Icons.device_unknown,
          ),
        ),
        title: Text(
          peer['displayName'] ?? (peer['deviceId'] != null ? peer['deviceId'].toString().substring(0, 16) : 'Unknown Device'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text('ID: ${peer['deviceId']}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            if (isTrusted)
               Row(
                 children: [
                   Icon(
                     isOnline ? Icons.circle : Icons.circle_outlined,
                     size: 12,
                     color: isOnline ? Colors.green : Colors.grey,
                   ),
                   const SizedBox(width: 4),
                   Text(
                     isOnline ? 'Online' : 'Offline',
                     style: theme.textTheme.labelMedium?.copyWith(
                       color: isOnline ? Colors.green : Colors.grey,
                     ),
                   ),
                 ],
               ),
            if (!isTrusted && peer['address'] != null)
               Text('Address: ${peer['address']}:${peer['port']}', style: theme.textTheme.bodySmall),
          ],
        ),
        trailing: isTrusted 
          ? IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () {}, // Future config options
            )
          : ElevatedButton(
              onPressed: () {}, // Future pair logic
              child: const Text('Pair'),
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.trustedDevicesTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
        ],
      ),
      body: _error != null && _trustedPeers.isEmpty && _discoveredPeers.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 16),
                  Text('Error loading devices: $_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _loadData, child: const Text('Retry'))
                ]
              )
            )
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Text(
                      'Trusted Devices',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_trustedPeers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('No trusted devices found.'),
                    )
                  else
                    ..._trustedPeers.map((p) => _buildPeerCard(p, true)),
                  
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Text(
                      'Discovered Devices',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_discoveredPeers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('No new devices discovered in your network.'),
                    )
                  else
                    ..._discoveredPeers.map((p) => _buildPeerCard(p, false)),
                  
                  const SizedBox(height: 80), // Fab spacing
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleDiscovery,
        icon: Icon(_isDiscovering ? Icons.search_off : Icons.search),
        label: Text(_isDiscovering ? 'Stop Discovery' : 'Discover Devices'),
      ),
    );
  }
}
