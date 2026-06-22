import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../src/ipc/json_rpc_client.dart';
import 'pairing_screen.dart';

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
  StreamSubscription? _peerLostSub;
  StreamSubscription? _trustSub;
  StreamSubscription? _pairingCompleteSub;
  Timer? _reloadDebounce;
  Timer? _fullReloadThrottle;

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
    _reloadDebounce?.cancel();
    _fullReloadThrottle?.cancel();
    _discoverySub?.cancel();
    _peerLostSub?.cancel();
    _trustSub?.cancel();
    _pairingCompleteSub?.cancel();
    super.dispose();
  }

  void _setupListeners() {
    final client = context.read<JsonRpcRiftClient>();
    _discoverySub = client.onPeerDiscovered.listen(_handlePeerDiscovered);
    _peerLostSub = client.onPeerLost.listen(_handlePeerLost);
    _trustSub = client.onTrustChanged.listen(_handleTrustChanged);
    _pairingCompleteSub =
        client.onPairingComplete.listen(_handlePairingComplete);
  }

  void _scheduleReload() {
    if (!mounted) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 250), () {
      _loadData();
    });
  }

  void _scheduleFullReloadThrottled() {
    if (!mounted) return;
    // Coalesce noisy event bursts into at most 1 full reload per 2 seconds.
    if (_fullReloadThrottle != null) return;
    _fullReloadThrottle = Timer(const Duration(seconds: 2), () {
      _fullReloadThrottle = null;
    });
    _scheduleReload();
  }

  void _handlePeerDiscovered(Map<String, dynamic> event) {
    final deviceId = event['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) return;
    if (!mounted) return;

    setState(() {
      // Upsert into discovered list.
      final existing = _discoveredPeers
          .indexWhere((p) => p is Map && p['deviceId']?.toString() == deviceId);
      if (existing >= 0) {
        final merged =
            Map<String, dynamic>.from(_discoveredPeers[existing] as Map);
        merged.addAll(event);
        _discoveredPeers[existing] = merged;
      } else {
        _discoveredPeers = [event, ..._discoveredPeers];
      }
    });

    // Full reload is still needed to pick up trust state/capabilities accurately.
    _scheduleFullReloadThrottled();
  }

  void _handlePeerLost(Map<String, dynamic> event) {
    final deviceId = event['deviceId']?.toString();
    if (deviceId == null || deviceId.isEmpty) return;
    if (!mounted) return;

    setState(() {
      _discoveredPeers = _discoveredPeers
          .where((p) => !(p is Map && p['deviceId']?.toString() == deviceId))
          .toList(growable: false);
    });

    _scheduleFullReloadThrottled();
  }

  void _handleTrustChanged(Map<String, dynamic> event) {
    final deviceId = event['deviceId']?.toString();
    final newState = event['newState']?.toString();
    if (deviceId == null ||
        deviceId.isEmpty ||
        newState == null ||
        newState.isEmpty) {
      return;
    }
    if (!mounted) return;

    final reason = event['reason']?.toString();
    final previous = event['previousState']?.toString();

    // Quick UI feedback for state transitions (helps triage).
    if (reason != null && reason.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Trust changed: $newState${previous != null ? ' (from $previous)' : ''} - $reason')),
      );
    }

    // We can't fully materialize trusted peer details from the event alone,
    // so do a throttled full reload. Still, update minimal local state to
    // prevent the UI from feeling stale.
    setState(() {
      // Remove from discovered if it is no longer discovered/pairing_pending.
      if (newState == 'trusted' ||
          newState == 'blocked' ||
          newState == 'revoked') {
        _discoveredPeers = _discoveredPeers
            .where((p) => !(p is Map && p['deviceId']?.toString() == deviceId))
            .toList(growable: false);
      }
    });

    _scheduleFullReloadThrottled();
  }

  void _handlePairingComplete(Map<String, dynamic> event) {
    // Spec: includes persistedAt, but listTrustedPeers is the source of truth.
    _scheduleFullReloadThrottled();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final client = context.read<JsonRpcRiftClient>();

    // Default empty lists if not connected
    if (!client.isConnected) {
      setState(() {
        _trustedPeers = [];
        _discoveredPeers = [];
        _isDiscovering = false;
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
          _isDiscovering = discoveredResult['isDiscovering'] == true;
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
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  String _trustStateLabel(String trustState) {
    switch (trustState) {
      case 'pairing_pending':
        return 'Pairing pending';
      case 'blocked':
        return 'Blocked';
      case 'revoked':
        return 'Revoked';
      case 'trusted':
        return 'Trusted';
      default:
        return 'Discovered';
    }
  }

  Future<bool> _confirmTrustAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Widget _buildPeerCard(Map<String, dynamic> peer, bool isTrusted) {
    final isOnline = peer['presence'] == 'online';
    final trustState = peer['trustState']?.toString() ??
        (isTrusted ? 'trusted' : 'discovered');
    final trustLabel = _trustStateLabel(trustState);
    final theme = Theme.of(context);

    final String deviceIdStr = peer['deviceId']?.toString() ?? '';
    final String shortId =
        deviceIdStr.length > 16 ? deviceIdStr.substring(0, 16) : deviceIdStr;
    final String titleText = peer['displayName'] ??
        (deviceIdStr.isNotEmpty ? shortId : 'Unknown Device');

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
          backgroundColor: isTrusted
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          foregroundColor: isTrusted
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurfaceVariant,
          child: Icon(
            isTrusted ? Icons.verified_user : Icons.device_unknown,
          ),
        ),
        title: Text(
          titleText,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text('ID: ${peer['deviceId']}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  label: Text(trustLabel),
                  visualDensity: VisualDensity.compact,
                ),
                if (isTrusted)
                  Row(
                    mainAxisSize: MainAxisSize.min,
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
              ],
            ),
            const SizedBox(height: 4),
            if (isTrusted)
              if (peer['capabilities'] is List &&
                  (peer['capabilities'] as List).isNotEmpty)
                Text(
                  'Capabilities: ${(peer['capabilities'] as List).join(', ')}',
                  style: theme.textTheme.bodySmall,
                ),
            if (!isTrusted && peer['address'] != null)
              Text('Address: ${peer['address']}:${peer['port']}',
                  style: theme.textTheme.bodySmall),
          ],
        ),
        trailing: isTrusted
            ? IconButton(
                icon: Icon(
                    trustState == 'blocked' ? Icons.lock_open : Icons.gpp_bad),
                tooltip: trustState == 'blocked'
                    ? 'Unblock device'
                    : (trustState == 'pairing_pending'
                        ? 'Cancel pairing'
                        : 'Revoke trust'),
                onPressed: () => _handlePeerAction(
                  peer: peer,
                  isTrusted: isTrusted,
                  trustState: trustState,
                  titleText: titleText,
                ),
              )
            : ElevatedButton(
                onPressed: () => _handlePeerAction(
                  peer: peer,
                  isTrusted: isTrusted,
                  trustState: trustState,
                  titleText: titleText,
                ),
                child: const Text('Pair'),
              ),
      ),
    );
  }

  Future<void> _handlePeerAction({
    required Map<String, dynamic> peer,
    required bool isTrusted,
    required String trustState,
    required String titleText,
  }) async {
    final client = context.read<JsonRpcRiftClient>();
    final deviceId = peer['deviceId']?.toString();
    if (deviceId == null) return;

    try {
      if (!isTrusted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PairingScreen(
              initialDeviceId: deviceId,
              initialDisplayName: titleText,
              autoStart: true,
            ),
          ),
        );
        await _loadData();
        return;
      }

      if (trustState == 'blocked') {
        final confirmed = await _confirmTrustAction(
          title: 'Unblock device?',
          message: 'This will return $titleText to discovered state.',
          confirmLabel: 'Unblock',
        );
        if (!confirmed) return;
        await client.unblockPeer(deviceId);
      } else if (trustState == 'trusted' || trustState == 'pairing_pending') {
        final confirmed = await _confirmTrustAction(
          title: trustState == 'pairing_pending'
              ? 'Cancel pairing?'
              : 'Revoke trust?',
          message: trustState == 'pairing_pending'
              ? 'This will drop the pending trust flow for $titleText.'
              : 'This will revoke trust for $titleText and disconnect active sessions.',
          confirmLabel:
              trustState == 'pairing_pending' ? 'Cancel pairing' : 'Revoke',
        );
        if (!confirmed) return;
        if (trustState == 'pairing_pending') {
          await client.rejectPairing(deviceId);
        } else {
          await client.revokeTrust(
              deviceId, 'User revoked trust from device manager');
        }
      }
      await _loadData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
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
                  Icon(Icons.warning_amber_rounded,
                      size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 16),
                  Text('Error loading devices: $_error',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                      onPressed: _loadData, child: const Text('Retry'))
                ]))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Text(
                      'Trusted Devices',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_trustedPeers.isEmpty)
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('No trusted devices found.'),
                    )
                  else
                    ..._trustedPeers.map((p) => _buildPeerCard(p, true)),

                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Text(
                      'Discovered Devices',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_discoveredPeers.isEmpty)
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 24, vertical: 8),
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
